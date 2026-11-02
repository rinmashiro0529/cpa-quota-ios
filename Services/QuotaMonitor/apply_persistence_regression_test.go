package monitor

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"icu.nahida/cpaquota/monitor/cpa"
)

type batchPersistence struct {
	mu    sync.Mutex
	body  []byte
	saves int
}

func (p *batchPersistence) Load() ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]byte(nil), p.body...), nil
}
func (p *batchPersistence) Save(b []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.saves++
	p.body = append([]byte(nil), b...)
	return nil
}
func (p *batchPersistence) reset() { p.mu.Lock(); defer p.mu.Unlock(); p.saves = 0 }
func (p *batchPersistence) result() (int, []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.saves, append([]byte(nil), p.body...)
}

func TestCollectionPersistsAllSessionSnapshotsOnce(t *testing.T) {
	for _, n := range []int{3, 16, 64} {
		t.Run(fmt.Sprint(n), func(t *testing.T) {
			base, clock, upstream := testService(t)
			options := base.options()
			store := &batchPersistence{}
			options.Store = store
			service, err := NewService(options)
			if err != nil {
				t.Fatal(err)
			}
			defer service.Close()
			value := 0.5
			upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "identity-one", Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
			for i := 0; i < n; i++ {
				body := registration()
				body["id"] = fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+1)
				body["activity_id"] = fmt.Sprintf("activity-%d", i)
				resp := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", body)
				if resp.StatusCode != http.StatusCreated {
					t.Fatalf("registration %d: %s", i, resp.Status)
				}
				resp.Body.Close()
			}
			store.reset()
			clock.Advance(10 * time.Minute)
			service.RunOnce(context.Background())
			saves, body := store.result()
			if saves != 1 {
				t.Fatalf("got %d snapshot writes for %d sessions, want 1", saves, n)
			}
			var state persisted
			if err := json.Unmarshal(body, &state); err != nil {
				t.Fatal(err)
			}
			if len(state.Sessions) != n {
				t.Fatalf("persisted %d sessions, want %d", len(state.Sessions), n)
			}
			for _, r := range state.Sessions {
				if r.Snapshot == nil || r.Snapshot.Sequence != 1 || r.NextRefresh == nil || r.Pending || r.AccountIdentities["fixture-upstream-account"] != "identity-one" {
					t.Fatalf("incomplete persisted snapshot: %+v", r)
				}
			}
		})
	}
}

type failingBatchPersistence struct {
	batchPersistence
	entered chan struct{}
	release chan struct{}
	fail    bool
}

func (p *failingBatchPersistence) Save(body []byte) error {
	if p.fail {
		close(p.entered)
		<-p.release
		return ErrStorage
	}
	return p.batchPersistence.Save(body)
}

func TestFailedBatchDoesNotDeliverAndFailsClosed(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &gatedNotifier{entered: make(chan struct{}, 8), release: make(chan struct{})}
	options.Notifier = notifier
	store := &failingBatchPersistence{entered: make(chan struct{}), release: make(chan struct{})}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	releaseSave := sync.OnceFunc(func() { close(store.release) })
	defer releaseSave()
	for i := 0; i < 3; i++ {
		body := registration()
		body["id"] = fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+1)
		body["activity_id"] = fmt.Sprintf("activity-%d", i)
		resp := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", body)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("registration %d: %s", i, resp.Status)
		}
		resp.Body.Close()
	}
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "identity-one", Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	store.fail = true
	clock.Advance(10 * time.Minute)
	done := make(chan struct{})
	go func() { service.RunOnce(context.Background()); close(done) }()
	select {
	case <-store.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("snapshot save did not start")
	}
	select {
	case <-notifier.entered:
		t.Fatal("update delivered before save completed")
	default:
	}
	releaseSave()
	<-done
	health := service.call(t, http.MethodGet, "/healthz", "", nil)
	if health.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("health status %s", health.Status)
	}
	health.Body.Close()
	before := upstream.Calls()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	if upstream.Calls() != before {
		t.Fatal("sampling continued after failed save")
	}
	service.Close()
	select {
	case <-notifier.entered:
		t.Fatal("failed batch delivered update")
	default:
	}
}

func TestNoActiveSessionDoesNotSaveOnRunOnce(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	store := &batchPersistence{}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	store.reset()
	service.RunOnce(context.Background())
	saves, _ := store.result()
	if saves != 0 {
		t.Fatalf("empty collection wrote %d times", saves)
	}
}

type gatedBatchPersistence struct {
	batchPersistence
	block   atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func (p *gatedBatchPersistence) Save(body []byte) error {
	if p.block.CompareAndSwap(true, false) {
		close(p.entered)
		<-p.release
	}
	return p.batchPersistence.Save(body)
}

func TestSuccessfulBatchNotifiesOnlyAfterDurableSnapshot(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &gatedNotifier{entered: make(chan struct{}, 8), release: make(chan struct{})}
	options.Notifier = notifier
	store := &gatedBatchPersistence{entered: make(chan struct{}), release: make(chan struct{})}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	releaseSave := sync.OnceFunc(func() { close(store.release) })
	defer releaseSave()
	defer close(notifier.release)
	for i := 0; i < 3; i++ {
		body := registration()
		body["id"] = fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+1)
		body["activity_id"] = fmt.Sprintf("activity-%d", i)
		resp := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", body)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("registration %d: %s", i, resp.Status)
		}
		resp.Body.Close()
	}
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "identity-one", Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	store.reset()
	store.block.Store(true)
	clock.Advance(10 * time.Minute)
	done := make(chan struct{})
	go func() { service.RunOnce(context.Background()); close(done) }()
	select {
	case <-store.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("snapshot save did not start")
	}
	select {
	case <-notifier.entered:
		t.Fatal("update delivered before save completed")
	default:
	}
	releaseSave()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("collection did not finish")
	}
	count, raw := store.result()
	if count != 1 {
		t.Fatalf("expected one durable snapshot save before notifier completion, got %d", count)
	}
	var state persisted
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		id := fmt.Sprintf("%08x-1111-4111-8111-111111111111", i+1)
		if state.Sessions[id].Snapshot == nil {
			t.Fatalf("missing durable snapshot %s", id)
		}
		response := service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+id, "bridge", nil)
		got := decodeSession(t, response)
		snap, ok := got["snapshot"].(map[string]any)
		if !ok || snap["sequence"] != float64(1) {
			t.Fatalf("missing readable snapshot %s: %+v", id, got)
		}
	}
	for i := 0; i < 3; i++ {
		select {
		case <-notifier.entered:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d notifications entered", i)
		}
	}
}

type loopbackCPACollector struct{ client *cpa.Client }

func (c loopbackCPACollector) Collect(ctx context.Context, _ string, _ []string) map[string]Reading {
	result := make(map[string]Reading)
	for id, r := range c.client.Collect(ctx) {
		result[id] = Reading{Identity: r.Identity, Remaining: r.Result.Remaining, Value: r.Result.Value, Unit: r.Result.Unit, Status: r.Status, ObservedAt: r.ObservedAt, ExpiresAt: r.ExpiresAt}
	}
	return result
}

func TestInvalidPluginTimeCannotPoisonServiceSnapshot(t *testing.T) {
	var phase atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v0/management/auth-files":
			_, _ = io.WriteString(w, `{"files":[{"id":"fixture-upstream-account","auth_index":"ix","provider":"freetier"}]}`)
		case "/v0/management/quota/providers":
			http.NotFound(w, r)
		case "/v0/management/quota/fetch":
			observed := "1800000000"
			if phase.Load() == 1 {
				observed = "1800000000000"
			}
			if phase.Load() == 2 {
				observed = "253402300800"
			}
			_, _ = io.WriteString(w, `{"summary":[{"key":"requests","value":25,"unit":"requests"}],"observed_at":`+observed+`}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	base, clock, _ := testService(t)
	options := base.options()
	account := &options.Config.Sources[0].Accounts[0]
	account.Provider = "freetier"
	account.Reader = "plugin"
	account.Selection = "summary-key:requests"
	account.Unit = "requests"
	client, err := cpa.New(cpa.Config{BaseURL: server.URL, ManagementKey: "synthetic", Accounts: []cpa.Account{{ID: "fixture-upstream-account", Provider: "freetier", Reader: "plugin", Selection: "summary-key:requests"}}, Client: server.Client(), Now: clock.Now})
	if err != nil {
		t.Fatal(err)
	}
	options.CPA = loopbackCPACollector{client}
	options.Store = &batchPersistence{}
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("registration: %s", response.Status)
	}
	response.Body.Close()
	for stage := 0; stage < 3; stage++ {
		phase.Store(int32(stage))
		clock.Advance(10 * time.Minute)
		service.RunOnce(context.Background())
		got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		snap, ok := got["snapshot"].(map[string]any)
		if !ok {
			t.Fatalf("stage %d missing snapshot: %+v", stage, got)
		}
		if snap["expires_at"] != float64(1800000600) {
			t.Fatalf("stage %d changed cached expiry: %+v", stage, snap)
		}
		accounts, ok := snap["accounts"].([]any)
		if !ok || len(accounts) != 1 {
			t.Fatalf("stage %d invalid accounts: %+v", stage, snap)
		}
		item, ok := accounts[0].(map[string]any)
		if !ok || item["observed_at"] != float64(1800000000) || item["value"] != float64(25) {
			t.Fatalf("stage %d changed cached value/time: %+v", stage, accounts)
		}
		if stage > 0 && item["status"] != "stale" {
			t.Fatalf("stage %d should retain stale reading: %+v", stage, item)
		}
	}
}
