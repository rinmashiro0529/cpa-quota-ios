package cpa

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
)

func TestPluginKeySelectionNeverRelabelsReorderedSameUnitMetrics(t *testing.T) {
	var response atomic.Value
	response.Store(`{"summary":[{"key":"daily","value":20,"unit":"requests"},{"key":"weekly","value":90,"unit":"requests"}]}`)
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v0/management/auth-files":
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"fixture-plugin","supports_quota":true}]}`)
		case "/v0/management/quota/providers":
			writeJSON(w, `{"providers":["fixture-plugin"]}`)
		case "/v0/management/quota/fetch":
			writeJSON(w, response.Load().(string))
		default:
			t.Errorf("unexpected plugin path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}, []Account{{ID: "a", Provider: "fixture-plugin", Reader: "plugin", Selection: "summary-key:weekly"}})

	first := client.Collect(context.Background())["a"]
	if first.Status != "ok" || first.Result.Value == nil || *first.Result.Value != 90 || first.Result.Unit != "requests" {
		t.Fatalf("initial confirmed metric was not read: %+v", first)
	}
	response.Store(`{"summary":[{"key":"weekly","value":85,"unit":"requests"},{"key":"monthly","value":300,"unit":"requests"},{"key":"daily","value":15,"unit":"requests"}]}`)
	now.Add(600)
	second := client.Collect(context.Background())["a"]
	if second.Status != "ok" || second.Result.Value == nil || *second.Result.Value != 85 || second.Identity != first.Identity {
		t.Fatalf("reordering changed the selected metric identity: %+v", second)
	}
	response.Store(`{"summary":[{"key":"weekly","value":10,"unit":"requests"},{"key":"weekly","value":80,"unit":"requests"}]}`)
	now.Add(600)
	third := client.Collect(context.Background())["a"]
	if third.Status != "stale" || third.Result.Value == nil || *third.Result.Value != 85 || third.ObservedAt != second.ObservedAt {
		t.Fatalf("ambiguous new metric was accepted or given a new observation: %+v", third)
	}
	response.Store(`{"summary":[{"label":"weekly","value":5,"unit":"requests"}]}`)
	now.Add(600)
	fourth := client.Collect(context.Background())["a"]
	if fourth.Status != "stale" || fourth.Result.Value == nil || *fourth.Result.Value != 85 || fourth.ObservedAt != second.ObservedAt {
		t.Fatalf("display label substituted for the missing key: %+v", fourth)
	}
}

func TestPluginPositionalConfigurationFailsBeforeAnyRequest(t *testing.T) {
	for _, selection := range []string{"summary:0", "bucket:0:0"} {
		_, err := New(Config{
			BaseURL: "https://fixture.example.invalid", ManagementKey: "fixture-key",
			Accounts: []Account{{ID: "a", Provider: "fixture-plugin", Reader: "plugin", Selection: selection}},
		})
		if err != ErrSelection {
			t.Errorf("unsafe positional selection %q was not rejected: %v", selection, err)
		}
	}
}
