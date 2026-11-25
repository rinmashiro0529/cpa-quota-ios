package quota_test

import (
	"strings"
	"testing"

	"icu.nahida/cpaquota/monitor/quota"
)

func TestPluginSummaryKeySurvivesReorderingAndInsertion(t *testing.T) {
	for _, body := range []string{
		`{"summary":[{"key":"daily","value":20,"unit":"requests"},{"key":"weekly","value":90,"unit":"requests"}]}`,
		`{"summary":[{"key":"weekly","value":90,"unit":"requests"},{"key":"daily","value":20,"unit":"requests"}]}`,
		`{"summary":[{"key":"monthly","value":300,"unit":"requests"},{"key":"daily","value":20,"unit":"requests"},{"key":"weekly","value":90,"unit":"requests"}]}`,
		`{"summary":[{"label":"Unidentified metric","value":1,"unit":"requests"},{"key":"weekly","label":"New display label","value":90,"unit":"requests","future_field":true}]}`,
	} {
		got, err := quota.Normalize("plugin", []byte(body), "summary-key:weekly")
		if err != nil || got.Value == nil || *got.Value != 90 || got.Unit != "requests" || got.Remaining != nil {
			t.Fatalf("stable summary key changed meaning: %+v %v", got, err)
		}
	}
}

func TestPluginSummaryIdentityMustBePresentAndUnique(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"deleted key", `{"summary":[{"key":"daily","value":20,"unit":"requests"}]}`},
		{"duplicate key", `{"summary":[{"key":"weekly","value":90,"unit":"requests"},{"key":"weekly","value":10,"unit":"requests"}]}`},
		{"equal duplicates", `{"summary":[{"key":"weekly","value":90,"unit":"requests"},{"key":"weekly","value":90,"unit":"requests"}]}`},
		{"label is not identity", `{"summary":[{"label":"weekly","value":90,"unit":"requests"}]}`},
		{"id is not the confirmed key", `{"summary":[{"id":"weekly","value":90,"unit":"requests"}]}`},
		{"key is case sensitive", `{"summary":[{"key":"Weekly","value":90,"unit":"requests"}]}`},
		{"key is not trimmed", `{"summary":[{"key":" weekly ","value":90,"unit":"requests"}]}`},
		{"numeric key is not a string", `{"summary":[{"key":7,"value":90,"unit":"requests"}]}`},
		{"wrong summary shape", `{"summary":{"key":"weekly","value":90,"unit":"requests"}}`},
		{"bucket has only display identity", `{"groups":[{"display_name":"Weekly","buckets":[{"window":"weekly","remainingFraction":0.9}]}]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := quota.Normalize("plugin", []byte(tc.body), "summary-key:weekly")
			if err == nil || got.Value != nil || got.Remaining != nil {
				t.Fatalf("unproven metric identity became a reading: %+v %v", got, err)
			}
		})
	}
	if got, err := quota.Normalize("plugin", []byte(`{"summary":[{"key":7,"value":90,"unit":"requests"}]}`), "summary-key:7"); err == nil || got.Value != nil {
		t.Fatalf("numeric key was coerced into the configured string identity: %+v %v", got, err)
	}
}

func TestPluginSelectionRejectsPositionsAndUnprovenBucketKeys(t *testing.T) {
	body := []byte(`{"summary":[{"key":"weekly","value":90,"unit":"requests"}],"groups":[{"id":"group","buckets":[{"id":"weekly","window":"weekly","remainingFraction":0.9}]}]}`)
	for _, selection := range []string{
		"summary:0", "bucket:0:0", "bucket-key:group:weekly", "weekly",
		"summary-key:", "summary-key: weekly", "summary-key:weekly ",
		"summary-key:weekly/requests", "summary-key:weekly:requests",
		"summary-key:" + strings.Repeat("a", 129),
	} {
		if err := quota.ValidateSelection("plugin", selection); err == nil {
			t.Errorf("unsafe selection accepted: %q", selection)
		}
		if got, err := quota.Normalize("plugin", body, selection); err == nil || got.Remaining != nil || got.Value != nil {
			t.Errorf("unsafe selection produced a reading: %q %+v %v", selection, got, err)
		}
	}
	for _, key := range []string{"weekly", "Weekly_Requests-1", "0", strings.Repeat("a", 128)} {
		if err := quota.ValidateSelection("plugin", "summary-key:"+key); err != nil {
			t.Errorf("valid confirmed summary key rejected: %q", key)
		}
	}
}
