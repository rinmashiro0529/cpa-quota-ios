package monitor

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"icu.nahida/cpaquota/monitor/apns"
)

const sessionID = "11111111-1111-4111-8111-111111111111"

func testService(t *testing.T) (*Service, *clock, *fakeCPA) {
	t.Helper()
	clock := &clock{now: time.Unix(1_800_000_000, 0)}
	upstream := &fakeCPA{}
	key := bytes.Repeat([]byte{9}, 32)
	store, err := OpenFileStore(filepath.Join(t.TempDir(), "state.enc"), key)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	cfg := validConfig()
	cfg.StatePath = store.path
	cfg.Principals = append(cfg.Principals, PrincipalConfig{ID: "other-phone", BearerTokenEnv: "TEST_OTHER_TOKEN", SourceAccounts: map[string][]string{"personal": {"fixture-upstream-account"}}})
	service, err := NewService(Options{Config: cfg, Store: store, Now: clock.Now, Tokens: map[string]string{"TEST_BRIDGE_TOKEN": "bridge", "TEST_OTHER_TOKEN": "other-bridge"}, Keys: map[string]string{"TEST_CPA_KEY": "fixture", "TEST_STATE_KEY": string(key)}, CPA: upstream})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Close)
	return service, clock, upstream
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type fakeCPA struct {
	mu       sync.Mutex
	readings map[string]Reading
	calls    int
	block    chan struct{}
	started  chan struct{}
}

func (f *fakeCPA) Collect(ctx context.Context, source string, accounts []string) map[string]Reading {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.started != nil {
		select {
		case f.started <- struct{}{}:
		default:
		}
	}
	if f.block != nil {
		block := f.block
		f.mu.Unlock()
		select {
		case <-block:
		case <-ctx.Done():
		}
		f.mu.Lock()
	}
	out := map[string]Reading{}
	for _, id := range accounts {
		reading := Reading{Status: "unavailable"}
		if f.readings != nil {
			if got, ok := f.readings[id]; ok {
				reading = got
			}
		}
		out[id] = reading
	}
	return out
}

func (s *Service) call(t *testing.T, method, path, token string, body any) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(encoded)
	}
	request := httptest.NewRequest(method, path, reader)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	s.Handler().ServeHTTP(response, request)
	return response.Result()
}

func decodeSession(t *testing.T, response *http.Response) map[string]any {
	t.Helper()
	defer response.Body.Close()
	var got map[string]any
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(got)
	if bytes.Contains(bytes.ToLower(encoded), []byte("push_token")) || bytes.Contains(encoded, []byte("bridge")) {
		t.Fatalf("response exposed a secret: %s", encoded)
	}
	return got
}

func registration() map[string]any {
	return map[string]any{"id": sessionID, "source_id": "personal", "account_ids": []string{"fixture-upstream-account"}, "duration_seconds": 14400, "activity_id": "fixture-activity", "push_token": "abcd"}
}

func TestRegistrationCanonicalizesJSONAndUUID(t *testing.T) {
	service, _, _ := testService(t)
	id := "aabbccdd-1122-4334-8abc-abcdefabcdef"
	body := `{"push_token":"abcd", "activity_id":"fixture-activity", "duration_seconds":14400, "account_ids":["fixture-upstream-account"], "source_id":"personal", "id":"AABBCCDD-1122-4334-8ABC-ABCDEFABCDEF"}`
	request := httptest.NewRequest(http.MethodPost, "/v1/monitoring/sessions", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer bridge")
	response := httptest.NewRecorder()
	service.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("standard UUID casing was rejected: %d", response.Code)
	}
	replay := registration()
	replay["id"] = id
	got := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", replay)
	if got.StatusCode != http.StatusCreated {
		t.Fatalf("equivalent JSON was not idempotent: %d", got.StatusCode)
	}
}

func TestOversizedActivityAliasesAreRejectedBeforeSessionAcceptance(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	var ids []string
	var accounts []AccountConfig
	for i := 0; i < 5; i++ {
		id := "quota-" + string(rune('a'+i))
		ids = append(ids, id)
		accounts = append(accounts, AccountConfig{ID: id, SafeID: strings.Repeat("s", 120) + string(rune('a'+i)), Label: strings.Repeat("L", 128), Provider: "codex", Selection: "primary", WindowID: strings.Repeat("w", 128), WindowLabel: strings.Repeat("W", 128), Unit: strings.Repeat("u", 128)})
	}
	options.Config.Sources[0].Accounts = accounts
	options.Config.Principals = options.Config.Principals[:1]
	options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": ids}
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	body := registration()
	body["account_ids"] = ids
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", body)
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatal("registration accepted aliases that cannot fit a system snapshot")
	}
}

func TestActivityBudgetIncludesSwiftEscapedUnitSlashes(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	var ids []string
	var accounts []AccountConfig
	for i := 0; i < 5; i++ {
		id := "quota-" + string(rune('a'+i))
		ids = append(ids, id)
		accounts = append(accounts, AccountConfig{ID: id, SafeID: id, Label: strings.Repeat("L", 100), Provider: "codex", Selection: "primary", WindowID: "primary", WindowLabel: strings.Repeat("W", 100), Unit: strings.Repeat("/", 128)})
	}
	options.Config.Sources[0].Accounts = accounts
	options.Config.Principals = options.Config.Principals[:1]
	options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": ids}
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	body := registration()
	body["account_ids"] = ids
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", body)
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatal("registration omitted escaped unit bytes from Swift content budget")
	}
}

func TestRegistrationIsIdempotentAndRejectsDifferentBody(t *testing.T) {
	service, _, _ := testService(t)
	first := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if first.StatusCode != http.StatusCreated && first.StatusCode != http.StatusOK {
		t.Fatalf("create status %d", first.StatusCode)
	}
	created := decodeSession(t, first)
	if created["revision"].(float64) != 1 || created["status"] != "active" || created["delivery_state"] == "sent" {
		t.Fatalf("initial session %#v", created)
	}
	repeat := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if repeat.StatusCode != first.StatusCode {
		t.Fatalf("idempotent replay status %d", repeat.StatusCode)
	}
	changed := registration()
	changed["activity_id"] = "other-activity"
	conflict := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", changed)
	if conflict.StatusCode != http.StatusConflict {
		t.Fatalf("different body status %d", conflict.StatusCode)
	}
}

func TestTokenRotationIsExpectedCurrentCAS(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	stale := service.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": strings.Repeat("cd", 16), "revision": 2})
	if stale.StatusCode != http.StatusConflict {
		t.Fatalf("stale revision status %d", stale.StatusCode)
	}
	rotated := service.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": strings.Repeat("cd", 16), "revision": 1})
	got := decodeSession(t, rotated)
	if rotated.StatusCode != http.StatusOK || got["revision"].(float64) != 2 {
		t.Fatalf("rotation %#v status %d", got, rotated.StatusCode)
	}
	overflow := service.call(t, http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", "bridge", map[string]any{"push_token": strings.Repeat("ef", 16), "revision": uint64(1<<64 - 1)})
	if overflow.StatusCode != http.StatusConflict {
		t.Fatalf("overflow status %d", overflow.StatusCode)
	}
}

func TestTokenRotationRejectsTrailingJSONWithoutAdvancingRevision(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	request := httptest.NewRequest(http.MethodPut, "/v1/monitoring/sessions/"+sessionID+"/token", strings.NewReader(`{"push_token":"aabb","revision":1} {"ignored":true}`))
	request.Header.Set("Authorization", "Bearer bridge")
	response := httptest.NewRecorder()
	service.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatal("token rotation accepted trailing JSON")
	}
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["revision"] != float64(1) {
		t.Fatal("invalid token request advanced revision")
	}
}

func TestUnknownDeleteWritesTombstoneAndBlocksLateCreate(t *testing.T) {
	service, _, _ := testService(t)
	unknown := strings.ToUpper(sessionID)
	removed := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+unknown, "bridge", nil)
	if removed.StatusCode != http.StatusNoContent || removed.ContentLength > 0 {
		body, _ := io.ReadAll(removed.Body)
		t.Fatalf("unknown delete status %d body %q", removed.StatusCode, body)
	}
	late := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if late.StatusCode != http.StatusGone && late.StatusCode != http.StatusNoContent && late.StatusCode != http.StatusConflict {
		t.Fatalf("late create after tombstone status %d", late.StatusCode)
	}
	again := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)
	if again.StatusCode != http.StatusNoContent {
		t.Fatalf("tombstone delete was not idempotent: %d", again.StatusCode)
	}
}

func TestForeignDeleteCannotReserveOrStopAnotherOwnersUUID(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	response := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "other-bridge", nil)
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("foreign delete status %d", response.StatusCode)
	}
	response.Body.Close()
	replay := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration())
	if replay.StatusCode != http.StatusCreated {
		t.Fatalf("foreign delete changed owner state: %d", replay.StatusCode)
	}
	replay.Body.Close()
}

func TestStopIsRevisionedAndDryRunNeverClaimsAPNsEnd(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	got := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["revision"] != float64(2) || got["delivery_state"] != "disabled" {
		t.Fatal("stop must advance control revision without claiming delivery")
	}
	again := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if again["revision"] != float64(2) {
		t.Fatal("repeated stop must remain idempotent")
	}
}

type endFailureNotifier struct {
	mu     sync.Mutex
	calls  int
	events chan string
}

func (n *endFailureNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	n.mu.Lock()
	n.calls++
	n.mu.Unlock()
	if n.events != nil {
		n.events <- event
	}
	return ErrUnavailable
}
func (n *endFailureNotifier) Calls() int { n.mu.Lock(); defer n.mu.Unlock(); return n.calls }

func TestEndWithoutSnapshotReportsFailureAndNeverClaimsEnded(t *testing.T) {
	base, _, _ := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &endFailureNotifier{}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	got := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["status"] != "stopped" || got["delivery_state"] != "failed" || notifier.Calls() != 1 {
		t.Fatal("stopping an unsampled activity must send end and expose failed delivery")
	}
}

type orderedNotifier struct {
	entered    chan string
	updateGate chan struct{}
	mu         sync.Mutex
	finished   []string
}

func (n *orderedNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	select {
	case n.entered <- event:
	case <-ctx.Done():
		return ctx.Err()
	}
	if event == "update" {
		select {
		case <-n.updateGate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	n.mu.Lock()
	n.finished = append(n.finished, event)
	n.mu.Unlock()
	return nil
}

type gatedNotifier struct {
	entered chan struct{}
	release chan struct{}
}

func (n *gatedNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	select {
	case n.entered <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case <-n.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestNewSnapshotCannotInheritPreviouslySentDelivery(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &gatedNotifier{entered: make(chan struct{}, 2), release: make(chan struct{})}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	defer close(notifier.release)
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	select {
	case <-notifier.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first update missing")
	}
	notifier.release <- struct{}{}
	deadline := time.Now().Add(2 * time.Second)
	for {
		got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		if got["delivery_state"] == "sent" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first update did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	select {
	case <-notifier.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("second update missing")
	}
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["delivery_state"] != "pending" {
		t.Fatal("new snapshot inherited the old delivery success")
	}
}

func TestStoppingSerializesEndAfterInFlightUpdate(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &orderedNotifier{entered: make(chan string, 4), updateGate: make(chan struct{})}
	var once sync.Once
	release := func() { once.Do(func() { close(notifier.updateGate) }) }
	defer release()
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	select {
	case event := <-notifier.entered:
		if event != "update" {
			t.Fatal("expected update")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("update never entered")
	}
	stopped := make(chan *http.Response, 1)
	go func() {
		stopped <- service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)
	}()
	select {
	case <-notifier.entered:
		release()
		(<-stopped).Body.Close()
		t.Fatal("end raced with an update that had not completed")
	case <-time.After(100 * time.Millisecond):
		release()
	}
	select {
	case response := <-stopped:
		response.Body.Close()
	case <-time.After(2 * time.Second):
		t.Fatal("stop never finished")
	}
	notifier.mu.Lock()
	defer notifier.mu.Unlock()
	if len(notifier.finished) != 2 || notifier.finished[0] != "update" || notifier.finished[1] != "end" {
		t.Fatal("delivery order was not update then end")
	}
}

type faultPersistence struct {
	mu   sync.Mutex
	body []byte
	fail bool
}

func (p *faultPersistence) Load() ([]byte, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]byte(nil), p.body...), nil
}
func (p *faultPersistence) Save(body []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.fail {
		return ErrStorage
	}
	p.body = append([]byte(nil), body...)
	return nil
}
func (p *faultPersistence) Fail() { p.mu.Lock(); p.fail = true; p.mu.Unlock() }

func TestDurabilityFailurePausesReadsAndSamplingUntilRecovery(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	store := &faultPersistence{}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	store.Fail()
	response := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("failed durable stop was accepted")
	}
	response.Body.Close()
	health := service.call(t, http.MethodGet, "/healthz", "", nil)
	if health.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("uncertain storage was still healthy")
	}
	health.Body.Close()
	before := upstream.Calls()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	if upstream.Calls() != before {
		t.Fatal("sampling continued after uncertain durable state")
	}
}

type retryEndNotifier struct{ calls int }

func (n *retryEndNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	n.calls++
	if n.calls == 1 {
		return ErrUnavailable
	}
	return nil
}
func TestRepeatedStopRetriesFailedEndWithoutChangingLeaseOrRevision(t *testing.T) {
	base, clock, _ := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &retryEndNotifier{}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	first := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	cooling := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if cooling["delivery_state"] != "failed" || notifier.calls != 1 {
		t.Fatal("repeated stop bypassed transport failure backoff")
	}
	clock.Advance(time.Minute)
	second := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if first["delivery_state"] != "failed" || second["delivery_state"] != "ended" || notifier.calls != 2 || first["revision"] != second["revision"] || first["expires_at"] != second["expires_at"] {
		t.Fatal("retry did not reconcile failed end idempotently")
	}
}

type throttledEndNotifier struct {
	mu        sync.Mutex
	calls     int
	completed chan struct{}
}

func (n *throttledEndNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, stale int64) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls++
	if n.calls == 1 {
		return &apns.HTTPError{Status: 429, RetryAfter: "120"}
	}
	select {
	case n.completed <- struct{}{}:
	default:
	}
	return nil
}
func (n *throttledEndNotifier) Calls() int { n.mu.Lock(); defer n.mu.Unlock(); return n.calls }
func TestEndRetryHonorsAPNsCooldownAcrossRepeatedDeleteAndRecovery(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &throttledEndNotifier{completed: make(chan struct{}, 1)}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	first := decodeSession(t, service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if first["delivery_state"] != "failed" {
		t.Fatal("rejected APNs end was reported as delivered")
	}
	service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil).Body.Close()
	if notifier.Calls() != 1 {
		t.Fatal("repeated delete bypassed APNs Retry-After")
	}
	service.Close()
	restored, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	clock.Advance(119 * time.Second)
	restored.RunOnce(context.Background())
	if notifier.Calls() != 1 {
		t.Fatal("recovery shortened persisted APNs cooldown")
	}
	clock.Advance(time.Second)
	restored.RunOnce(context.Background())
	select {
	case <-notifier.completed:
	case <-time.After(2 * time.Second):
		t.Fatal("due end retry never ran")
	}
	if upstream.Calls() != 0 {
		t.Fatal("APNs retry sampled a stopped source")
	}
}

func TestKnownDeleteReturnsStoppedSession(t *testing.T) {
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	removed := service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)
	got := decodeSession(t, removed)
	if removed.StatusCode != http.StatusOK || got["status"] == "active" {
		t.Fatalf("known delete %#v status %d", got, removed.StatusCode)
	}
}

func TestDuplicateBearerValuesCannotMergePrincipals(t *testing.T) {
	service, _, _ := testService(t)
	options := service.options()
	options.Tokens = map[string]string{"TEST_BRIDGE_TOKEN": "same-token", "TEST_OTHER_TOKEN": "same-token"}
	if _, err := NewService(options); err == nil {
		t.Fatal("duplicate bearer values must fail closed")
	}
}

func TestRestorationCannotKeepRevokedAccountLeaseActive(t *testing.T) {
	service, clock, upstream := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	options := service.options()
	second := options.Config.Sources[0].Accounts[0]
	second.ID, second.SafeID = "second-account", "account-2"
	options.Config.Sources[0].Accounts = append(options.Config.Sources[0].Accounts, second)
	options.Config.Principals[0].SourceAccounts = map[string][]string{"personal": {"second-account"}}
	service.Close()
	restored, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	clock.Advance(10 * time.Minute)
	before := upstream.Calls()
	restored.RunOnce(context.Background())
	if upstream.Calls() != before {
		t.Fatal("recovery sampled an account whose grant was revoked")
	}
}

func TestRestorationDoesNotRelabelCachedDataAfterWindowConfigurationChanges(t *testing.T) {
	service, clock, upstream := testService(t)
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	service.Close()
	options := service.options()
	options.Config.Sources[0].Accounts[0].WindowID = "other-window"
	restored, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	got := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	snapshot, ok := got["snapshot"].(map[string]any)
	if !ok || snapshot["phase"] != "stopped" || snapshot["sequence"] != float64(2) ||
		snapshot["accounts"].([]any)[0].(map[string]any)["window_id"] != "primary" {
		t.Fatal("changed source/window configuration lost or relabeled the last snapshot")
	}
	if got["status"] != "stopped" || got["revision"] != float64(2) || got["next_refresh_at"] != nil {
		t.Fatal("configuration change must end the previous semantic session")
	}
}

func TestAuthorizationIsolatesPrincipalsAndAccounts(t *testing.T) {
	service, _, _ := testService(t)
	if got := service.call(t, http.MethodGet, "/healthz", "", nil); got.StatusCode != http.StatusOK {
		t.Fatalf("health %d", got.StatusCode)
	}
	missing := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "", registration())
	if missing.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing token status %d", missing.StatusCode)
	}
	foreign := registration()
	foreign["account_ids"] = []string{"other-account"}
	if got := service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", foreign); got.StatusCode != http.StatusForbidden {
		t.Fatalf("unscoped account status %d", got.StatusCode)
	}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	other := service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "other-bridge", nil)
	if other.StatusCode != http.StatusNotFound && other.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-principal read status %d", other.StatusCode)
	}
}

func TestCollectionThatFinishesAfterLeaseCannotPublishReadyData(t *testing.T) {
	service, clock, upstream := testService(t)
	request := registration()
	request["duration_seconds"] = 3600
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", request).Body.Close()
	gate, entered := make(chan struct{}), make(chan struct{}, 1)
	value := 0.5
	upstream.mu.Lock()
	upstream.block, upstream.started = gate, entered
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &value, Status: "ok", ObservedAt: 1800000600, ExpiresAt: 1800001200}}
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	done := make(chan struct{})
	go func() { service.RunOnce(context.Background()); close(done) }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("collector did not enter")
	}
	clock.Advance(time.Hour)
	close(gate)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("collection did not finish")
	}
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["status"] != "expired" {
		t.Fatal("lease stayed active")
	}
	if snapshot, ok := got["snapshot"].(map[string]any); ok && snapshot["phase"] == "ready" {
		t.Fatal("late collection published ready content after lease expiry")
	}
}

func TestSchedulerEndsExpiredLeaseWithoutAnotherSourceRead(t *testing.T) {
	base, clock, upstream := testService(t)
	options := base.options()
	options.Config.DryRun = false
	options.Config.APNs = APNsConfig{TeamID: "TEAM", KeyID: "KEY", BundleID: "icu.nahida.fixture", Environment: "sandbox", PrivateKeyEnv: "TEST_APNS_KEY"}
	notifier := &endFailureNotifier{events: make(chan string, 2)}
	options.Notifier = notifier
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(4 * time.Hour)
	service.RunOnce(context.Background())
	select {
	case event := <-notifier.events:
		if event != "end" {
			t.Fatal("expired lease sent an update")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expired lease never sent end")
	}
	if upstream.Calls() != 0 {
		t.Fatal("expired lease sampled the source")
	}
}

func TestLeaseExpiresWithoutExtendingOnRecovery(t *testing.T) {
	service, clock, upstream := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(4 * time.Hour)
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if got["status"] != "expired" {
		t.Fatalf("expired lease stayed active: %#v", got)
	}
	before := upstream.Calls()
	service.RunOnce(context.Background())
	if upstream.Calls() != before {
		t.Fatal("expired session was collected")
	}
	reloaded, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	clock.Advance(-time.Minute)
	restored := decodeSession(t, reloaded.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	if restored["status"] != "expired" || restored["expires_at"].(float64) != got["expires_at"].(float64) {
		t.Fatalf("recovery extended the lease: %#v", restored)
	}
}

func (f *fakeCPA) Calls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.calls }

func TestRefreshDoesNotAcceptAnUndurablePendingIntent(t *testing.T) {
	base, _, upstream := testService(t)
	options := base.options()
	store := &faultPersistence{}
	options.Store = store
	service, err := NewService(options)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	store.Fail()
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions/"+sessionID+"/refresh", "bridge", nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("refresh accepted an intent it could not persist")
	}
	if upstream.Calls() != 0 {
		t.Fatal("refresh sampled after storage failure")
	}
}

func TestRefreshReturnsPendingWithoutClaimingDelivery(t *testing.T) {
	service, _, upstream := testService(t)
	remaining := 0.5
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &remaining, Status: "ok", ObservedAt: 1_800_000_000, ExpiresAt: 1_800_000_900}}
	upstream.block = make(chan struct{})
	upstream.mu.Unlock()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	response := service.call(t, http.MethodPost, "/v1/monitoring/sessions/"+sessionID+"/refresh", "bridge", nil)
	got := decodeSession(t, response)
	if response.StatusCode != http.StatusAccepted || got["delivery_state"] == "sent" || got["revision"].(float64) != 1 {
		t.Fatalf("refresh claimed completion: status %d %#v", response.StatusCode, got)
	}
	close(upstream.block)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
		if current["snapshot"] != nil {
			if current["revision"].(float64) != 1 || current["delivery_state"] != "disabled" {
				t.Fatalf("collection changed control state: %#v", current)
			}
			snapshot := current["snapshot"].(map[string]any)
			if snapshot["expires_at"].(float64) != 1_800_000_900 || snapshot["accounts"].([]any)[0].(map[string]any)["id"] != "account-1" {
				t.Fatalf("snapshot lost data expiry or safe alias: %#v", snapshot)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("refresh never published a cached snapshot")
}

func TestConcurrentManualRefreshMergesOneSourceRound(t *testing.T) {
	service, _, upstream := testService(t)
	gate, entered := make(chan struct{}), make(chan struct{}, 4)
	upstream.block, upstream.started = gate, entered
	var once sync.Once
	release := func() { once.Do(func() { close(gate) }) }
	defer release()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	service.call(t, http.MethodPost, "/v1/monitoring/sessions/"+sessionID+"/refresh", "bridge", nil).Body.Close()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first round did not start")
	}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions/"+sessionID+"/refresh", "bridge", nil).Body.Close()
	select {
	case <-entered:
		release()
		t.Fatal("same-source refresh started a duplicate round")
	case <-time.After(100 * time.Millisecond):
		release()
	}
}

func TestFailedSourceKeepsPriorValueAndObservationTime(t *testing.T) {
	service, clock, upstream := testService(t)
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "same-identity", Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "same-identity", Status: "failed"}}
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	snapshot := got["snapshot"].(map[string]any)
	account := snapshot["accounts"].([]any)[0].(map[string]any)
	if account["remaining_fraction"] != 0.5 || account["observed_at"] != float64(1800000000) || snapshot["expires_at"] != float64(1800000900) || account["status"] != "stale" {
		t.Fatal("failure lost the successful quota or invented a newer observation")
	}
}

func TestSourceUnitsCannotBeInventedOrRelabeled(t *testing.T) {
	for _, tc := range []struct {
		name, actual, configured string
		valid                    bool
	}{
		{"different semantics", "credits", "requests", false},
		{"missing source unit", "", "requests", false},
		{"source semantics retained", "credits", "", true},
		{"normal display punctuation", "requests / min", "requests / min", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base, clock, upstream := testService(t)
			options := base.options()
			options.Config.Sources[0].Accounts[0].Unit = tc.configured
			service, err := NewService(options)
			if err != nil {
				t.Fatal(err)
			}
			defer service.Close()
			value := 37.0
			upstream.readings = map[string]Reading{"fixture-upstream-account": {Value: &value, Unit: tc.actual, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
			service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
			clock.Advance(10 * time.Minute)
			service.RunOnce(context.Background())
			got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
			account := got["snapshot"].(map[string]any)["accounts"].([]any)[0].(map[string]any)
			if tc.valid {
				if account["value"] != 37.0 || account["unit"] != tc.actual {
					t.Fatal("source unit was not preserved")
				}
			} else if account["value"] != nil || account["unit"] != nil || account["status"] != "unavailable" {
				t.Fatal("unknown or mismatched source unit was displayed")
			}
		})
	}
}

func TestIdentityRotationCannotRefillOldValueAfterFailedNewRead(t *testing.T) {
	service, clock, upstream := testService(t)
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "first-identity", Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	service.Close()
	restored, err := NewService(service.options())
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Identity: "second-identity", Status: "failed"}}
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	restored.RunOnce(context.Background())
	got := decodeSession(t, restored.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	account := got["snapshot"].(map[string]any)["accounts"].([]any)[0].(map[string]any)
	if account["remaining_fraction"] != nil || account["observed_at"] != nil {
		t.Fatal("new identity inherited old value after durable recovery")
	}
	encoded, _ := json.Marshal(got)
	if bytes.Contains(encoded, []byte("identity")) {
		t.Fatal("internal identity fingerprint escaped into public response")
	}
}

func TestUnavailableAccountDoesNotReusePriorIdentityValue(t *testing.T) {
	service, clock, upstream := testService(t)
	value := 0.5
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &value, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Status: "unavailable"}}
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	got := decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil))
	account := got["snapshot"].(map[string]any)["accounts"].([]any)[0].(map[string]any)
	if account["remaining_fraction"] != nil || account["observed_at"] != nil || account["status"] != "unavailable" {
		t.Fatal("unavailable inventory entry inherited an older identity value")
	}
}

func TestSourceCacheUsesDataTimeNotUnrelatedSessionSequence(t *testing.T) {
	service, clock, upstream := testService(t)
	oldValue, newValue := 0.5, 0.25
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &oldValue, Status: "ok", ObservedAt: 1800000000, ExpiresAt: 1800000900}}
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	service.call(t, http.MethodDelete, "/v1/monitoring/sessions/"+sessionID, "bridge", nil).Body.Close()
	next := registration()
	next["id"] = "22222222-2222-4222-8222-222222222222"
	next["activity_id"] = "second-activity"
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", next).Body.Close()
	upstream.mu.Lock()
	upstream.readings = map[string]Reading{"fixture-upstream-account": {Remaining: &newValue, Status: "ok", ObservedAt: 1800001800, ExpiresAt: 1800002700}}
	upstream.mu.Unlock()
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	cached := decodeSession(t, service.call(t, http.MethodGet, "/v1/sources/personal/quota", "bridge", nil))
	if cached["accounts"].([]any)[0].(map[string]any)["remaining_fraction"] != 0.25 {
		t.Fatal("older session sequence hid newer source data")
	}
}

func TestSchedulerHonorsIntervalAndMergesSource(t *testing.T) {
	service, clock, upstream := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	second := registration()
	second["id"] = "22222222-2222-4222-8222-222222222222"
	second["activity_id"] = "second-activity"
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", second).Body.Close()
	before := upstream.Calls()
	service.RunOnce(context.Background())
	if upstream.Calls() != before {
		t.Fatal("scheduler collected before the interval")
	}
	clock.Advance(10 * time.Minute)
	service.RunOnce(context.Background())
	if upstream.Calls() != before+1 {
		t.Fatalf("same-source sessions were not merged: calls %d -> %d", before, upstream.Calls())
	}
}

func TestSharedContractFixtureDecodes(t *testing.T) {
	raw, err := os.ReadFile("../../Tests/ContractFixtures/monitoring-v1-session.json")
	if err != nil {
		t.Fatal(err)
	}
	var session struct {
		Version  int    `json:"version"`
		ID       string `json:"id"`
		Status   string `json:"status"`
		Snapshot struct {
			ExpiresAt int64 `json:"expires_at"`
			Accounts  []struct {
				ID    string `json:"id"`
				Label string `json:"label"`
			} `json:"accounts"`
		} `json:"snapshot"`
	}
	if json.Unmarshal(raw, &session) != nil || session.Version != 1 || session.Status != "active" || session.Snapshot.Accounts[0].ID != "account-1" || session.Snapshot.Accounts[0].Label != "账号1" {
		t.Fatalf("shared contract fixture rejected: %+v", session)
	}
	service, _, _ := testService(t)
	service.call(t, http.MethodPost, "/v1/monitoring/sessions", "bridge", registration()).Body.Close()
	encoded, _ := json.Marshal(decodeSession(t, service.call(t, http.MethodGet, "/v1/monitoring/sessions/"+sessionID, "bridge", nil)))
	for _, field := range []string{"source_id", "account_ids", "activity_id", "starts_at", "expires_at", "delivery_state", "revision"} {
		if !bytes.Contains(encoded, []byte(`"`+field+`"`)) {
			t.Fatalf("response missing contract field %s: %s", field, encoded)
		}
	}
}
