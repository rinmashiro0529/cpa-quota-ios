package monitor

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"sync"
	"testing"
	"time"

	"icu.nahida/cpaquota/monitor/apns"
)

func seedAuditSnapshot(t *testing.T, service *Service, clock *clock, upstream *fakeCPA) map[string]any {
	t.Helper()
	value := 0.5
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {
		Identity: "synthetic-identity", Remaining: &value, Status: "ok",
		ObservedAt: 1_800_000_000, ExpiresAt: 1_800_000_900,
	}}
	upstream.mu.Unlock()
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("register: HTTP %d", response.StatusCode)
	}
	response.Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	return decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
}

func TestExpirationPublishesMonotonicTerminalSnapshot(t *testing.T) {
	service, clock, upstream := testService(t)
	before := seedAuditSnapshot(t, service, clock, upstream)
	clock.Advance(4*time.Hour - 10*time.Minute)
	service.RunOnce(context.Background())
	after := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	oldSnapshot, newSnapshot := before["snapshot"].(map[string]any), after["snapshot"].(map[string]any)
	if after["status"] != "expired" || after["revision"] != float64(2) ||
		newSnapshot["phase"] != "expired" || newSnapshot["sequence"] != oldSnapshot["sequence"].(float64)+1 {
		t.Fatalf("terminal response violates the content version contract: %#v", after)
	}
	if !reflect.DeepEqual(oldSnapshot["accounts"], newSnapshot["accounts"]) ||
		oldSnapshot["generated_at"] != newSnapshot["generated_at"] || oldSnapshot["expires_at"] != newSnapshot["expires_at"] {
		t.Fatal("expiry changed the last observed data or its timestamps")
	}
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	again := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if !reflect.DeepEqual(after, again) {
		t.Fatal("terminal response changed again on restore or repeated GET")
	}
}

func TestConfigurationChangeEndsTheOldSemanticSession(t *testing.T) {
	service, clock, upstream := testService(t)
	before := seedAuditSnapshot(t, service, clock, upstream)
	service.Close()
	options := service.options()
	options.Config.Sources[0].Accounts[0].WindowID = "replacement-window"
	options.Config.Sources[0].Accounts[0].WindowLabel = "Replacement window"
	restored, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	after := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	oldSnapshot, newSnapshot := before["snapshot"].(map[string]any), after["snapshot"].(map[string]any)
	if after["status"] != "stopped" || after["revision"] != float64(2) || after["next_refresh_at"] != nil ||
		newSnapshot["phase"] != "stopped" || newSnapshot["sequence"] != oldSnapshot["sequence"].(float64)+1 ||
		!reflect.DeepEqual(oldSnapshot["accounts"], newSnapshot["accounts"]) {
		t.Fatalf("configuration change did not preserve and end the old snapshot: %#v", after)
	}
	cache := restored.call(t, http.MethodGet, "/v1/sources/personal/quota", "bridge", nil)
	defer cache.Body.Close()
	if cache.StatusCode != http.StatusNotFound {
		t.Fatal("old configuration data entered the current source cache")
	}
	calls := upstream.Calls()
	clock.Advance(10 * time.Minute)
	restored.RunOnce(context.Background())
	if upstream.Calls() != calls {
		t.Fatal("old session was sampled under a new window configuration")
	}
	restored.Close()
	again, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if got := decodeSession(t, again.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)); !reflect.DeepEqual(after, got) {
		t.Fatal("repeated restoration changed a terminal snapshot")
	}
}

func TestGrantRevocationReturnsMonotonicRedactedTerminalContent(t *testing.T) {
	service, clock, upstream := testService(t)
	before := seedAuditSnapshot(t, service, clock, upstream)
	service.Close()
	options := service.options()
	second := options.Config.Sources[0].Accounts[0]
	second.ID, second.SafeID = "second-account", "account-2"
	options.Config.Sources[0].Accounts = append(options.Config.Sources[0].Accounts, second)
	options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": {"second-account"}}
	restored, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	after := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	newSnapshot, ok := after["snapshot"].(map[string]any)
	if !ok || after["status"] != "stopped" || after["revision"] != float64(2) || after["delivery_state"] != "disabled" ||
		newSnapshot["phase"] != "stopped" || newSnapshot["sequence"] != before["snapshot"].(map[string]any)["sequence"].(float64)+1 {
		t.Fatalf("revocation did not provide an acceptable terminal response: %#v", after)
	}
	encoded, err := json.Marshal(newSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"Account 1", "5 hours", "remaining_fraction", "observed_at", "synthetic-identity"} {
		if bytes.Contains(encoded, []byte(secret)) {
			t.Fatalf("revoked snapshot retained %q", secret)
		}
	}
	accounts, ok := newSnapshot["accounts"].([]any)
	if !ok || len(accounts) != 1 || accounts[0].(map[string]any)["status"] != "unavailable" {
		t.Fatal("redaction must remain a valid bounded v1 content-state")
	}
	calls := upstream.Calls()
	clock.Advance(10 * time.Minute)
	restored.RunOnce(context.Background())
	if upstream.Calls() != calls {
		t.Fatal("revoked account was sampled")
	}
	restored.Close()
	again, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if got := decodeSession(t, again.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)); !reflect.DeepEqual(after, got) {
		t.Fatal("repeated revocation restoration was not idempotent")
	}
}

type auditNotification struct {
	token, event string
}

type auditNotifier struct {
	mu      sync.Mutex
	calls   []auditNotification
	err     error
	entered chan auditNotification
}

func (n *auditNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	call := auditNotification{token: token, event: event}
	n.mu.Lock()
	n.calls = append(n.calls, call)
	err := n.err
	n.mu.Unlock()
	if n.entered != nil {
		select {
		case n.entered <- call:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}

func (n *auditNotifier) Calls() []auditNotification {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]auditNotification(nil), n.calls...)
}

func auditLiveService(t *testing.T, base *Service, notifier Notifier) *Service {
	t.Helper()
	base.Close()
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Close)
	return service
}

func awaitAuditIdle(t *testing.T, service *Service) {
	t.Helper()
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		service.mu.Lock()
		idle := len(service.rounds) == 0 && len(service.notifications) == 0
		service.mu.Unlock()
		if idle {
			return
		}
		select {
		case <-tick.C:
		case <-deadline.C:
			t.Fatal("service workers did not finish")
		}
	}
}

func TestScheduleScansLeaseDeadlinesWhileCollectionIsBlocked(t *testing.T) {
	base, clock, upstream := testService(t)
	notifier := &auditNotifier{entered: make(chan auditNotification, 8)}
	service := auditLiveService(t, base, notifier)
	long := registration()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", long).Body.Close()
	short := registration()
	short["id"], short["push_token"], short["duration_seconds"] = "22222222-2222-4222-8222-222222222222", "ef01", 3600
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", short).Body.Close()
	upstream.mu.Lock()
	upstream.block, upstream.started = make(chan struct{}), make(chan struct{}, 1)
	entered := upstream.started
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); service.Schedule(ctx, time.Millisecond) }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("scheduled collector did not enter")
	}
	clock.Advance(50 * time.Minute)
	// Do not GET the short session: GET itself could expire it and hide the regression.
	select {
	case call := <-notifier.entered:
		if call.token != "ef01" || call.event != "end" {
			t.Fatalf("unexpected lease notification: %#v", call)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("slow collection blocked an independent lease deadline")
	}
	if upstream.Calls() != 1 {
		t.Fatal("repeated scans started duplicate work for the blocked source")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("scheduler did not stop while a source was blocked")
	}
	service.Close() // Cancels and waits for the still-blocked collector.
	service.mu.Lock()
	defer service.mu.Unlock()
	if len(service.rounds) != 0 || len(service.notifications) != 0 {
		t.Fatal("close returned before workers released their ownership")
	}
}

func TestInvalidAPNsTokenStaysFailedAcrossCollectionRestoreAndCAS(t *testing.T) {
	base, clock, upstream := testService(t)
	notifier := &auditNotifier{err: &apns.HTTPError{Status: http.StatusGone}}
	service := auditLiveService(t, base, notifier)
	seedAuditSnapshot(t, service, clock, upstream)
	awaitAuditIdle(t, service)
	if len(notifier.Calls()) != 1 {
		t.Fatal("initial APNs rejection was not observed")
	}
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	awaitAuditIdle(t, service)
	if len(notifier.Calls()) != 1 {
		t.Fatal("collection retried the permanently rejected activity token")
	}
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	clock.Advance(10 * time.Minute)
	restored.RunOnce(context.Background())
	awaitAuditIdle(t, restored)
	if len(notifier.Calls()) != 1 {
		t.Fatal("restore forgot the permanent token rejection")
	}
	same := restored.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": "ABCD", "revision": 1})
	defer same.Body.Close()
	if same.StatusCode != http.StatusConflict {
		t.Fatal("same token with different hex case cleared the permanent failure")
	}
	stale := restored.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": "ef01", "revision": 99})
	defer stale.Body.Close()
	if stale.StatusCode != http.StatusConflict {
		t.Fatal("stale CAS cleared the permanent failure")
	}
	notifier.mu.Lock()
	notifier.err = nil
	notifier.mu.Unlock()
	rotated := restored.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": "ef01", "revision": 1})
	defer rotated.Body.Close()
	if rotated.StatusCode != http.StatusOK {
		t.Fatalf("valid token CAS: HTTP %d", rotated.StatusCode)
	}
	restored.RunOnce(context.Background())
	awaitAuditIdle(t, restored)
	calls := notifier.Calls()
	if len(calls) != 2 || calls[1].token != "ef01" {
		t.Fatalf("new token did not restore delivery exactly once: %#v", calls)
	}
	current := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if current["version"] != float64(1) || current["delivery_state"] != "sent" {
		t.Fatal("persistent token state changed the public v1 response contract")
	}
}
