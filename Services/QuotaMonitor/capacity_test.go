package monitor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
)

func requireCapacityStatus(t *testing.T, response *http.Response, want int) {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != want {
		t.Fatalf("HTTP status = %d, want %d", response.StatusCode, want)
	}
	if want == http.StatusInsufficientStorage && response.Header.Get("Retry-After") != "" {
		t.Fatal("retained intent capacity has no time-based retry promise")
	}
}

func TestPrincipalCapacityRejectsOnlyNewIntents(t *testing.T) {
	service, _, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 4, MaxTombstones: 4, MaxPrincipalIntents: 1}
	path := "/v1/monitoring/sessions"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", registration()), http.StatusCreated)
	before, err := service.opt.Store.Load()
	if err != nil {
		t.Fatal(err)
	}
	next := registration()
	next["id"] = "22222222-2222-4222-8222-222222222222"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", next), http.StatusInsufficientStorage)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/33333333-3333-4333-8333-333333333333", "bridge", nil), http.StatusInsufficientStorage)
	after, err := service.opt.Store.Load()
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("rejected admission changed the durable state")
	}
	// Idempotency, reads, and stopping already accepted work remain available.
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", registration()), http.StatusCreated)
	requireCapacityStatus(t, service.call(t, http.MethodGet, path+"/"+sessionID, "bridge", nil), http.StatusOK)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/"+sessionID, "bridge", nil), http.StatusOK)
	requireCapacityStatus(t, service.call(t, http.MethodGet, "/healthz", "", nil), http.StatusOK)
	// One exhausted principal does not consume another principal's allowance.
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "other-bridge", next), http.StatusCreated)
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	requireCapacityStatus(t, restored.call(t, http.MethodPost, path, "bridge", next), http.StatusNotFound)
	requireCapacityStatus(t, restored.call(t, http.MethodGet, path+"/"+sessionID, "bridge", nil), http.StatusOK)
}

func TestTombstoneCapacityPreservesReplayProtection(t *testing.T) {
	service, _, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 2, MaxTombstones: 1, MaxPrincipalIntents: 4}
	path := "/v1/monitoring/sessions/"
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+sessionID, "bridge", nil), http.StatusNoContent)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+sessionID, "bridge", nil), http.StatusNoContent)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"22222222-2222-4222-8222-222222222222", "bridge", nil), http.StatusInsufficientStorage)
	requireCapacityStatus(t, service.call(t, http.MethodPost, strings.TrimSuffix(path, "/"), "bridge", registration()), http.StatusConflict)
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	requireCapacityStatus(t, restored.call(t, http.MethodPost, strings.TrimSuffix(path, "/"), "bridge", registration()), http.StatusConflict)
	requireCapacityStatus(t, restored.call(t, http.MethodDelete, path+sessionID, "bridge", nil), http.StatusNoContent)
	requireCapacityStatus(t, restored.call(t, http.MethodGet, "/healthz", "", nil), http.StatusOK)
}

func TestGlobalSessionCapacityDoesNotCloseService(t *testing.T) {
	service, _, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 1, MaxTombstones: 4, MaxPrincipalIntents: 4}
	path := "/v1/monitoring/sessions"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", registration()), http.StatusCreated)
	next := registration()
	next["id"] = "22222222-2222-4222-8222-222222222222"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "other-bridge", next), http.StatusInsufficientStorage)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/"+sessionID, "bridge", nil), http.StatusOK)
	requireCapacityStatus(t, service.call(t, http.MethodGet, "/healthz", "", nil), http.StatusOK)
}

func TestConcurrentAdmissionDoesNotOversubscribeCapacity(t *testing.T) {
	service, _, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 8, MaxTombstones: 8, MaxPrincipalIntents: 5}
	statuses := make(chan int, 20)
	start := make(chan struct{})
	var requests sync.WaitGroup
	for i := 0; i < cap(statuses); i++ {
		requests.Add(1)
		go func(i int) {
			defer requests.Done()
			<-start
			request := registration()
			request["id"] = fmt.Sprintf("%08x-1111-4111-8111-111111111111", i)
			response := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", request)
			defer response.Body.Close()
			statuses <- response.StatusCode
		}(i)
	}
	close(start)
	requests.Wait()
	close(statuses)
	accepted, rejected := 0, 0
	for status := range statuses {
		switch status {
		case http.StatusCreated:
			accepted++
		case http.StatusInsufficientStorage:
			rejected++
		default:
			t.Fatalf("unexpected concurrent admission status: %d", status)
		}
	}
	if accepted != 5 || rejected != 15 {
		t.Fatalf("capacity was not atomic: accepted %d, rejected %d", accepted, rejected)
	}
	requireCapacityStatus(t, service.call(t, http.MethodGet, "/healthz", "", nil), http.StatusOK)
}

func capacityRecord(id string) sessionRecord {
	return sessionRecord{Version: 1, ID: id, Principal: "phone", SourceID: "personal",
		AccountIDs: []string{"a", "b", "c", "d", "e"}, ActivityID: "activity", PushToken: "abcd",
		StartsAt: 1_800_000_000, ExpiresAt: 1_800_003_600, Status: "active", Revision: 1, Delivery: "pending"}
}

func TestAdmissionReservesFutureSnapshotTokenAndDeliveryGrowth(t *testing.T) {
	record := capacityRecord(sessionID)
	state := persisted{Sessions: map[string]sessionRecord{sessionID: record}, Tombstones: map[string]string{}}
	before, _ := json.Marshal(state)
	reserved, err := reservedStateBytes(state)
	if err != nil {
		t.Fatal(err)
	}
	after, _ := json.Marshal(state)
	if !bytes.Equal(before, after) {
		t.Fatal("reservation mutated live state")
	}
	record.PushToken = strings.Repeat("f", 4096)
	record.Version, record.TokenInvalidReason = 2, "DeviceTokenNotForTopic"
	record.Status, record.Delivery = "expired", "disabled"
	record.Revision, record.DeliveryRetryAt, record.DeliveryAttempts = math.MaxUint64, math.MaxInt64, math.MaxUint8
	next := int64(math.MaxInt64)
	record.NextRefresh = &next
	record.AccountIdentities = map[string]string{}
	for _, id := range record.AccountIDs {
		record.AccountIdentities[id] = strings.Repeat("a", 64)
	}
	value, observed := math.MaxFloat64, int64(math.MaxInt64)
	accounts := make([]accountRecord, 3)
	for i := range accounts {
		accounts[i] = accountRecord{ID: fmt.Sprint(i), Label: strings.Repeat("L", 128), Provider: strings.Repeat("P", 128),
			WindowID: strings.Repeat("W", 128), Window: strings.Repeat("W", 128), Unit: strings.Repeat("U", 128),
			Value: &value, Observed: &observed, Status: "unavailable"}
	}
	record.Snapshot = &snapshotRecord{Version: 1, Sequence: math.MaxUint64, Phase: "expired", GeneratedAt: math.MaxInt64, ExpiresAt: math.MaxInt64, Accounts: accounts}
	snapshot, _ := json.Marshal(record.Snapshot)
	if len(snapshot) > contentBudget {
		t.Fatal("test snapshot must obey the real content budget")
	}
	state.Sessions[sessionID] = record
	grown, err := json.Marshal(state)
	if err != nil || len(grown) > reserved {
		t.Fatalf("accepted work outgrew reserved state: %d > %d (%v)", len(grown), reserved, err)
	}
}

func TestAdmissionChecksReservedBytesBeforeFileStoreFailure(t *testing.T) {
	state := persisted{Sessions: map[string]sessionRecord{}, Tombstones: map[string]string{}}
	for i := 0; i < 4096; i++ {
		id := fmt.Sprintf("%08x-1111-4111-8111-111111111111", i)
		state.Sessions[id] = capacityRecord(id)
	}
	body, _ := json.Marshal(state)
	if len(body) >= maxStateBytes-128 {
		t.Fatal("fixture should fit now but lack room for future accepted work")
	}
	limits := CapacityLimits{MaxSessions: 16384, MaxTombstones: 65536, MaxPrincipalIntents: 65536}
	if err := validateCapacity(state, limits); !errors.Is(err, ErrCapacity) {
		t.Fatalf("future growth was admitted: %v", err)
	}
	base, _, _ := testService(t)
	options := base.options()
	options.Store = &faultPersistence{body: body}
	options.Config.Capacity = limits
	if service, err := NewService(options); !errors.Is(err, ErrCapacity) {
		if service != nil {
			service.Close()
		}
		t.Fatalf("over-budget recovery should reject without rewriting: %v", err)
	}
	stored, _ := options.Store.Load()
	if !bytes.Equal(body, stored) {
		t.Fatal("capacity rejection rewrote or discarded existing state")
	}
}

func TestCapacityConfigurationAndStablePluginSelection(t *testing.T) {
	cfg := validConfig()
	if err := cfg.Validate(); err != nil || cfg.Capacity.MaxSessions != 1024 || cfg.Capacity.MaxPrincipalIntents != 256 || cfg.Capacity.MaxTombstones != 4096 {
		t.Fatal("capacity defaults were not applied")
	}
	for _, limits := range []CapacityLimits{{MaxSessions: -1}, {MaxSessions: 16385}, {MaxTombstones: -1}, {MaxPrincipalIntents: -1}} {
		c := validConfig()
		c.Capacity = limits
		if c.Validate() == nil {
			t.Fatal("invalid capacity configuration accepted")
		}
	}
	for _, selection := range []string{"summary:0", "bucket:0:0", "summary-key:"} {
		c := validConfig()
		c.Sources[0].Accounts[0].Reader = "plugin"
		c.Sources[0].Accounts[0].Selection = selection
		if c.Validate() == nil {
			t.Fatalf("unstable selector accepted: %q", selection)
		}
	}
	c := validConfig()
	c.Sources[0].Accounts[0].Reader = "plugin"
	c.Sources[0].Accounts[0].Selection = "summary-key:requests_left"
	if err := c.Validate(); err != nil {
		t.Fatalf("stable selector rejected: %v", err)
	}
}
