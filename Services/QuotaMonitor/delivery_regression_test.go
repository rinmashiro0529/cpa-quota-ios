package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"icu.nahida/cpaquota/monitor/apns"
)

func TestInvalidTokenStateIsDurableAndStopsAllEndRetries(t *testing.T) {
	base, clock, upstream := testService(t)
	notifier := &auditNotifier{err: &apns.HTTPError{Status: 410, Reason: "Unregistered"}}
	service := auditLiveService(t, base, notifier)
	seedAuditSnapshot(t, service, clock, upstream)
	awaitAuditIdle(t, service)
	raw, err := service.opt.Store.Load()
	if err != nil {
		t.Fatal(err)
	}
	var durable persisted
	if err := json.Unmarshal(raw, &durable); err != nil {
		t.Fatal(err)
	}
	if record := durable.Sessions[sessionID]; record.Version != 2 || record.TokenInvalidReason != "Unregistered" {
		t.Fatal("invalid-token evidence was not saved as a v2 record")
	}
	for range 2 {
		response := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)
		stopped := decodeSession(t, response)
		if stopped["status"] != "stopped" || stopped["delivery_state"] != "failed" || stopped["version"] != float64(1) {
			t.Fatal("stop lost terminal intent or incorrectly claimed delivery")
		}
	}
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	clock.Advance(time.Hour)
	restored.RunOnce(context.Background())
	restored.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil).Body.Close()
	awaitAuditIdle(t, restored)
	if len(notifier.Calls()) != 1 {
		t.Fatal("stop, repeated stop or restoration sent to the known-invalid token")
	}
}

func TestProviderAuthenticationFailureDoesNotInvalidateActivityToken(t *testing.T) {
	base, clock, upstream := testService(t)
	notifier := &auditNotifier{err: &apns.HTTPError{Status: 403, Reason: "ExpiredProviderToken"}}
	service := auditLiveService(t, base, notifier)
	seedAuditSnapshot(t, service, clock, upstream)
	awaitAuditIdle(t, service)
	service.mu.Lock()
	record := service.state.Sessions[sessionID]
	service.mu.Unlock()
	if record.TokenInvalidReason != "" || record.Version != 1 || record.DeliveryRetryAt != clock.Now().Unix()+60 {
		t.Fatal("provider JWT failure was treated as a permanent activity-token failure")
	}
	clock.Advance(59 * time.Second)
	service.RunOnce(context.Background())
	awaitAuditIdle(t, service)
	if len(notifier.Calls()) != 1 {
		t.Fatal("provider JWT retry ignored backoff")
	}
	notifier.mu.Lock()
	notifier.err = nil
	notifier.mu.Unlock()
	clock.Advance(time.Second)
	service.RunOnce(context.Background())
	awaitAuditIdle(t, service)
	calls := notifier.Calls()
	if len(calls) != 2 || calls[1].token != "abcd" || upstream.Calls() != 1 {
		t.Fatal("provider recovery did not retry the existing token without sampling")
	}
}

func TestBadDeviceTokenAndWrongTopicStayInvalidAcrossRefresh(t *testing.T) {
	for _, reason := range []string{"BadDeviceToken", "DeviceTokenNotForTopic"} {
		t.Run(reason, func(t *testing.T) {
			base, clock, upstream := testService(t)
			notifier := &auditNotifier{err: &apns.HTTPError{Status: 400, Reason: reason}}
			service := auditLiveService(t, base, notifier)
			seedAuditSnapshot(t, service, clock, upstream)
			awaitAuditIdle(t, service)
			clock.Advance(10 * time.Minute)
			response := service.call(t, http.MethodPost, "/v1/monitoring/sessions/"+sessionID+"/refresh", "bridge", nil)
			if response.StatusCode != http.StatusAccepted {
				t.Fatalf("refresh: HTTP %d", response.StatusCode)
			}
			response.Body.Close()
			awaitAuditIdle(t, service)
			service.RunOnce(context.Background())
			awaitAuditIdle(t, service)
			if len(notifier.Calls()) != 1 || upstream.Calls() != 2 {
				t.Fatal("refresh either stopped useful collection or revived an invalid push token")
			}
		})
	}
}

type gatedTokenRejection struct {
	entered chan struct{}
	release chan struct{}
	calls   atomic.Int32
}

func (n *gatedTokenRejection) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	n.calls.Add(1)
	select {
	case n.entered <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case <-n.release:
		return &apns.HTTPError{Status: 410, Reason: "Unregistered"}
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestTokenRejectionSurvivesNewerContentAndLeaseExpiry(t *testing.T) {
	for _, transition := range []string{"new_content", "expiry"} {
		t.Run(transition, func(t *testing.T) {
			base, clock, upstream := testService(t)
			notifier := &gatedTokenRejection{entered: make(chan struct{}, 4), release: make(chan struct{})}
			var once sync.Once
			release := func() { once.Do(func() { close(notifier.release) }) }
			defer release()
			service := auditLiveService(t, base, notifier)
			seedAuditSnapshot(t, service, clock, upstream)
			select {
			case <-notifier.entered:
			case <-time.After(2 * time.Second):
				t.Fatal("first token attempt did not enter")
			}
			if transition == "expiry" {
				clock.Advance(4 * time.Hour)
			} else {
				clock.Advance(10 * time.Minute)
			}
			service.RunOnce(context.Background())
			release()
			awaitAuditIdle(t, service)
			service.mu.Lock()
			record := service.state.Sessions[sessionID]
			service.mu.Unlock()
			if record.Snapshot.Sequence != 2 || record.TokenInvalidReason != "Unregistered" || record.Delivery != "failed" {
				t.Fatal("new content or expiry discarded an authoritative rejection of the unchanged token")
			}
			service.RunOnce(context.Background())
			awaitAuditIdle(t, service)
			if notifier.calls.Load() != 1 {
				t.Fatal("queued work sent to a token already known to be invalid")
			}
		})
	}
}

func TestTokenFailureCannotBeSmuggledIntoALegacyRecord(t *testing.T) {
	base, clock, upstream := testService(t)
	seedAuditSnapshot(t, base, clock, upstream)
	base.Close()
	raw, err := base.opt.Store.Load()
	if err != nil {
		t.Fatal(err)
	}
	var state persisted
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		version int
		reason  string
	}{
		{1, "Unregistered"}, {2, "arbitrary-response-body"}, {3, ""},
	} {
		record := state.Sessions[sessionID]
		record.Version, record.TokenInvalidReason = tc.version, tc.reason
		state.Sessions[sessionID] = record
		body, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		options := base.options()
		options.Store = &faultPersistence{body: body}
		if restored, err := NewService(options); err == nil {
			restored.Close()
			t.Fatalf("accepted invalid durable version/reason: %d", tc.version)
		}
	}
}

func TestDeliveryGateReferencesAreReclaimedWithoutBreakingSerialization(t *testing.T) {
	service, _, _ := testService(t)
	first, ok := service.lockDelivery(context.Background(), sessionID)
	if !ok {
		t.Fatal("initial gate was unavailable")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if release, ok := service.lockDelivery(ctx, sessionID); ok {
		release()
		first()
		t.Fatal("cancelled waiter acquired a held gate")
	}
	service.mu.Lock()
	users := service.delivery[sessionID].users
	service.mu.Unlock()
	if users != 1 {
		first()
		t.Fatal("cancelled waiter leaked or removed another holder's reference")
	}
	first()
	var active, collisions atomic.Int32
	var group sync.WaitGroup
	start := make(chan struct{})
	for range 8 {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			for range 100 {
				release, ok := service.lockDelivery(context.Background(), sessionID)
				if !ok {
					collisions.Add(1)
					return
				}
				if active.Add(1) != 1 {
					collisions.Add(1)
				}
				active.Add(-1)
				release()
			}
		}()
	}
	close(start)
	group.Wait()
	service.mu.Lock()
	defer service.mu.Unlock()
	if collisions.Load() != 0 || len(service.delivery) != 0 {
		t.Fatal("gate reclamation broke serialization or retained idle UUIDs")
	}
}

func TestUnknownAndForeignDeletesDoNotRetainDeliveryGates(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	foreign := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "other-bridge", nil)
	if foreign.StatusCode != http.StatusNotFound {
		t.Fatal("foreign delete did not preserve owner isolation")
	}
	foreign.Body.Close()
	for i := range 16 {
		id := fmt.Sprintf("%08d-2222-4222-8222-222222222222", i)
		response := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+id, "bridge", nil)
		if response.StatusCode != http.StatusNoContent {
			t.Fatalf("unknown delete: HTTP %d", response.StatusCode)
		}
		response.Body.Close()
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if len(service.delivery) != 0 {
		t.Fatal("unknown or foreign deletes retained permanent delivery gates")
	}
}

func TestTerminalContentSequenceNeverWraps(t *testing.T) {
	previous := &snapshotRecord{Version: 1, Sequence: math.MaxUint64, Phase: "ready", Accounts: []accountRecord{revokedAccount}}
	if terminalSnapshot(previous, "expired") != previous {
		t.Fatal("exhausted sequence changed content without a larger version")
	}
	if _, err := revokedSnapshot(previous, 1800000000); err == nil {
		t.Fatal("exhausted sequence silently reset a revoked snapshot")
	}
}

func TestCollectionAtSequenceLimitPreservesLastObservation(t *testing.T) {
	service, clock, upstream := testService(t)
	seedAuditSnapshot(t, service, clock, upstream)
	service.mu.Lock()
	record := service.state.Sessions[sessionID]
	last := *record.Snapshot
	last.Sequence = math.MaxUint64
	record.Snapshot = &last
	service.state.Sessions[sessionID] = record
	err := service.persistLocked()
	service.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	service.mu.Lock()
	after := service.state.Sessions[sessionID]
	service.mu.Unlock()
	if after.Snapshot != record.Snapshot || after.Snapshot.Sequence != math.MaxUint64 {
		t.Fatal("collection wrapped the content sequence or replaced the final observation")
	}
	clock.Advance(4 * time.Hour)
	service.RunOnce(context.Background())
	service.mu.Lock()
	after = service.state.Sessions[sessionID]
	service.mu.Unlock()
	if after.Status != "expired" || after.Snapshot != record.Snapshot {
		t.Fatal("exhausted content sequence prevented lease termination or changed immutable content")
	}
}
