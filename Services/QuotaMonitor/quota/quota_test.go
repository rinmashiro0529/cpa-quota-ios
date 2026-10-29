package quota_test

import (
	"encoding/json"
	"math"
	"os"
	"testing"

	"icu.nahida/cpaquota/monitor/quota"
)

func TestFrozenEdgeSemantics(t *testing.T) {
	codex := []byte(`{"rate_limit":{"primary_window":{"used_percent":-5},"secondary_window":{"used_percent":0}}}`)
	unknown, err := quota.Normalize("codex", codex, "primary")
	if err != nil || unknown.Remaining != nil {
		t.Fatalf("negative codex usage must stay unknown: %+v %v", unknown, err)
	}
	full, err := quota.Normalize("codex", codex, "secondary")
	if err != nil || full.Remaining == nil || *full.Remaining != 1 {
		t.Fatalf("zero codex usage: %+v %v", full, err)
	}
	over := []byte(`{"rate_limit":{"primary_window":{"used_percent":100},"secondary_window":{"used_percent":140}}}`)
	exact, err := quota.Normalize("codex", over, "primary")
	if err != nil || exact.Remaining == nil || *exact.Remaining != 0 {
		t.Fatalf("exact codex limit: %+v %v", exact, err)
	}
	clamped, err := quota.Normalize("codex", over, "secondary")
	if err != nil || clamped.Remaining == nil || *clamped.Remaining != 0 {
		t.Fatalf("codex over-limit must remain zero, not unknown: %+v %v", clamped, err)
	}

	xai := []byte(`{"config":{"monthlyLimit":10000,"used":-1}}`)
	got, err := quota.Normalize("xai", xai, "monthly")
	if err != nil || got.Remaining != nil {
		t.Fatalf("negative xai usage must stay unknown: %+v %v", got, err)
	}
	spent := []byte(`{"config":{"monthlyLimit":10000,"used":15000}}`)
	got, err = quota.Normalize("xai", spent, "monthly")
	if err != nil || got.Remaining == nil || *got.Remaining != 0 {
		t.Fatalf("xai over limit must be zero remaining: %+v %v", got, err)
	}
	got, err = quota.Normalize("xai", xai, "used-usd")
	if err != nil || got.Value != nil || got.Unit != "" {
		t.Fatalf("negative xai currency must stay unknown: %+v %v", got, err)
	}

	below := []byte(`{"groups":[{"buckets":[{"remainingFraction":-0.2}]}]}`)
	got, err = quota.Normalize("plugin", below, "bucket:0:0")
	if err == nil || got.Remaining != nil || got.Value != nil {
		t.Fatalf("unidentified plugin bucket must be unsupported: %+v %v", got, err)
	}
	above := []byte(`{"groups":[{"buckets":[{"remainingFraction":1.5}]}]}`)
	got, err = quota.Normalize("plugin", above, "bucket:0:0")
	if err == nil || got.Remaining != nil || got.Value != nil {
		t.Fatalf("unidentified plugin bucket must be unsupported: %+v %v", got, err)
	}
	credits := []byte(`{"summary":[{"key":"credits","label":"Credits","value":3,"unit":"credits"}]}`)
	got, err = quota.Normalize("plugin", credits, "summary-key:credits")
	if err != nil || got.Unit != "credits" || got.Value == nil || *got.Value != 3 || got.Remaining != nil {
		t.Fatalf("plugin unit must be preserved and not renamed: %+v %v", got, err)
	}
}

func TestParityFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../../Tests/ContractFixtures/quota-parity-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name, Provider string
		Body           json.RawMessage
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			switch tc.Name {
			case "codex-over-limit-primary-stays-independent":
				one, err := quota.Normalize(tc.Provider, tc.Body, "primary")
				if err != nil || one.Remaining == nil || *one.Remaining != 0 {
					t.Fatalf("primary: %+v %v", one, err)
				}
				two, err := quota.Normalize(tc.Provider, tc.Body, "secondary")
				if err != nil || two.Remaining == nil || math.Abs(*two.Remaining-0.91) > 1e-9 {
					t.Fatalf("secondary: %+v %v", two, err)
				}
			case "plugin-summary-only-is-not-zero-percent":
				got, err := quota.Normalize(tc.Provider, tc.Body, "summary-key:requests")
				if err != nil || got.Remaining != nil || got.Value == nil || *got.Value != 123 || got.Unit != "requests" {
					t.Fatalf("summary: %+v %v", got, err)
				}
			case "xai-monthly-percent-and-cents":
				got, err := quota.Normalize(tc.Provider, tc.Body, "monthly")
				if err != nil || got.Remaining == nil || *got.Remaining != 0.75 {
					t.Fatalf("monthly: %+v %v", got, err)
				}
				limit, err := quota.Normalize(tc.Provider, tc.Body, "monthly-limit-usd")
				if err != nil || limit.Value == nil || *limit.Value != 100 || limit.Unit != "USD" {
					t.Fatalf("limit: %+v %v", limit, err)
				}
				used, err := quota.Normalize(tc.Provider, tc.Body, "used-usd")
				if err != nil || used.Value == nil || *used.Value != 25 || used.Unit != "USD" {
					t.Fatalf("used: %+v %v", used, err)
				}
			case "plugin-window-with-missing-ratio-is-unknown":
				// Swift may display an unidentified bucket, but the monitor
				// cannot bind it to a stable system window. Do not infer a value.
				got, err := quota.Normalize(tc.Provider, tc.Body, "bucket:0:0")
				if err == nil || got.Remaining != nil || got.Value != nil {
					t.Fatalf("bucket: %+v %v", got, err)
				}
			default:
				t.Fatalf("unknown fixture %q", tc.Name)
			}
		})
	}
}
