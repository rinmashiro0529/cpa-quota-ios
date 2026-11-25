package cpa

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

type envelopeFixture struct {
	Name     string          `json:"name"`
	Now      int64           `json:"now"`
	Envelope json.RawMessage `json:"envelope"`
	Expected struct {
		Valid        bool     `json:"valid"`
		Status       int      `json:"status"`
		RetrySeconds *float64 `json:"retry_after_seconds"`
	} `json:"expected"`
}

func envelopeFixtures(t *testing.T) []envelopeFixture {
	t.Helper()
	raw, err := os.ReadFile("../../../Tests/ContractFixtures/cpa-envelope-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []envelopeFixture
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatal(err)
	}
	if len(fixtures) == 0 {
		t.Fatal("shared envelope contract has no cases")
	}
	return fixtures
}

func TestSharedEnvelopeContract(t *testing.T) {
	for _, tc := range envelopeFixtures(t) {
		t.Run(tc.Name, func(t *testing.T) {
			payload, status, header, valid := unwrap(tc.Envelope)
			if valid != tc.Expected.Valid || status != tc.Expected.Status {
				t.Fatalf("envelope validity/status = %v/%d, want %v/%d", valid, status, tc.Expected.Valid, tc.Expected.Status)
			}
			if !valid {
				return
			}
			if status >= 200 && status < 300 && !json.Valid(payload) {
				t.Fatal("successful envelope did not return valid JSON")
			}
			var parsed *time.Duration
			for _, raw := range header.Values("Retry-After") {
				if delay, ok := retryAfter(raw, time.Unix(tc.Now, 0).UTC()); ok {
					parsed = &delay
					break
				}
			}
			if tc.Expected.RetrySeconds == nil {
				if parsed != nil {
					t.Fatalf("invented a server Retry-After: %v", *parsed)
				}
			} else if parsed == nil || math.Abs(parsed.Seconds()-*tc.Expected.RetrySeconds) > 1e-9 {
				t.Fatalf("Retry-After = %v, want %v seconds", parsed, *tc.Expected.RetrySeconds)
			}
		})
	}
}

func TestEnvelopeCooldownPreventsEarlyQuotaRequests(t *testing.T) {
	for _, tc := range envelopeFixtures(t) {
		if !tc.Expected.Valid || tc.Expected.Status != http.StatusTooManyRequests {
			continue
		}
		t.Run(tc.Name, func(t *testing.T) {
			var quotaCalls atomic.Int32
			client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v0/management/auth-files" {
					writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
					return
				}
				if r.URL.Path != "/v0/management/api-call" {
					t.Errorf("unexpected quota path %s", r.URL.Path)
					http.NotFound(w, r)
					return
				}
				quotaCalls.Add(1)
				_, _ = w.Write(tc.Envelope)
			}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
			now.Store(tc.Now)
			seconds := int64(defaultCooldown / time.Second)
			if tc.Expected.RetrySeconds != nil {
				seconds = int64(*tc.Expected.RetrySeconds)
			}
			first := client.Collect(context.Background())["a"]
			if first.Status != "cooling_down" || first.ExpiresAt != tc.Now+seconds || quotaCalls.Load() != 1 {
				t.Fatalf("first cooldown = %+v, calls = %d", first, quotaCalls.Load())
			}
			now.Store(tc.Now + seconds - 1)
			second := client.Collect(context.Background())["a"]
			if second.Status != "cooling_down" || second.ExpiresAt != first.ExpiresAt || quotaCalls.Load() != 1 {
				t.Fatalf("cooldown was shortened or skipped: %+v, calls = %d", second, quotaCalls.Load())
			}
			now.Store(tc.Now + seconds)
			client.Collect(context.Background())
			if quotaCalls.Load() != 2 {
				t.Fatalf("quota was not eligible at its deadline: calls = %d", quotaCalls.Load())
			}
		})
	}
}

func TestEnvelopeRejectsAmbiguousJSON(t *testing.T) {
	for _, body := range []string{
		`{"status_code":200,"body":{}} {}`,
		`null`, `[]`,
		`{"status_code":200,"body":"{} {}"}`,
		`{"status_code":200,"body":"null"}`,
		`{"status_code":1e1000,"body":{}}`,
	} {
		if _, _, _, ok := unwrap([]byte(body)); ok {
			t.Errorf("accepted ambiguous envelope %s", body)
		}
	}
}

func TestRetryAfterDurationOverflowCannotCreatePastDeadline(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	boundary := strconv.FormatFloat(float64(math.MaxInt64)/float64(time.Second), 'g', -1, 64)
	for _, value := range []string{boundary, "1e100", "NaN", "+Inf", "-1"} {
		if delay, ok := retryAfter(value, now); ok {
			t.Errorf("unrepresentable Retry-After %q accepted as %v", value, delay)
		}
	}
	origin := Origin{now: func() time.Time { return now }}
	if got := origin.deadline(http.Header{"Retry-After": {boundary}}); !got.Equal(now.Add(defaultCooldown)) {
		t.Fatalf("overflow deadline = %v, want safe local cooldown", got)
	}
}
