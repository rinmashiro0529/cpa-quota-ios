package monitor

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func readCapabilities(t *testing.T, service *Service, token string) capabilitiesResponse {
	t.Helper()
	response := service.call(t, http.MethodGet, "/v1/capabilities", token, nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("capabilities response: %s, cache policy %q", response.Status, response.Header.Get("Cache-Control"))
	}
	var result capabilitiesResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestCapabilitiesMatchesSharedSwiftFixture(t *testing.T) {
	service, _, _ := testService(t)
	got := readCapabilities(t, service, "bridge")
	body, err := os.ReadFile(filepath.Join("..", "..", "Tests", "ContractFixtures", "monitoring-capabilities-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var want capabilitiesResponse
	if err := decodeStrict(body, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("capabilities handler diverged from the shared Swift contract: %+v", got)
	}
}

func TestCapabilitiesAuthenticatesWithoutMutatingOrCollecting(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	store := &batchPersistence{}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	for _, token := range []string{"", "wrong-token"} {
		response := service.call(t, http.MethodGet, "/v1/capabilities", token, nil)
		response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("invalid token returned %s", response.Status)
		}
	}
	for i := 0; i < 3; i++ {
		got := readCapabilities(t, service, "bridge")
		if got.GeneratedAt != clock.Now().Unix() || got.Capacity.Used != 0 {
			t.Fatal("verification created a retained intent")
		}
	}
	saves, body := store.result()
	if saves != 0 || len(body) != 0 || upstream.Calls() != 0 {
		t.Fatal("authorization verification wrote state or contacted CPA")
	}
	service.Close()
	response := service.call(t, http.MethodGet, "/v1/capabilities", "bridge", nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("closed service claimed authorization was available")
	}
}

func TestCapabilitiesDisclosesOnlyAuthorizedAccountsAndSafeConfiguration(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	options.Store = &batchPersistence{}
	allowed := options.Config.Sources[0].Accounts[0]
	other := allowed
	other.ID, other.SafeID, other.Label = "not-authorized-account", "not-authorized-alias", "Hidden label"
	second := options.Config.Sources[0]
	second.ID, second.BaseURL, second.ManagementKeyEnv = "hidden-source", "https://hidden.example.invalid", "TEST_HIDDEN_KEY"
	second.Accounts = []AccountConfig{other}
	options.Config.Sources[0].Accounts = []AccountConfig{other, allowed}
	options.Config.Sources = append(options.Config.Sources, second)
	options.Config.Principals[1].SourceAccounts = map[string][]string{"hidden-source": {other.ID}}
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	got := readCapabilities(t, service, "bridge")
	if len(got.Sources) != 1 || got.Sources[0].ID != "personal" || len(got.Sources[0].Accounts) != 1 || got.Sources[0].Accounts[0].ID != allowed.ID {
		t.Fatal("capabilities crossed the principal authorization boundary")
	}
	encoded, _ := json.Marshal(got)
	for _, forbidden := range []string{other.ID, other.SafeID, other.Label, second.ID, "example.invalid", "TEST_", "management_key", "principal", "push_token", "bridge"} {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("capabilities exposed forbidden configuration field %q", forbidden)
		}
	}
	foreign := readCapabilities(t, service, "other-bridge")
	if len(foreign.Sources) != 1 || foreign.Sources[0].ID != second.ID || foreign.Sources[0].Accounts[0].ID != other.ID {
		t.Fatal("second principal did not receive its own scoped inventory")
	}
}

func TestCapabilitiesSortsAuthorizedResourcesDeterministically(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	options.Store = &batchPersistence{}
	first := options.Config.Sources[0].Accounts[0]
	last := first
	last.ID, last.SafeID = "z-account", "z-alias"
	second := options.Config.Sources[0]
	second.ID, second.BaseURL = "a-source", "https://another.example.invalid"
	second.Accounts = []AccountConfig{last, first}
	options.Config.Sources = append(options.Config.Sources, second)
	options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": {first.ID}, "a-source": {last.ID, first.ID}}
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	got := readCapabilities(t, service, "bridge")
	if got.Sources[0].ID != "a-source" || got.Sources[1].ID != "personal" || got.Sources[0].Accounts[0].ID != first.ID || got.Sources[0].Accounts[1].ID != last.ID {
		t.Fatal("capabilities did not use stable source/account ordering")
	}
}

func TestCapacityPreflightRetainsTerminalHistoryAndWarnsBeforeExhaustion(t *testing.T) {
	service, clock, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 6, MaxTombstones: 6, MaxPrincipalIntents: 5}
	path := "/v1/monitoring/sessions"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", registration()), http.StatusCreated)
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/"+sessionID, "bridge", nil), http.StatusOK)
	second := registration()
	second["id"] = "22222222-2222-4222-8222-222222222222"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "bridge", second), http.StatusCreated)
	clock.Advance(4 * time.Hour)
	requireCapacityStatus(t, service.call(t, http.MethodGet, path+"/"+second["id"].(string), "bridge", nil), http.StatusOK)
	for i := 3; i <= 4; i++ {
		id := fmt.Sprintf("%08d-1111-4111-8111-111111111111", i)
		requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/"+id, "bridge", nil), http.StatusNoContent)
	}
	got := readCapabilities(t, service, "bridge").Capacity
	if got.Used != 4 || got.Remaining != 1 || got.WarningAt != 4 || got.Status != "warning" || !got.CanCreateSession || !got.CanRecordCancellation {
		t.Fatalf("incorrect early warning for retained terminal work: %+v", got)
	}
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	if after := readCapabilities(t, restored, "bridge").Capacity; after != got {
		t.Fatal("restart silently released historical capacity")
	}
	// Neither a stopped nor an expired registration can become active again.
	for _, request := range []map[string]any{registration(), second} {
		result := decodeSession(t, restored.call(t, http.MethodPost, path, "bridge", request))
		if result["status"] == "active" {
			t.Fatal("capacity diagnostics revived a terminal registration")
		}
	}
	late := registration()
	late["id"] = "00000003-1111-4111-8111-111111111111"
	requireCapacityStatus(t, restored.call(t, http.MethodPost, path, "bridge", late), http.StatusConflict)
	requireCapacityStatus(t, restored.call(t, http.MethodDelete, path+"/55555555-5555-4555-8555-555555555555", "bridge", nil), http.StatusNoContent)
	exhausted := readCapabilities(t, restored, "bridge").Capacity
	if exhausted.Used != 5 || exhausted.Remaining != 0 || exhausted.Status != "exhausted" || exhausted.CanCreateSession || exhausted.CanRecordCancellation {
		t.Fatalf("exhausted capacity was not explained: %+v", exhausted)
	}
	// Confirmed cancellation and the other principal remain available.
	requireCapacityStatus(t, restored.call(t, http.MethodDelete, path+"/"+sessionID, "bridge", nil), http.StatusOK)
	if other := readCapabilities(t, restored, "other-bridge").Capacity; other.Used != 0 || other.Remaining != 5 || other.Status != "ok" {
		t.Fatalf("another principal's retained counts leaked: %+v", other)
	}
}

func TestCapacityPreflightDistinguishesGlobalSlotsWithoutForeignCounts(t *testing.T) {
	service, _, _ := testService(t)
	service.opt.Config.Capacity = CapacityLimits{MaxSessions: 1, MaxTombstones: 1, MaxPrincipalIntents: 5}
	path := "/v1/monitoring/sessions"
	requireCapacityStatus(t, service.call(t, http.MethodPost, path, "other-bridge", registration()), http.StatusCreated)
	capacity := readCapabilities(t, service, "bridge").Capacity
	if capacity.Used != 0 || capacity.Remaining != 5 || capacity.Status != "ok" || capacity.CanCreateSession || !capacity.CanRecordCancellation {
		t.Fatalf("global session slots were confused with principal usage: %+v", capacity)
	}
	requireCapacityStatus(t, service.call(t, http.MethodDelete, path+"/22222222-2222-4222-8222-222222222222", "other-bridge", nil), http.StatusNoContent)
	capacity = readCapabilities(t, service, "bridge").Capacity
	if capacity.Used != 0 || capacity.CanRecordCancellation {
		t.Fatal("global tombstone limit not reflected without disclosing its owner")
	}
}

func TestCapabilitiesDoesNotExpireSessionsAsASideEffect(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	store := &batchPersistence{}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	requireCapacityStatus(t, service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()), http.StatusCreated)
	store.reset()
	_, before := store.result()
	clock.Advance(5 * time.Hour)
	got := readCapabilities(t, service, "bridge")
	saves, after := store.result()
	if got.Capacity.Used != 1 || saves != 0 || !bytes.Equal(before, after) || upstream.Calls() != 0 {
		t.Fatal("read-only verification changed the session lifecycle")
	}
	response := service.call(t, http.MethodGet, "/healthz", "", nil)
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != http.StatusOK || strings.Contains(string(body), "sources") {
		t.Fatal("public healthz acquired authorization or inventory semantics")
	}
}
