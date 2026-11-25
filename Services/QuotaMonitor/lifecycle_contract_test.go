package monitor

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

type lifecycleContractCase struct {
	Name     string           `json:"name"`
	Sessions []map[string]any `json:"sessions"`
}

type lifecycleContract struct {
	Version int                     `json:"version"`
	Cases   []lifecycleContractCase `json:"cases"`
}

// These are real handler responses, not manually transcribed state transitions.
// Swift tests consume the same committed fixture through one Store per case.
func TestMonitoringLifecycleFixtureMatchesServiceResponses(t *testing.T) {
	got := lifecycleContract{Version: 1}
	for _, name := range []string{"expiry", "explicit_stop", "configuration_changed", "grant_revoked", "expiry_before_first_snapshot"} {
		service, clock, upstream := testService(t)
		var before map[string]any
		if name == "expiry_before_first_snapshot" {
			before = decodeSession(t, service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()))
		} else {
			before = seedAuditSnapshot(t, service, clock, upstream)
		}
		var after map[string]any
		switch name {
		case "expiry", "expiry_before_first_snapshot":
			clock.Advance(time.Unix(1_800_014_400, 0).Sub(clock.Now()))
			service.RunOnce(context.Background())
		case "explicit_stop":
			after = decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		case "configuration_changed", "grant_revoked":
			service.Close()
			options := service.options()
			if name == "configuration_changed" {
				options.Config.Sources[0].Accounts[0].WindowID = "replacement-window"
				options.Config.Sources[0].Accounts[0].WindowLabel = "Replacement window"
			} else {
				second := options.Config.Sources[0].Accounts[0]
				second.ID, second.SafeID = "second-account", "account-2"
				options.Config.Sources[0].Accounts = append(options.Config.Sources[0].Accounts, second)
				options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": {"second-account"}}
			}
			restored, err := NewService(options)
			if err != nil {
				t.Fatal(err)
			}
			service = restored
			t.Cleanup(restored.Close)
		}
		if after == nil {
			after = decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		}
		service.Close()
		restored, err := NewService(service.options())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(restored.Close)
		repeated := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		if !reflect.DeepEqual(after, repeated) {
			t.Fatalf("%s terminal state changed on restore", name)
		}
		got.Cases = append(got.Cases, lifecycleContractCase{Name: name, Sessions: []map[string]any{before, after, repeated}})
	}
	path := filepath.Join("..", "..", "Tests", "ContractFixtures", "monitoring-lifecycle-v1.json")
	if os.Getenv("UPDATE_MONITORING_FIXTURES") == "1" {
		body, err := json.MarshalIndent(got, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(body, '\n'), 0644); err != nil {
			t.Fatal(err)
		}
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var want lifecycleContract
	if err := json.Unmarshal(body, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatal("handler lifecycle responses differ from the shared Swift/Go fixture; review the contract before regenerating")
	}
}
