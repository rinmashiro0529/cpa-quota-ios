package cpa

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A real loopback TLS fixture, matching the public Client seam. Handlers speak
// the Swift CPA management contract: plugin quota is a direct body, not an
// api-call envelope, and provider capability is a fixed GET.
func contractClient(t *testing.T, handler http.HandlerFunc, accounts []Account) (*Client, *atomic.Int64) {
	t.Helper()
	now := &atomic.Int64{}
	now.Store(1_800_000_000)
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	reserveFixtureServer(t, server)
	client, err := New(Config{
		BaseURL: server.URL, ManagementKey: "fixture-key", Accounts: accounts, Client: server.Client(),
		Now: func() time.Time { return time.Unix(now.Load(), 0).UTC() },
	})
	if err != nil {
		t.Fatal(err)
	}
	return client, now
}

func writeJSON(w http.ResponseWriter, body string) { _, _ = io.WriteString(w, body) }

func TestPluginDirectFetchDistinguishesReaderFromProvider(t *testing.T) {
	var sawProviders atomic.Bool
	var fetched atomic.Value
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v0/management/auth-files":
			writeJSON(w, `{"files":[{"id":"claude-account","auth_index":"auth-9","provider":"claude","supports_quota":true}]}`)
		case r.Method == http.MethodGet && r.URL.Path == "/v0/management/quota/providers":
			sawProviders.Store(true)
			writeJSON(w, `{"providers":[{"provider":"claude","supported_providers":["claude"]}]}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v0/management/quota/fetch":
			body, _ := io.ReadAll(r.Body)
			fetched.Store(string(body))
			writeJSON(w, `{"subscription":{"plan":"pro"},"summary":[{"key":"requests","value":1000,"unit":"requests"}]}`)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
		}
	}, []Account{{ID: "claude-account", Provider: "claude", Selection: "summary-key:requests", Reader: "plugin"}})

	got := client.Collect(context.Background())["claude-account"]
	if !sawProviders.Load() {
		t.Fatal("plugin collection never read the fixed quota/providers capability")
	}
	raw, _ := fetched.Load().(string)
	var request map[string]any
	if json.Unmarshal([]byte(raw), &request) != nil || request["auth_index"] != "auth-9" || request["url"] != nil || request["method"] != nil {
		t.Fatalf("plugin fetch was not the direct auth_index body: %s", raw)
	}
	if got.Status != "ok" || got.Result.Value == nil || *got.Result.Value != 1000 || got.Result.Unit != "requests" {
		t.Fatalf("plugin direct quota was not parsed: %+v", got)
	}
}

func TestPluginCapability404StillHonorsExplicitReader(t *testing.T) {
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v0/management/auth-files":
			writeJSON(w, `{"files":[{"id":"p","name":"plugin-name","auth_index":"ix","type":"freetier"}]}`)
		case "/v0/management/quota/providers":
			http.NotFound(w, r)
		case "/v0/management/quota/fetch":
			writeJSON(w, `{"summary":[{"key":"requests","value":25,"unit":"requests"}]}`)
		default:
			http.NotFound(w, r)
		}
	}, []Account{{ID: "p", Provider: "freetier", Selection: "summary-key:requests", Reader: "plugin"}})
	got := client.Collect(context.Background())["p"]
	if got.Status != "ok" || got.Result.Value == nil || *got.Result.Value != 25 || got.Result.Unit != "requests" {
		t.Fatalf("explicit plugin reader did not survive a missing capability endpoint: %+v", got)
	}
}

func TestPassiveObservedTimeIsNeverInvented(t *testing.T) {
	const inventory = `{"observed_at":"2026-10-25T10:03:42Z","files":[{"id":"c1","auth_index":"1","provider":"codex","id_token":{"chatgpt_account_id":"owner-1"},"quota":{"signals":{"X-Codex-Primary-Used-Percent":"47","X-Codex-Primary-Reset-At":"1792933413"}}}]}`
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v0/management/auth-files":
			writeJSON(w, inventory)
		case r.URL.Path == "/v0/management/api-call":
			w.WriteHeader(http.StatusBadGateway)
		default:
			http.NotFound(w, r)
		}
	}, []Account{{ID: "c1", Provider: "codex", Selection: "primary"}})
	got := client.Collect(context.Background())["c1"]
	if got.Result.Remaining != nil || got.ObservedAt != 0 {
		t.Fatal("signals without their own observation date must remain unavailable")
	}
	if got.ObservedAt == now.Load() || got.ObservedAt == 1_792_922_622 {
		t.Fatalf("missing quota observation was forged from now or the inventory list time: %d", got.ObservedAt)
	}
	if got.ObservedAt != 0 {
		t.Fatalf("a signal payload without observed_at was treated as observed: %d", got.ObservedAt)
	}
}

func TestPassiveCacheKeepsOriginalObservation(t *testing.T) {
	const observed = "2026-10-25T10:00:00Z"
	var calls atomic.Int32
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"c1","auth_index":"1","provider":"codex","quota":{"observed_at":"`+observed+`","signals":{"X-Codex-Primary-Used-Percent":"20"}}}]}`)
			return
		}
		calls.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	}, []Account{{ID: "c1", Provider: "codex", Selection: "primary"}})
	first := client.Collect(context.Background())["c1"]
	want := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC).Unix()
	if first.ObservedAt != want || first.ExpiresAt != 0 {
		t.Fatalf("passive observation was not preserved exactly: %+v", first)
	}
	now.Store(now.Load() + 10_000)
	second := client.Collect(context.Background())["c1"]
	if second.Status != "stale" || second.ObservedAt != want || second.ExpiresAt != 0 || second.Result.Remaining == nil || *second.Result.Remaining != 0.8 {
		t.Fatalf("failed refresh replaced the cached observation: %+v", second)
	}
	if calls.Load() < 2 {
		t.Fatal("cached passive value skipped the live refresh")
	}
}

func TestAuthIndexRotationDoesNotReuseCachedIdentity(t *testing.T) {
	var generation atomic.Int32
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			index := "auth-old"
			if generation.Load() > 0 {
				index = "auth-new"
			}
			writeJSON(w, `{"files":[{"id":"c1","auth_index":"`+index+`","provider":"codex"}]}`)
			return
		}
		var body struct {
			AuthIndex string `json:"auth_index"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.AuthIndex == "auth-old" {
			writeJSON(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":10}}}}`)
			return
		}
		w.WriteHeader(http.StatusBadGateway)
	}, []Account{{ID: "c1", Provider: "codex", Selection: "primary"}})
	first := client.Collect(context.Background())["c1"]
	if first.Status != "ok" || first.Result.Remaining == nil || math.Abs(*first.Result.Remaining-0.9) > 1e-9 {
		t.Fatalf("initial identity was not read: %+v", first)
	}
	generation.Store(1)
	rotated := client.Collect(context.Background())["c1"]
	if len(first.Identity) != 64 || len(rotated.Identity) != 64 || first.Identity == rotated.Identity {
		t.Fatal("selected readings did not expose distinct opaque identity fingerprints")
	}
	if rotated.Status == "stale" || rotated.Status == "ok" || (rotated.Result.Remaining != nil && *rotated.Result.Remaining == 0.9) {
		t.Fatalf("rotated auth_index reused the previous identity cache: %+v", rotated)
	}
}

func TestDisabledAccountDropsCachedIdentity(t *testing.T) {
	var disabled atomic.Bool
	var quotaCalls atomic.Int32
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			flag := "false"
			if disabled.Load() {
				flag = "true"
			}
			writeJSON(w, `{"files":[{"id":"c1","auth_index":"1","provider":"codex","disabled":`+flag+`}]}`)
			return
		}
		quotaCalls.Add(1)
		writeJSON(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":10}}}}`)
	}, []Account{{ID: "c1", Provider: "codex", Selection: "primary"}})
	if client.Collect(context.Background())["c1"].Status != "ok" {
		t.Fatal("enabled account was not read")
	}
	disabled.Store(true)
	before := quotaCalls.Load()
	got := client.Collect(context.Background())["c1"]
	if got.Status == "ok" || got.Status == "stale" || quotaCalls.Load() != before {
		t.Fatalf("disabled account kept or re-queried its old identity: %+v calls=%d", got, quotaCalls.Load())
	}
}

func TestCodexOwnerComesFromNestedIdentity(t *testing.T) {
	var owner atomic.Value
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"c1","auth_index":"1","provider":"codex","metadata":{"id_token":{"chatgpt_account_id":"meta-owner"}}}]}`)
			return
		}
		var body struct {
			Header map[string]string `json:"header"`
			URL    string            `json:"url"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		owner.Store(body.Header["Chatgpt-Account-Id"] + " " + body.URL)
		writeJSON(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":0}}}}`)
	}, []Account{{ID: "c1", Provider: "codex", Selection: "primary"}})
	if client.Collect(context.Background())["c1"].Status != "ok" {
		t.Fatal("codex read failed")
	}
	if owner.Load() != "meta-owner https://chatgpt.com/backend-api/wham/usage" {
		t.Fatalf("owner or target was not the fixed contract value: %v", owner.Load())
	}
}

func TestRetryAfterHTTPDateAndLongDelayAreNotShortened(t *testing.T) {
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"codex"}]}`)
			return
		}
		var body struct {
			AuthIndex string `json:"auth_index"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		header := "Sun, 06 Nov 1994 08:49:37 GMT"
		if body.AuthIndex == "2" {
			header = "7200"
		}
		writeJSON(w, `{"status_code":429,"header":{"Retry-After":"`+header+`"},"body":{}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "codex", Selection: "primary"}})
	got := client.Collect(context.Background())
	past := time.Date(1994, 11, 6, 8, 49, 37, 0, time.UTC).Unix()
	if got["a"].Status != "cooling_down" || got["a"].ExpiresAt != now.Load()+int64(defaultCooldown/time.Second) {
		t.Fatalf("an already elapsed HTTP date was not the safe default cooldown: %+v", got["a"])
	}
	if got["b"].Status != "cooling_down" || got["b"].ExpiresAt != now.Load()+7200 {
		t.Fatalf("a two hour Retry-After was shortened: %+v", got["b"])
	}
	if past >= now.Load() {
		t.Fatal("fixture date is not in the past")
	}
}

func TestFutureHTTPDateIsHonoredExactly(t *testing.T) {
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
			return
		}
		when := time.Unix(1_800_000_000, 0).UTC().Add(3 * time.Hour).Format(time.RFC1123)
		writeJSON(w, `{"status_code":429,"header":{"Retry-After":"`+when+`"},"body":{}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	got := client.Collect(context.Background())["a"]
	if got.Status != "cooling_down" || got.ExpiresAt != now.Load()+3*3600 {
		t.Fatalf("future HTTP Retry-After was not honored exactly: %+v", got)
	}
}

func TestOverflowingRetryAfterFailsSafe(t *testing.T) {
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
			return
		}
		writeJSON(w, `{"status_code":429,"header":{"Retry-After":"1e100"},"body":{}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	got := client.Collect(context.Background())["a"]
	if got.Status != "cooling_down" || got.ExpiresAt != now.Load()+int64(defaultCooldown/time.Second) {
		t.Fatalf("overflowing Retry-After was not the safe default: %+v", got)
	}
}

func sameOriginPair(t *testing.T, handler http.HandlerFunc, firstAccounts, secondAccounts []Account) (*Client, *Client, *atomic.Int64) {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	reserveFixtureServer(t, server)
	now := &atomic.Int64{}
	now.Store(1800000000)
	create := func(accounts []Account) *Client {
		client, err := New(Config{BaseURL: server.URL, ManagementKey: "fixture-key", Accounts: accounts, Client: server.Client(), Now: func() time.Time { return time.Unix(now.Load(), 0) }})
		if err != nil {
			t.Fatal(err)
		}
		return client
	}
	return create(firstAccounts), create(secondAccounts), now
}

func TestManagement429BlocksEveryManagementRequestOnOrigin(t *testing.T) {
	var calls atomic.Int32
	handler := func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Retry-After", "3600")
		w.WriteHeader(http.StatusTooManyRequests)
	}
	first, second, now := sameOriginPair(t, handler, []Account{{ID: "a", Provider: "codex", Selection: "primary"}}, []Account{{ID: "b", Provider: "xai", Selection: "monthly"}})
	if first.Collect(context.Background())["a"].ExpiresAt != now.Load()+3600 {
		t.Fatal("management 429 did not publish the shared deadline")
	}
	blocked := calls.Load()
	again := second.Collect(context.Background())["b"]
	if calls.Load() != blocked || again.Status != "cooling_down" || again.ExpiresAt != now.Load()+3600 {
		t.Fatalf("a second client bypassed the origin management block: %+v calls=%d/%d", again, calls.Load(), blocked)
	}
}

func TestAuthFailureStaysBlockedAcrossClients(t *testing.T) {
	var calls atomic.Int32
	handler := func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusForbidden)
	}
	first, second, now := sameOriginPair(t, handler, []Account{{ID: "a", Provider: "codex", Selection: "primary"}}, []Account{{ID: "b", Provider: "codex", Selection: "secondary"}})
	if first.Collect(context.Background())["a"].Status != "failed" {
		t.Fatal("403 did not fail closed")
	}
	blocked := calls.Load()
	now.Store(now.Load() + 48*3600)
	if second.Collect(context.Background())["b"].Status != "failed" || calls.Load() != blocked {
		t.Fatal("403 circuit was not permanent for the whole origin")
	}
}

func TestUpstream429StaysOnOneAccount(t *testing.T) {
	var calls atomic.Int32
	client, now := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"xai"}]}`)
			return
		}
		var body struct {
			AuthIndex string `json:"auth_index"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.AuthIndex == "1" {
			writeJSON(w, `{"status_code":429,"header":{"Retry-After":"600"},"body":{}}`)
			return
		}
		writeJSON(w, `{"status_code":200,"body":{"config":{"monthlyLimit":2000,"used":500}}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "xai", Selection: "monthly"}})
	first := client.Collect(context.Background())
	if first["a"].Status != "cooling_down" || first["a"].ExpiresAt != now.Load()+600 || first["b"].Status != "ok" {
		t.Fatalf("upstream 429 was not account scoped: %+v", first)
	}
	used := calls.Load()
	second := client.Collect(context.Background())
	if second["a"].Status != "cooling_down" || second["b"].Status != "ok" || calls.Load() <= used {
		t.Fatalf("sibling account was blocked by the upstream cooldown: %+v calls=%d", second, calls.Load())
	}
}

func TestSharedCapAndCancellationDoNotCloseTheSibling(t *testing.T) {
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	var mu sync.Mutex
	var paths []string
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"codex"},{"id":"c","auth_index":"3","provider":"codex"}]}`)
			return
		}
		started <- struct{}{}
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		writeJSON(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":0}}}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "codex", Selection: "primary"}, {ID: "c", Provider: "codex", Selection: "primary"}})

	ctx, cancel := context.WithCancel(context.Background())
	left := make(chan map[string]Reading, 1)
	right := make(chan map[string]Reading, 1)
	go func() { left <- client.Collect(ctx) }()
	waitFor(t, started, 3)
	go func() { right <- client.Collect(context.Background()) }()
	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case got := <-left:
		if got["a"].Status == "ok" {
			t.Fatal("cancelled collection reported success")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled collection did not return")
	}
	close(release)
	select {
	case got := <-right:
		if got["a"].Status != "ok" || got["c"].Status != "ok" {
			t.Fatalf("cancelling one waiter closed the shared collection: %+v", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the sibling collection was closed by the cancelled waiter")
	}
}

func TestRequestCancelDoesNotAbortAnotherRequest(t *testing.T) {
	entered := make(chan struct{})
	var once sync.Once
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
			return
		}
		first := false
		once.Do(func() { first = true })
		if first {
			close(entered)
			<-r.Context().Done()
			return
		}
		writeJSON(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":0}}}}`)
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		client.Collect(ctx)
		close(done)
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("first request never reached the fixture")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled request leaked its goroutine")
	}
	recovered := client.Collect(context.Background())["a"]
	if recovered.Status != "ok" {
		t.Fatalf("cancelling one request made the client unusable: %+v", recovered)
	}
}

func TestCollectionDeadlineBoundsASilentServer(t *testing.T) {
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			writeJSON(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
			return
		}
		<-r.Context().Done()
	}, []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	started := time.Now()
	got := client.Collect(ctx)["a"]
	if got.Status == "ok" || time.Since(started) > 5*time.Second {
		t.Fatalf("a silent upstream ignored the collection deadline: %+v after %s", got, time.Since(started))
	}
}

func TestCustomClientCannotReplaceTheDialer(t *testing.T) {
	server := httptest.NewUnstartedServer(http.NotFoundHandler())
	server.StartTLS()
	defer server.Close()
	transport := server.Client().Transport.(*http.Transport).Clone()
	transport.DialContext = nil
	transport.TLSClientConfig = &tls.Config{RootCAs: transport.TLSClientConfig.RootCAs, MinVersion: tls.VersionTLS12}
	cfg := Config{BaseURL: server.URL, ManagementKey: "fixture", Accounts: []Account{{ID: "a", Provider: "codex", Selection: "primary"}}, Client: &http.Client{Transport: transport, Jar: http.DefaultClient.Jar}}
	if _, err := New(cfg); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, started <-chan struct{}, count int) {
	t.Helper()
	for i := 0; i < count; i++ {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d of %d requests started", i, count)
		}
	}
}

func TestPluginObservationValidationAndRetainedCache(t *testing.T) {
	cases := []struct {
		name, fields string
		want         int64
		invalid      bool
	}{
		{"missing", "", 1800000000, false},
		{"historical", `,"observed_at":1799999900`, 1799999900, false},
		{"current", `,"observedAt":1800000000`, 1800000000, false},
		{"future boundary", `,"observed_at":1800000060`, 1800000060, false},
		{"matching aliases", `,"observed_at":1800000000,"observedAt":1800000000`, 1800000000, false},
		{"conflict", `,"observed_at":1800000000,"observedAt":1799999999`, 0, true},
		{"future", `,"observed_at":1800000061`, 0, true},
		{"zero", `,"observed_at":0`, 0, true},
		{"negative", `,"observed_at":-1`, 0, true},
		{"null", `,"observed_at":null`, 0, true},
		{"string", `,"observed_at":"1800000000"`, 0, true},
		{"fraction", `,"observed_at":1800000000.5`, 0, true},
		{"fraction below float precision", `,"observed_at":1800000000.00000001`, 0, true},
		{"milliseconds", `,"observed_at":1800000000000`, 0, true},
		{"huge", `,"observed_at":1e30`, 0, true},
		{"calendar bound", `,"observed_at":253402300800`, 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var phase atomic.Int32
			client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v0/management/auth-files":
					writeJSON(w, `{"files":[{"id":"p","auth_index":"ix","provider":"freetier"}]}`)
				case "/v0/management/quota/providers":
					http.NotFound(w, r)
				case "/v0/management/quota/fetch":
					if phase.Load() == 0 {
						writeJSON(w, `{"summary":[{"key":"requests","value":25,"unit":"requests"}],"observed_at":1799999900}`)
					} else {
						writeJSON(w, `{"summary":[{"key":"requests","value":50,"unit":"requests"}]`+tc.fields+`}`)
					}
				default:
					http.NotFound(w, r)
				}
			}, []Account{{ID: "p", Provider: "freetier", Selection: "summary-key:requests", Reader: "plugin"}})
			first := client.Collect(context.Background())["p"]
			if first.Status != "ok" {
				t.Fatalf("initial response: %+v", first)
			}
			phase.Store(1)
			got := client.Collect(context.Background())["p"]
			if tc.invalid {
				if got.Status != "stale" || got.ObservedAt != first.ObservedAt || got.ExpiresAt != first.ExpiresAt || got.Result.Value == nil || *got.Result.Value != 25 {
					t.Fatalf("invalid response did not preserve cache: first=%+v got=%+v", first, got)
				}
			} else if got.Status != "ok" || got.ObservedAt != tc.want || got.ExpiresAt != tc.want+600 || got.Result.Value == nil || *got.Result.Value != 50 {
				t.Fatalf("unexpected response: %+v", got)
			}
		})
	}
}

func TestInvalidPluginObservationWithoutCacheFails(t *testing.T) {
	client, _ := contractClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v0/management/auth-files":
			writeJSON(w, `{"files":[{"id":"p","auth_index":"ix","provider":"freetier"}]}`)
		case "/v0/management/quota/providers":
			http.NotFound(w, r)
		case "/v0/management/quota/fetch":
			writeJSON(w, `{"summary":[{"key":"requests","value":50,"unit":"requests"}],"observed_at":0}`)
		default:
			http.NotFound(w, r)
		}
	}, []Account{{ID: "p", Provider: "freetier", Selection: "summary-key:requests", Reader: "plugin"}})
	got := client.Collect(context.Background())["p"]
	if got.Status != "failed" || got.ObservedAt != 0 || got.ExpiresAt != 0 || got.Result.Value != nil {
		t.Fatalf("invalid uncached observation accepted: %+v", got)
	}
}
