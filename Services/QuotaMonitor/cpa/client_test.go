package cpa

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func fixtureClient(t *testing.T, handler http.Handler, accounts []Account) (*Client, *httptest.Server, *atomic.Int64) {
	t.Helper()
	now := &atomic.Int64{}
	now.Store(1_800_000_000)
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	client, err := New(Config{
		BaseURL: server.URL, ManagementKey: "fixture-key", Accounts: accounts, Client: server.Client(),
		Now: func() time.Time { return time.Unix(now.Load(), 0) },
	})
	if err != nil {
		t.Fatal(err)
	}
	return client, server, now
}

func TestCollectUsesAllowlistedAccountAndSafeReading(t *testing.T) {
	var sawAuth atomic.Bool
	client, _, _ := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer fixture-key" {
			sawAuth.Store(true)
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v0/management/auth-files":
			io.WriteString(w, `{"files":[{"id":"fixture-upstream-account","auth_index":"auth-7","provider":"codex"}]}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v0/management/api-call":
			var body struct {
				AuthIndex string `json:"auth_index"`
				URL       string `json:"url"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			if body.AuthIndex != "auth-7" || !strings.Contains(body.URL, "wham/usage") {
				t.Errorf("unexpected proxy request %+v", body)
			}
			io.WriteString(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":58}}}}`)
		default:
			http.NotFound(w, r)
		}
	}), []Account{{ID: "fixture-upstream-account", Provider: "codex", Selection: "primary"}})

	got := client.Collect(context.Background())
	reading := got["fixture-upstream-account"]
	if !sawAuth.Load() || reading.Status != "ok" || reading.Result.Remaining == nil || math.Abs(*reading.Result.Remaining-0.42) > 1e-9 || reading.ObservedAt != 1_800_000_000 {
		t.Fatalf("reading %+v auth=%v", reading, sawAuth.Load())
	}
	if strings.Contains(client.String(), "fixture-key") {
		t.Fatal("client string exposes the management key")
	}
}

func TestCollectCapsConcurrencyAndMergesSameOrigin(t *testing.T) {
	var current, peak atomic.Int32
	release := make(chan struct{})
	started := make(chan struct{}, 8)
	client, _, _ := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			io.WriteString(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"codex"},{"id":"c","auth_index":"3","provider":"codex"},{"id":"d","auth_index":"4","provider":"codex"}]}`)
			return
		}
		n := current.Add(1)
		for {
			old := peak.Load()
			if n <= old || peak.CompareAndSwap(old, n) {
				break
			}
		}
		started <- struct{}{}
		<-release
		current.Add(-1)
		io.WriteString(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":10}}}}`)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "codex", Selection: "primary"}, {ID: "c", Provider: "codex", Selection: "primary"}, {ID: "d", Provider: "codex", Selection: "primary"}})

	done := make(chan map[string]Reading, 2)
	go func() { done <- client.Collect(context.Background()) }()
	go func() { done <- client.Collect(context.Background()) }()
	for i := 0; i < 3; i++ {
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatal("collection did not reach the concurrency cap")
		}
	}
	time.Sleep(150 * time.Millisecond)
	if peak.Load() != 3 || len(started) != 0 {
		t.Fatalf("same-origin collections were not merged at the cap: peak=%d extra=%d", peak.Load(), len(started))
	}
	close(release)
	first, second := <-done, <-done
	if first["a"].Status != "ok" || second["d"].Status != "ok" {
		t.Fatalf("merged collection failed: %+v %+v", first["a"], second["d"])
	}
}

func TestAuthCircuitDoesNotReopenByTime(t *testing.T) {
	var calls atomic.Int32
	client, _, now := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	if client.Collect(context.Background())["a"].Status != "failed" {
		t.Fatal("401 was not a failure")
	}
	blocked := calls.Load()
	now.Store(1_800_000_000 + 48*3600)
	again := client.Collect(context.Background())
	if calls.Load() != blocked || again["a"].Status != "failed" {
		t.Fatal("401 circuit reopened on its own")
	}
}

func TestPersistentAuthCircuitAndScopedCooldown(t *testing.T) {
	var calls atomic.Int32
	client, _, _ := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path == "/v0/management/auth-files" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "xai", Selection: "monthly"}})
	first := client.Collect(context.Background())
	if first["a"].Status != "failed" || first["b"].Status != "failed" {
		t.Fatalf("auth failure was not shared: %+v", first)
	}
	after := calls.Load()
	second := client.Collect(context.Background())
	if calls.Load() != after || second["a"].Status != "failed" {
		t.Fatal("401 did not open a persistent circuit")
	}

	calls.Store(0)
	var mode atomic.Value
	mode.Store("quota")
	other, _, clock := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path == "/v0/management/auth-files" {
			io.WriteString(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"codex"}]}`)
			return
		}
		if mode.Load() == "quota" {
			w.Header().Set("Retry-After", "60")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		io.WriteString(w, `{"status_code":200,"body":{"rate_limit":{"secondary_window":{"used_percent":0}}}}`)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "codex", Selection: "secondary"}})
	cooled := other.Collect(context.Background())
	if cooled["a"].Status != "cooling_down" || cooled["a"].ExpiresAt != 1_800_000_060 || cooled["b"].Status != "cooling_down" {
		t.Fatalf("quota cooldown was not scoped to the account: %+v", cooled)
	}
	quotaCalls := calls.Load()
	mode.Store("ready")
	repeated := other.Collect(context.Background())
	if calls.Load() != quotaCalls || repeated["b"].Status != "cooling_down" {
		t.Fatal("429 cooldown did not suppress the same account")
	}
	clock.Store(1_800_000_061)
	recovered := other.Collect(context.Background())
	if recovered["b"].Status != "ok" || recovered["b"].Result.Remaining == nil || *recovered["b"].Result.Remaining != 1 {
		t.Fatalf("cooldown did not expire: %+v", recovered["b"])
	}
}

func TestUpstream429DoesNotBlockSiblingAccount(t *testing.T) {
	client, _, _ := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			io.WriteString(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"},{"id":"b","auth_index":"2","provider":"codex"}]}`)
			return
		}
		var body struct {
			AuthIndex string `json:"auth_index"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		if body.AuthIndex == "1" {
			io.WriteString(w, `{"status_code":429,"header":{"Retry-After":"60"},"body":{}}`)
			return
		}
		io.WriteString(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":0}}}}`)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "b", Provider: "codex", Selection: "primary"}})
	got := client.Collect(context.Background())
	if got["a"].Status != "cooling_down" || got["b"].Status != "ok" {
		t.Fatalf("upstream cooldown leaked across accounts: %+v", got)
	}
}

func TestCollectionCancelReleasesPermit(t *testing.T) {
	started := make(chan struct{})
	var first atomic.Bool
	client, _, _ := fixtureClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v0/management/auth-files" {
			io.WriteString(w, `{"files":[{"id":"a","auth_index":"1","provider":"codex"}]}`)
			return
		}
		if first.CompareAndSwap(false, true) {
			close(started)
			<-r.Context().Done()
			return
		}
		io.WriteString(w, `{"status_code":200,"body":{"rate_limit":{"primary_window":{"used_percent":0}}}}`)
	}), []Account{{ID: "a", Provider: "codex", Selection: "primary"}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan map[string]Reading, 1)
	go func() { done <- client.Collect(ctx) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("request never started")
	}
	cancel()
	select {
	case got := <-done:
		if got["a"].Status == "ok" {
			t.Fatal("cancelled collection reported success")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancellation did not release the collection")
	}
	recovered := client.Collect(context.Background())
	if recovered == nil {
		t.Fatal("client became unusable after cancellation")
	}
}

func TestCustomTrustIsLimitedToLoopback(t *testing.T) {
	pool := x509.NewCertPool()
	server := httptest.NewUnstartedServer(http.NotFoundHandler())
	server.StartTLS()
	defer server.Close()
	if !pool.AppendCertsFromPEM(server.Certificate().Raw) && server.Certificate() == nil {
		t.Fatal("fixture certificate unavailable")
	}
	host, port, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "https://"))
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() || port == "" {
		t.Fatal("fixture is not explicit loopback")
	}
	transport := server.Client().Transport.(*http.Transport)
	if transport.TLSClientConfig == nil || transport.TLSClientConfig.RootCAs == nil {
		transport = transport.Clone()
		transport.TLSClientConfig = &tls.Config{RootCAs: x509.NewCertPool(), MinVersion: tls.VersionTLS12}
	}
	cfg := Config{BaseURL: "https://example.invalid:443", ManagementKey: "k", Accounts: []Account{{ID: "a", Provider: "codex", Selection: "primary"}}, Client: &http.Client{Transport: transport}}
	if _, err := New(cfg); err == nil {
		t.Fatal("custom trust was accepted for a non-loopback origin")
	}
}
