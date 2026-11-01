// Package cpa implements the fixed CPA management read protocol.
package cpa

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"icu.nahida/cpaquota/monitor/quota"
)

// Account identifies an inventory entry by its Swift-compatible id (id, then name,
// then auth_index). Provider is the real inventory provider. Reader selects the
// parser and transport. The positional constructor order is ID, Provider, Selection;
// Reader is optional and defaults from Provider.
type Account struct {
	ID, Provider, Selection string
	Reader                  string
}

// Config belongs to one fixed CPA source. Now must be safe for concurrent use.
// Client is a test seam restricted to explicit numeric loopback HTTPS + port.
type Config struct {
	BaseURL, ManagementKey string
	Accounts               []Account
	Client                 *http.Client
	Now                    func() time.Time
}

// Reading contains only a selected quota value, never the inventory or response.
// ObservedAt and ExpiresAt are Unix seconds; zero means unknown. ExpiresAt is a
// data freshness deadline, NOT a session lease. Cached values keep both timestamps.
type Reading struct {
	Identity   string
	Result     quota.Result
	ObservedAt int64
	Status     string
	ExpiresAt  int64
}

const (
	maximumAccounts = 3
	defaultCooldown = 60 * time.Second
)

type originState struct {
	mu          sync.Mutex
	blocked     bool
	inventory   map[string]inventoryEntry
	cooldown    map[string]time.Time
	originUntil time.Time
	cache       map[string]Reading
	inflight    *collection
	slots       chan struct{}
}

type inventoryEntry struct {
	authIndex, provider, owner string
	disabled                   bool
	passive                    map[string]Reading
}

type collection struct {
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	result  map[string]Reading
	callers int
}

// Origin coordinates every client that reads one CPA origin, so a second
// configured source cannot bypass its authentication circuit or cooldown.
type Origin struct {
	state    *originState
	slots    chan struct{}
	now      func() time.Time
	request  func(context.Context, string, string, []byte) (int, http.Header, []byte, error)
	accounts []Account
	base     *url.URL
}

var (
	originsMu sync.Mutex
	origins   = map[string]*originState{}
)

func (*Client) String() string { return "<CPA client>" }
func (Config) String() string  { return "<CPA config>" }

type Client struct {
	origin *Origin
}

func originFor(base *url.URL, now func() time.Time, request func(context.Context, string, string, []byte) (int, http.Header, []byte, error), accounts []Account) *Origin {
	key := monitorOrigin(base)
	originsMu.Lock()
	defer originsMu.Unlock()
	state := origins[key]
	if state == nil {
		state = &originState{cooldown: map[string]time.Time{}, cache: map[string]Reading{}, slots: make(chan struct{}, maximumAccounts)}
		origins[key] = state
	}
	return &Origin{state: state, slots: state.slots, now: now, request: request, accounts: accounts, base: base}
}

func monitorOrigin(base *url.URL) string {
	port := base.Port()
	if port == "" {
		port = "443"
	}
	return base.Scheme + "://" + base.Hostname() + ":" + port
}

func (c *Client) Collect(ctx context.Context) map[string]Reading {
	return c.origin.collect(ctx)
}

func (o *Origin) collect(ctx context.Context) map[string]Reading {
	if ctx.Err() != nil {
		return o.failed("unavailable")
	}
	o.state.mu.Lock()
	if o.state.blocked {
		o.state.mu.Unlock()
		return o.failed("failed")
	}
	current := o.state.inflight
	if current == nil {
		child, cancel := context.WithTimeout(context.Background(), collectionTimeout)
		current = &collection{ctx: child, cancel: cancel, done: make(chan struct{})}
		o.state.inflight = current
		go o.runCollection(current)
	}
	current.callers++
	o.state.mu.Unlock()
	select {
	case <-ctx.Done():
		o.detach(current)
		return o.failed("unavailable")
	case <-current.done:
		o.detach(current)
		if ctx.Err() != nil {
			return o.failed("unavailable")
		}
		return o.filter(current.result)
	}
}

func (o *Origin) runCollection(current *collection) {
	defer current.cancel()
	result := o.read(current.ctx)
	if current.ctx.Err() != nil {
		result = o.failed("unavailable")
	}
	o.state.mu.Lock()
	current.result = result
	if o.state.inflight == current {
		o.state.inflight = nil
	}
	close(current.done)
	o.state.mu.Unlock()
}

func (o *Origin) detach(current *collection) {
	o.state.mu.Lock()
	defer o.state.mu.Unlock()
	current.callers--
	if current.callers == 0 {
		current.cancel()
		if o.state.inflight == current {
			o.state.inflight = nil
		}
	}
}

func (o *Origin) filter(result map[string]Reading) map[string]Reading {
	out := make(map[string]Reading, len(o.accounts))
	for _, account := range o.accounts {
		reading, ok := result[account.ID]
		if !ok {
			reading = Reading{Status: "unavailable"}
		}
		out[account.ID] = reading
	}
	return out
}

func (o *Origin) failed(status string) map[string]Reading {
	out := make(map[string]Reading, len(o.accounts))
	for _, account := range o.accounts {
		out[account.ID] = Reading{Status: status}
	}
	return out
}

func (o *Origin) read(ctx context.Context) map[string]Reading {
	now := o.now()
	o.state.mu.Lock()
	if o.state.blocked {
		o.state.mu.Unlock()
		return o.failed("failed")
	}
	if now.Before(o.state.originUntil) {
		until := o.state.originUntil.Unix()
		o.state.mu.Unlock()
		out := o.failed("cooling_down")
		for id := range out {
			out[id] = Reading{Status: "cooling_down", ExpiresAt: until}
		}
		return out
	}
	cached := map[string]Reading{}
	var pending []Account
	for _, account := range o.accounts {
		if until, ok := o.state.cooldown[account.ID]; ok && now.Before(until) {
			cached[account.ID] = Reading{Status: "cooling_down", ExpiresAt: until.Unix()}
			continue
		}
		delete(o.state.cooldown, account.ID)
		pending = append(pending, account)
	}
	o.state.mu.Unlock()
	if len(pending) == 0 {
		return cached
	}
	if !o.ensureInventory(ctx) {
		o.state.mu.Lock()
		until, blocked := o.state.originUntil, o.state.blocked
		o.state.mu.Unlock()
		for _, account := range pending {
			if !blocked && now.Before(until) {
				cached[account.ID] = Reading{Status: "cooling_down", ExpiresAt: until.Unix()}
			} else {
				cached[account.ID] = o.retained(account, "failed")
			}
		}
		return cached
	}
	var group sync.WaitGroup
	var mu sync.Mutex
	for _, account := range pending {
		group.Add(1)
		go func(account Account) {
			defer group.Done()
			reading := o.readAccount(ctx, account)
			mu.Lock()
			cached[account.ID] = reading
			mu.Unlock()
		}(account)
	}
	group.Wait()
	return cached
}

func (o *Origin) ensureInventory(ctx context.Context) bool {
	status, header, body, err := o.exchange(ctx, http.MethodGet, "/auth-files", nil)
	if ctx.Err() != nil {
		return false
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		o.block()
		return false
	}
	if status == http.StatusTooManyRequests {
		o.coolOrigin(header)
		return false
	}
	if err != nil || status != http.StatusOK {
		return false
	}
	entries, ok := decodeInventory(body)
	if !ok {
		return false
	}
	o.state.mu.Lock()
	for id, previous := range o.state.inventory {
		current, exists := entries[id]
		if !exists || current.disabled || current.authIndex != previous.authIndex || current.owner != previous.owner || current.provider != previous.provider {
			for key := range o.state.cache {
				if strings.HasPrefix(key, id+"\x00") {
					delete(o.state.cache, key)
				}
			}
			delete(o.state.cooldown, id)
		}
	}
	o.state.inventory = entries
	o.state.mu.Unlock()
	for _, account := range o.accounts {
		if account.reader() != "plugin" {
			continue
		}
		status, header, _, _ := o.exchange(ctx, http.MethodGet, "/quota/providers", nil)
		if status == 401 || status == 403 {
			o.block()
			return false
		}
		if status == 429 {
			o.coolOrigin(header)
			return false
		}
		break
	}
	return true
}

func (o *Origin) block() {
	o.state.mu.Lock()
	o.state.blocked = true
	o.state.mu.Unlock()
}

func (o *Origin) readAccount(ctx context.Context, account Account) (reading Reading) {
	select {
	case o.slots <- struct{}{}:
		defer func() { <-o.slots }()
	case <-ctx.Done():
		return Reading{Status: "unavailable"}
	}
	o.state.mu.Lock()
	entry, ok := o.state.inventory[account.ID]
	blocked, deadline := o.state.blocked, o.state.originUntil
	o.state.mu.Unlock()
	if ok && !entry.disabled {
		body, _ := json.Marshal([]string{account.cacheKey(), entry.authIndex, entry.provider, entry.owner})
		hash := sha256.Sum256(body)
		identity := hex.EncodeToString(hash[:])
		defer func() { reading.Identity = identity }()
	}
	if ctx.Err() != nil {
		return Reading{Status: "unavailable"}
	}
	if blocked {
		return o.retained(account, "failed")
	}
	if deadline.After(o.now()) {
		return o.originReading()
	}
	reader := account.reader()
	if !ok || entry.authIndex == "" || entry.disabled || !strings.EqualFold(entry.provider, account.Provider) || reader == "" {
		return Reading{Status: "unavailable"}
	}
	body, err := requestBody(account, entry)
	if err != nil {
		return o.retained(account, "unavailable")
	}
	path := "/api-call"
	if reader == "plugin" {
		path = "/quota/fetch"
	}
	status, header, response, err := o.exchange(ctx, http.MethodPost, path, body)
	if ctx.Err() != nil {
		return o.retained(account, "unavailable")
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		o.block()
		return Reading{Status: "failed"}
	}
	if status == http.StatusTooManyRequests {
		o.coolOrigin(header)
		return o.originReading()
	}
	if err != nil || status != http.StatusOK {
		return o.retained(account, "failed")
	}
	payload, upstreamStatus, upstreamHeader, observed := response, 200, http.Header{}, int64(0)
	if reader != "plugin" {
		var ok bool
		payload, upstreamStatus, upstreamHeader, ok = unwrap(response)
		if !ok {
			return o.retained(account, "failed")
		}
	} else {
		var valid bool
		observed, valid = pluginObserved(response, o.now().Unix())
		if !valid {
			return o.retained(account, "failed")
		}
	}
	if upstreamStatus == http.StatusTooManyRequests {
		return o.cool(account.ID, upstreamHeader)
	}
	if upstreamStatus < 200 || upstreamStatus >= 300 {
		return o.retained(account, "failed")
	}
	result, err := quota.Normalize(reader, payload, account.Selection)
	if err != nil {
		return o.retained(account, "failed")
	}
	if observed == 0 {
		observed = o.now().Unix()
	}
	reading = Reading{Result: result, ObservedAt: observed, Status: "ok", ExpiresAt: observed + 600}
	o.remember(account, reading)
	return reading
}

func (o *Origin) retained(account Account, status string) Reading {
	o.state.mu.Lock()
	defer o.state.mu.Unlock()
	if cached, ok := o.state.cache[account.cacheKey()]; ok {
		cached.Status = "stale"
		return cached
	}
	entry, exists := o.state.inventory[account.ID]
	if exists && !entry.disabled && entry.provider == strings.ToLower(account.Provider) {
		if reading, ok := entry.passive[account.Selection]; ok {
			reading.Status = "stale"
			o.state.cache[account.cacheKey()] = reading
			return reading
		}
	}
	return Reading{Status: status}
}

func (o *Origin) remember(account Account, reading Reading) {
	o.state.mu.Lock()
	o.state.cache[account.cacheKey()] = reading
	o.state.mu.Unlock()
}

func (a Account) reader() string {
	reader := strings.ToLower(a.Reader)
	if reader == "" {
		reader = strings.ToLower(a.Provider)
	}
	switch reader {
	case "codex", "xai", "plugin":
		return reader
	default:
		return ""
	}
}

func (a Account) cacheKey() string {
	return a.ID + "\x00" + strings.ToLower(a.Provider) + "\x00" + a.reader() + "\x00" + a.Selection
}

func (o *Origin) coolOrigin(header http.Header) {
	until := o.deadline(header)
	o.state.mu.Lock()
	if until.After(o.state.originUntil) {
		o.state.originUntil = until
	}
	o.state.mu.Unlock()
}

func (o *Origin) originReading() Reading {
	o.state.mu.Lock()
	defer o.state.mu.Unlock()
	return Reading{Status: "cooling_down", ExpiresAt: o.state.originUntil.Unix()}
}

func (o *Origin) deadline(header http.Header) time.Time {
	now := o.now()
	for _, value := range header.Values("Retry-After") {
		if delay, ok := retryAfter(value, now); ok {
			return now.Add(delay)
		}
	}
	return now.Add(defaultCooldown)
}

func (o *Origin) cool(id string, header http.Header) Reading {
	until := o.deadline(header)
	o.state.mu.Lock()
	if current, ok := o.state.cooldown[id]; !ok || until.After(current) {
		o.state.cooldown[id] = until
	} else {
		until = current
	}
	o.state.mu.Unlock()
	return Reading{Status: "cooling_down", ExpiresAt: until.Unix()}
}

func retryAfter(value string, now time.Time) (time.Duration, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, false
	}
	if seconds, err := strconv.ParseFloat(trimmed, 64); err == nil && seconds >= 0 && !math.IsNaN(seconds) && !math.IsInf(seconds, 0) {
		if seconds < 1 {
			return time.Second, true
		}
		// Float64(MaxInt64) rounds up; accepting that boundary would overflow
		// time.Duration and turn a long cooldown into a deadline in the past.
		if seconds >= float64(math.MaxInt64)/float64(time.Second) {
			return 0, false
		}
		return time.Duration(seconds * float64(time.Second)), true
	}
	when, ok := httpDate(trimmed)
	if !ok && strings.Contains(trimmed, "T") {
		var err error
		when, err = time.Parse(time.RFC3339Nano, trimmed)
		ok = err == nil && when.Year() >= 1 && when.Year() <= 9999
	}
	if ok {
		if when.After(now) {
			return when.Sub(now), true
		}
		// A syntactically valid but elapsed server date still uses the local
		// minimum cooldown, rather than selecting a later array element.
		return defaultCooldown, true
	}
	return 0, false
}

func httpDate(value string) (time.Time, bool) {
	for _, layout := range []string{time.RFC1123, time.RFC850, time.ANSIC} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, true
		}
	}
	return time.Time{}, false
}

func (o *Origin) exchange(ctx context.Context, method, path string, body []byte) (int, http.Header, []byte, error) {
	return o.request(ctx, method, path, body)
}

func requestBody(account Account, entry inventoryEntry) ([]byte, error) {
	if account.reader() == "plugin" {
		return json.Marshal(map[string]string{"auth_index": entry.authIndex})
	}
	target := ""
	header := map[string]string{"Authorization": "Bearer $TOKEN$"}
	switch account.reader() {
	case "codex":
		target = "https://chatgpt.com/backend-api/wham/usage"
		header["Content-Type"] = "application/json"
		header["User-Agent"] = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
		if entry.owner != "" {
			header["Chatgpt-Account-Id"] = entry.owner
		}
	case "xai":
		target = "https://cli-chat-proxy.grok.com/v1/billing"
	default:
		return nil, errors.New("unsupported provider")
	}
	return json.Marshal(map[string]any{"auth_index": entry.authIndex, "method": "GET", "url": target, "header": header})
}

func decodeInventory(body []byte) (map[string]inventoryEntry, bool) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var root any
	if decoder.Decode(&root) != nil {
		return nil, false
	}
	files, _ := root.([]any)
	if files == nil {
		object, _ := root.(map[string]any)
		if object == nil {
			return nil, false
		}
		files, _ = object["files"].([]any)
	}
	if files == nil {
		return nil, false
	}
	out := make(map[string]inventoryEntry, len(files))
	for _, raw := range files {
		file, _ := raw.(map[string]any)
		if file == nil {
			continue
		}
		text := func(keys ...string) string {
			for _, key := range keys {
				if value, _ := file[key].(string); strings.TrimSpace(value) != "" {
					return strings.TrimSpace(value)
				}
			}
			return ""
		}
		id := text("id")
		if id == "" {
			id = text("name")
		}
		authIndex := text("auth_index", "authIndex")
		if id == "" {
			id = authIndex
		}
		if id == "" {
			continue
		}
		if _, exists := out[id]; exists {
			return nil, false
		}
		disabled := false
		if flag, ok := file["disabled"].(bool); ok {
			disabled = flag
		}
		if strings.EqualFold(text("status"), "disabled") {
			disabled = true
		}
		out[id] = inventoryEntry{authIndex: authIndex, provider: strings.ToLower(text("provider", "type")), owner: identityOwner(file), disabled: disabled, passive: passiveReadings(file)}
	}
	return out, true
}

func identityOwner(file map[string]any) string {
	candidates := []any{file["id_token"], file["idToken"]}
	for _, key := range []string{"metadata", "attributes"} {
		if container, ok := file[key].(map[string]any); ok {
			candidates = append(candidates, container["id_token"], container["idToken"], container)
		}
	}
	for _, candidate := range candidates {
		object, _ := candidate.(map[string]any)
		if object == nil {
			continue
		}
		for _, key := range []string{"chatgpt_account_id", "chatgptAccountId"} {
			if value, _ := object[key].(string); strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return ""
}

func pluginObserved(body []byte, now int64) (int64, bool) {
	var root map[string]json.RawMessage
	if json.Unmarshal(body, &root) != nil {
		return 0, false
	}
	var observed int64
	for _, key := range []string{"observed_at", "observedAt"} {
		raw, present := root[key]
		if !present {
			continue
		}
		value, err := strconv.ParseFloat(string(raw), 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) || value <= 0 || value >= 253402300800 || value > float64(now)+60 {
			return 0, false
		}
		exact, ok := new(big.Rat).SetString(string(raw))
		if !ok || !exact.IsInt() {
			return 0, false
		}
		seconds := exact.Num().Int64()
		if seconds <= 0 || seconds >= 253402300800 || seconds > now+60 || (observed != 0 && observed != seconds) {
			return 0, false
		}
		observed = seconds
	}
	return observed, true
}

func numberValue(value any) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case json.Number:
		parsed, err := typed.Float64()
		return parsed, err == nil
	default:
		return 0, false
	}
}

// Cached returns the last accepted reading without contacting CPA.
func (c *Client) Cached(account Account) (Reading, bool) {
	c.origin.state.mu.Lock()
	defer c.origin.state.mu.Unlock()
	reading, ok := c.origin.state.cache[account.cacheKey()]
	return reading, ok
}

func discard(body io.Reader) { _, _ = io.Copy(io.Discard, io.LimitReader(body, maximumBody+1)) }
