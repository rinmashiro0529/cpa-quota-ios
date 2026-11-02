package monitor

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	protocolVersion = 1
	maximumBody     = 64 * 1024
	staticReserve   = 512
	contentBudget   = 4096 - staticReserve
	roundTimeout    = 240 * time.Second
	refreshSpacing  = 600 * time.Second
)

var ErrUnavailable = errors.New("monitoring service unavailable")

// Reading is the source-neutral result consumed by the scheduler. It deliberately
// carries no inventory, URL, credential or raw response.
type Reading struct {
	Identity              string
	Remaining             *float64
	Value                 *float64
	Unit                  string
	Status                string
	ObservedAt, ExpiresAt int64
}

// Collector reads allowlisted accounts for one configured source.
type Collector interface {
	Collect(context.Context, string, []string) map[string]Reading
}

// Notifier delivers one activity update or end. Dry-run returns ErrDeliveryDisabled.
type Notifier interface {
	Notify(ctx context.Context, token, event string, state []byte, timestamp, staleDate int64) error
}

var ErrDeliveryDisabled = errors.New("delivery disabled")

type Options struct {
	Context  context.Context
	Config   Config
	Store    Persistence
	Now      func() time.Time
	Tokens   map[string]string
	Keys     map[string]string
	CPA      Collector
	Notifier Notifier
}

type Service struct {
	opt           Options
	mu            sync.Mutex
	state         persisted
	sources       map[string]SourceConfig
	tokens        map[string]principalAuth
	ctx           context.Context
	cancel        context.CancelFunc
	delivery      map[string]*deliveryGate
	failed        bool
	closed        bool
	workers       sync.WaitGroup
	rounds        map[string]*sourceRound
	lastRound     map[string]int64
	notifications map[string]bool
}

type principalAuth struct {
	id       string
	accounts map[string]map[string]bool
}

type persisted struct {
	Sessions   map[string]sessionRecord `json:"sessions"`
	Tombstones map[string]string        `json:"tombstones"`
}

type sessionRecord struct {
	Version           int               `json:"version"`
	ID                string            `json:"id"`
	Principal         string            `json:"principal"`
	SourceID          string            `json:"source_id"`
	AccountIDs        []string          `json:"account_ids"`
	ActivityID        string            `json:"activity_id"`
	PushToken         string            `json:"push_token"`
	StartsAt          int64             `json:"starts_at"`
	ExpiresAt         int64             `json:"expires_at"`
	NextRefresh       *int64            `json:"next_refresh_at,omitempty"`
	Status            string            `json:"status"`
	Revision          uint64            `json:"revision"`
	Delivery          string            `json:"delivery_state"`
	Snapshot          *snapshotRecord   `json:"snapshot,omitempty"`
	RequestHash       [32]byte          `json:"request_hash"`
	SourceConfigHash  [32]byte          `json:"source_config_hash"`
	AccountIdentities map[string]string `json:"account_identities,omitempty"`
	Pending           bool              `json:"pending"`
	DeliveryRetryAt   int64             `json:"delivery_retry_at,omitempty"`
	DeliveryAttempts  uint8             `json:"delivery_attempts,omitempty"`
	// Version 2 is a durable-record version only; the HTTP contract remains v1.
	// Older readers must fail closed instead of forgetting a token rejection.
	TokenInvalidReason string `json:"token_invalid_reason,omitempty"`
}

type snapshotRecord struct {
	Version     int             `json:"version"`
	Sequence    uint64          `json:"sequence"`
	Phase       string          `json:"phase"`
	GeneratedAt int64           `json:"generated_at"`
	ExpiresAt   int64           `json:"expires_at"`
	Accounts    []accountRecord `json:"accounts"`
}

type accountRecord struct {
	ID        string   `json:"id"`
	Label     string   `json:"label"`
	Provider  string   `json:"provider"`
	WindowID  string   `json:"window_id"`
	Window    string   `json:"window_label"`
	Remaining *float64 `json:"remaining_fraction,omitempty"`
	Value     *float64 `json:"value,omitempty"`
	Unit      string   `json:"unit,omitempty"`
	Observed  *int64   `json:"observed_at,omitempty"`
	Status    string   `json:"status"`
}

func NewService(opt Options) (*Service, error) {
	if opt.Now == nil {
		opt.Now = time.Now
	}
	if opt.Store == nil || opt.Config.Validate() != nil {
		return nil, ErrUnavailable
	}
	sources := make(map[string]SourceConfig, len(opt.Config.Sources))
	for _, source := range opt.Config.Sources {
		sources[source.ID] = source
	}
	tokens := map[string]principalAuth{}
	for _, principal := range opt.Config.Principals {
		secret := opt.Tokens[principal.BearerTokenEnv]
		if secret == "" {
			return nil, ErrUnavailable
		}
		if _, duplicate := tokens[secret]; duplicate {
			return nil, ErrUnavailable
		}
		accounts := map[string]map[string]bool{}
		for source, ids := range principal.SourceAccounts {
			accounts[source] = map[string]bool{}
			for _, id := range ids {
				accounts[source][id] = true
			}
		}
		tokens[secret] = principalAuth{id: principal.ID, accounts: accounts}
	}
	raw, err := opt.Store.Load()
	if err != nil {
		return nil, err
	}
	state := persisted{Sessions: map[string]sessionRecord{}, Tombstones: map[string]string{}}
	if len(raw) > 0 {
		if decodeStrict(raw, &state) != nil || state.Sessions == nil || state.Tombstones == nil {
			return nil, ErrUnavailable
		}
	}
	if err := validateCapacity(state, opt.Config.Capacity); err != nil {
		return nil, err
	}
	byID := map[string]principalAuth{}
	for _, principal := range tokens {
		byID[principal.id] = principal
	}
	changed := false
	for id, record := range state.Sessions {
		if id != record.ID || (record.Version != 1 && record.Version != 2) || record.Revision == 0 ||
			!validTokenFailure(record.TokenInvalidReason) || (record.TokenInvalidReason != "" && record.Version != 2) ||
			!validRegistration(record.ID, record.SourceID, record.AccountIDs, int(record.ExpiresAt-record.StartsAt), record.ActivityID, record.PushToken) {
			return nil, ErrUnavailable
		}
		principal, exists := byID[record.Principal]
		if !exists || !principal.allows(record.SourceID, record.AccountIDs) {
			redacted, err := revokedSnapshot(record.Snapshot, opt.Now().Unix())
			if err != nil {
				return nil, err
			}
			if record.Status != "stopped" || record.Delivery != "disabled" || record.NextRefresh != nil || record.Pending || redacted != record.Snapshot {
				record.Status, record.Delivery, record.NextRefresh, record.Snapshot = "stopped", "disabled", nil, redacted
				record.Pending = false
				if record.Revision < math.MaxUint64 {
					record.Revision++
				}
				state.Sessions[id] = record
				changed = true
			}
		} else if hash := sourceConfigHash(sources[record.SourceID]); hash != record.SourceConfigHash && record.Status == "active" {
			// A session owns the semantics accepted at registration. Never restart
			// its sequence or apply new window labels to an old observation.
			record.Status, record.NextRefresh, record.Pending = "stopped", nil, false
			record.Snapshot = terminalSnapshot(record.Snapshot, "stopped")
			if record.Revision < math.MaxUint64 {
				record.Revision++
			}
			record.Delivery = pendingDelivery(record, opt.Config.DryRun)
			state.Sessions[id] = record
			changed = true
		}
	}
	parent := opt.Context
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	service := &Service{opt: opt, state: state, sources: sources, tokens: tokens, ctx: ctx, cancel: cancel,
		delivery: map[string]*deliveryGate{}, rounds: map[string]*sourceRound{}, lastRound: map[string]int64{}, notifications: map[string]bool{}}
	for _, record := range state.Sessions {
		if record.Snapshot != nil && record.NextRefresh != nil {
			started := *record.NextRefresh - int64(refreshSpacing/time.Second)
			if started > service.lastRound[record.SourceID] {
				service.lastRound[record.SourceID] = started
			}
		}
	}
	if changed && service.persistLocked() != nil {
		cancel()
		return nil, ErrUnavailable
	}
	return service, nil
}

func sourceConfigHash(source SourceConfig) [32]byte {
	body, _ := json.Marshal(source)
	return sha256.Sum256(body)
}

func (s *Service) options() Options { return s.opt }

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/v1/monitoring/sessions", s.sessions)
	mux.HandleFunc("/v1/monitoring/sessions/", s.session)
	mux.HandleFunc("GET /v1/sources/{sourceID}/quota", s.quota)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		available := s.availableLocked()
		s.mu.Unlock()
		if !available {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Service) availableLocked() bool { return !s.failed && s.ctx.Err() == nil }

type registrationRequest struct {
	ID       string   `json:"id"`
	SourceID string   `json:"source_id"`
	Accounts []string `json:"account_ids"`
	Duration int      `json:"duration_seconds"`
	Activity string   `json:"activity_id"`
	Token    string   `json:"push_token"`
}

func decodeStrict(body []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return ErrUnavailable
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return ErrUnavailable
	}
	return nil
}

func (s *Service) sessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	principal, ok := s.authenticate(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	body, _, ok := readBody(w, r)
	if !ok {
		return
	}
	var request registrationRequest
	if decodeStrict(body, &request) != nil {
		http.Error(w, "invalid registration", http.StatusBadRequest)
		return
	}
	request.ID = strings.ToLower(request.ID)
	request.Token = strings.ToLower(request.Token)
	if !validRegistration(request.ID, request.SourceID, request.Accounts, request.Duration, request.Activity, request.Token) {
		http.Error(w, "invalid registration", http.StatusBadRequest)
		return
	}
	canonical, _ := json.Marshal(request)
	hash := sha256.Sum256(canonical)
	id := request.ID
	if !principal.allows(request.SourceID, request.Accounts) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, tombstoned := s.state.Tombstones[principal.id+"\x00"+id]; tombstoned {
		http.Error(w, "cancelled registration", http.StatusConflict)
		return
	}
	if existing, found := s.state.Sessions[id]; found {
		if existing.Principal != principal.id {
			http.NotFound(w, r)
			return
		}
		if subtle.ConstantTimeCompare(existing.RequestHash[:], hash[:]) != 1 {
			http.Error(w, "conflict", http.StatusConflict)
			return
		}
		s.expireLocked(&existing)
		if !s.availableLocked() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		writeJSON(w, http.StatusCreated, s.view(existing))
		return
	}
	now := s.opt.Now().Unix()
	next := now + int64(refreshSpacing/time.Second)
	record := sessionRecord{
		Version: protocolVersion, ID: id, Principal: principal.id, SourceID: request.SourceID,
		AccountIDs: append([]string(nil), request.Accounts...), ActivityID: request.Activity, PushToken: request.Token,
		StartsAt: now, ExpiresAt: now + int64(request.Duration), NextRefresh: &next, Status: "active",
		Revision: 1, Delivery: s.initialDelivery(), RequestHash: hash, SourceConfigHash: sourceConfigHash(s.sources[request.SourceID]),
	}
	if !s.registrationFits(record) {
		http.Error(w, "invalid activity payload", http.StatusBadRequest)
		return
	}
	if err := s.admitSessionLocked(principal.id, record); err != nil {
		http.Error(w, "capacity exhausted", http.StatusInsufficientStorage)
		return
	}
	s.state.Sessions[id] = record
	if s.persistLocked() != nil {
		delete(s.state.Sessions, id)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusCreated, s.view(record))
}

func (s *Service) session(w http.ResponseWriter, r *http.Request) {
	principal, ok := s.authenticate(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/v1/monitoring/sessions/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	id := strings.ToLower(parts[0])
	if !validUUID(id) {
		http.NotFound(w, r)
		return
	}
	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		s.readSession(w, r, principal, id)
	case len(parts) == 1 && r.Method == http.MethodDelete:
		s.deleteSession(w, r, principal, id)
	case len(parts) == 2 && parts[1] == "token" && r.Method == http.MethodPut:
		s.rotateToken(w, r, principal, id)
	case len(parts) == 2 && parts[1] == "refresh" && r.Method == http.MethodPost:
		s.refreshSession(w, r, principal, id)
	default:
		http.NotFound(w, r)
	}
}

func (s *Service) readSession(w http.ResponseWriter, r *http.Request, principal principalAuth, id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	record, found := s.visible(principal, id)
	if !found {
		http.NotFound(w, r)
		return
	}
	s.expireLocked(&record)
	if !s.availableLocked() {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, s.view(record))
}

func (s *Service) lockDelivery(ctx context.Context, id string) (func(), bool) {
	s.mu.Lock()
	if !s.availableLocked() {
		s.mu.Unlock()
		return nil, false
	}
	gate := s.delivery[id]
	if gate == nil {
		gate = &deliveryGate{token: make(chan struct{}, 1)}
		s.delivery[id] = gate
	}
	gate.users++
	s.mu.Unlock()
	release := func(acquired bool) {
		if acquired {
			<-gate.token
		}
		s.mu.Lock()
		gate.users--
		if gate.users == 0 {
			delete(s.delivery, id)
		}
		s.mu.Unlock()
	}
	select {
	case gate.token <- struct{}{}:
		return func() { release(true) }, true
	case <-ctx.Done():
		release(false)
		return nil, false
	case <-s.ctx.Done():
		release(false)
		return nil, false
	}
}

func (s *Service) deleteSession(w http.ResponseWriter, r *http.Request, principal principalAuth, id string) {
	release, ok := s.lockDelivery(r.Context(), id)
	if !ok {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	defer release()
	s.mu.Lock()
	record, found := s.visible(principal, id)
	if !found {
		if _, foreign := s.state.Sessions[id]; foreign {
			s.mu.Unlock()
			http.NotFound(w, r)
			return
		}
		key := principal.id + "\x00" + id
		if _, tombstoned := s.state.Tombstones[key]; tombstoned {
			s.mu.Unlock()
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if err := s.admitTombstoneLocked(principal.id, id); err != nil {
			s.mu.Unlock()
			http.Error(w, "capacity exhausted", http.StatusInsufficientStorage)
			return
		}
		s.state.Tombstones[key] = principal.id
		if s.persistLocked() != nil {
			delete(s.state.Tombstones, key)
			s.mu.Unlock()
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		s.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if record.Status != "active" {
		s.mu.Unlock()
		if record.Delivery == "failed" || record.Delivery == "pending" {
			s.sendNotification(record, "end")
		}
		s.mu.Lock()
		current := s.state.Sessions[id]
		if !s.availableLocked() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
		} else {
			writeJSON(w, http.StatusOK, s.view(current))
		}
		s.mu.Unlock()
		return
	}
	if record.Revision == math.MaxUint64 {
		s.mu.Unlock()
		http.Error(w, "conflict", http.StatusConflict)
		return
	}
	record.Status = "stopped"
	record.Revision++
	record.NextRefresh = nil
	record.Pending = false
	record.Snapshot = terminalSnapshot(record.Snapshot, "stopped")
	record.Delivery = pendingDelivery(record, s.opt.Config.DryRun)
	previous := s.state.Sessions[id]
	s.state.Sessions[id] = record
	if s.persistLocked() != nil {
		s.state.Sessions[id] = previous
		s.mu.Unlock()
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	s.cancelUnusedSourceLocked(record.SourceID)
	s.mu.Unlock()
	s.sendNotification(record, "end")
	s.mu.Lock()
	current := s.state.Sessions[id]
	if !s.availableLocked() {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	} else {
		writeJSON(w, http.StatusOK, s.view(current))
	}
	s.mu.Unlock()
}

func (s *Service) rotateToken(w http.ResponseWriter, r *http.Request, principal principalAuth, id string) {
	release, locked := s.lockDelivery(r.Context(), id)
	if !locked {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	defer release()
	body, _, ok := readBody(w, r)
	if !ok {
		return
	}
	var request struct {
		Token    string `json:"push_token"`
		Revision uint64 `json:"revision"`
	}
	if decodeStrict(body, &request) != nil || !validToken(request.Token) {
		http.Error(w, "invalid token", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, found := s.visible(principal, id)
	if found {
		s.expireLocked(&record)
	}
	if !s.availableLocked() {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	if !found || record.Status != "active" {
		http.NotFound(w, r)
		return
	}
	if request.Revision != record.Revision || record.Revision == math.MaxUint64 {
		http.Error(w, "conflict", http.StatusConflict)
		return
	}
	request.Token = strings.ToLower(request.Token)
	if record.TokenInvalidReason != "" && strings.EqualFold(request.Token, record.PushToken) {
		http.Error(w, "token unchanged", http.StatusConflict)
		return
	}
	previous := record
	record.PushToken = request.Token
	if record.TokenInvalidReason != "" {
		record.TokenInvalidReason = ""
		record.DeliveryRetryAt, record.DeliveryAttempts = 0, 0
	}
	record.Revision++
	record.Delivery = s.initialDelivery()
	s.state.Sessions[id] = record
	if s.persistLocked() != nil {
		s.state.Sessions[id] = previous
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, s.view(record))
}

func (s *Service) refreshSession(w http.ResponseWriter, r *http.Request, principal principalAuth, id string) {
	s.mu.Lock()
	record, found := s.visible(principal, id)
	if !found {
		s.mu.Unlock()
		http.NotFound(w, r)
		return
	}
	s.expireLocked(&record)
	if !s.availableLocked() {
		s.mu.Unlock()
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	if record.Status == "active" {
		record.Pending = true
		record.Delivery = pendingDelivery(record, s.opt.Config.DryRun)
		s.state.Sessions[id] = record
		if s.persistLocked() != nil {
			s.mu.Unlock()
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
	}
	view := s.view(record)
	s.mu.Unlock()
	writeJSON(w, http.StatusAccepted, view)
	if record.Status == "active" {
		s.startCollections([]string{id})
	}
}

func (s *Service) quota(w http.ResponseWriter, r *http.Request) {
	principal, ok := s.authenticate(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	sourceID := r.PathValue("sourceID")
	if !identifier(sourceID) || principal.accounts[sourceID] == nil {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var newest *snapshotRecord
	configuration := sourceConfigHash(s.sources[sourceID])
	for _, record := range s.state.Sessions {
		if record.Principal == principal.id && record.SourceID == sourceID && record.SourceConfigHash == configuration && record.Snapshot != nil && (newest == nil || record.Snapshot.GeneratedAt > newest.GeneratedAt ||
			(record.Snapshot.GeneratedAt == newest.GeneratedAt && record.Snapshot.Sequence > newest.Sequence)) {
			newest = record.Snapshot
		}
	}
	if newest == nil {
		http.Error(w, "no cached quota", http.StatusNotFound)
		return
	}
	filtered := *newest
	filtered.Accounts = nil
	for _, account := range newest.Accounts {
		if s.accountAllowed(principal, sourceID, account.ID) {
			filtered.Accounts = append(filtered.Accounts, account)
		}
	}
	encoded, err := json.Marshal(filtered)
	if err != nil || len(filtered.Accounts) < 1 || len(filtered.Accounts) > 5 || len(encoded) > 3584 {
		http.Error(w, "no cached quota", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, filtered)
}

func (s *Service) authenticate(r *http.Request) (principalAuth, bool) {
	header := r.Header.Get("Authorization")
	secret, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || secret == "" || strings.Contains(secret, " ") {
		return principalAuth{}, false
	}
	for configured, principal := range s.tokens {
		if subtle.ConstantTimeCompare([]byte(configured), []byte(secret)) == 1 {
			return principal, true
		}
	}
	return principalAuth{}, false
}

func (s *Service) visible(principal principalAuth, id string) (sessionRecord, bool) {
	record, found := s.state.Sessions[id]
	return record, found && record.Principal == principal.id
}

func (s *Service) expireLocked(record *sessionRecord) {
	if record.Status == "active" && s.opt.Now().Unix() >= record.ExpiresAt {
		previous := *record
		record.Status = "expired"
		record.NextRefresh = nil
		record.Pending = false
		record.Delivery = pendingDelivery(*record, s.opt.Config.DryRun)
		if record.Revision < math.MaxUint64 {
			record.Revision++
		}
		record.Snapshot = terminalSnapshot(record.Snapshot, "expired")
		s.state.Sessions[record.ID] = *record
		if s.persistLocked() != nil {
			s.state.Sessions[record.ID] = previous
			*record = previous
			return
		}
		s.cancelUnusedSourceLocked(record.SourceID)
		s.queueNotificationLocked(*record, "end")
	}
}

func (s *Service) initialDelivery() string {
	if s.opt.Config.DryRun {
		return "disabled"
	}
	return "pending"
}

func (s *Service) view(record sessionRecord) map[string]any {
	out := map[string]any{
		"version": protocolVersion, "id": record.ID, "source_id": record.SourceID, "account_ids": record.AccountIDs,
		"activity_id": record.ActivityID, "starts_at": record.StartsAt, "expires_at": record.ExpiresAt,
		"status": record.Status, "revision": record.Revision, "delivery_state": record.Delivery,
	}
	if record.NextRefresh != nil {
		out["next_refresh_at"] = *record.NextRefresh
	}
	if record.Snapshot != nil {
		out["snapshot"] = record.Snapshot
	}
	return out
}

func (s *Service) persistLocked() error {
	if !s.availableLocked() {
		return ErrStorage
	}
	encoded, err := json.Marshal(s.state)
	if err == nil {
		err = s.opt.Store.Save(encoded)
	}
	if err != nil {
		s.failed = true
		s.cancel()
		return ErrStorage
	}
	return nil
}

func (s *Service) accountAllowed(principal principalAuth, source, safeID string) bool {
	configured := s.sources[source]
	for _, account := range configured.Accounts {
		if account.SafeID == safeID && principal.accounts[source][account.ID] {
			return true
		}
	}
	return false
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, [32]byte, bool) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maximumBody+1))
	if err != nil || len(body) > maximumBody {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return nil, [32]byte{}, false
	}
	return body, sha256.Sum256(body), true
}

func (p principalAuth) allows(source string, accounts []string) bool {
	allowed := p.accounts[source]
	if allowed == nil {
		return false
	}
	seen := map[string]bool{}
	for _, id := range accounts {
		if !allowed[id] || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

func validRegistration(id, source string, accounts []string, duration int, activity, token string) bool {
	if !validUUID(id) || id != strings.ToLower(id) || !identifier(source) || len(accounts) < 1 || len(accounts) > 5 {
		return false
	}
	if duration != 3600 && duration != 14400 && duration != 28800 || !validActivity(activity) || !validToken(token) {
		return false
	}
	for _, account := range accounts {
		if !accountID(account) {
			return false
		}
	}
	return true
}

func validUUID(value string) bool {
	parts := strings.Split(value, "-")
	groups := []int{8, 4, 4, 4, 12}
	if len(parts) != len(groups) {
		return false
	}
	for i, part := range parts {
		if len(part) != groups[i] {
			return false
		}
		for _, r := range part {
			if !strings.ContainsRune("0123456789abcdef", r) {
				return false
			}
		}
	}
	return true
}

func validActivity(value string) bool {
	return value != "" && len(value) <= 256 && strings.IndexFunc(value, unicode.IsControl) < 0
}

func validToken(value string) bool {
	if len(value) == 0 || len(value) > 4096 || len(value)%2 != 0 {
		return false
	}
	for _, r := range value {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return false
		}
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// Schedule runs collection rounds until ctx ends. The production interval is 600
// seconds; tests may supply a shorter one. Each round keeps its own deadline.
func (s *Service) Schedule(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(s.scanInterval(interval))
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			// Collection is owned by one worker per source. The scanner never
			// waits for that worker, so lease/retry deadlines remain independent.
			s.startCollections(s.scanDue())
		}
	}
}

// RunOnce collects every active session whose lease and schedule are due.
// Collection never changes session.revision; only a control-plane change does.
func (s *Service) RunOnce(ctx context.Context) {
	s.collect(ctx, s.scanDue())
}

func (s *Service) scanDue() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.availableLocked() {
		return nil
	}
	var due []string
	now := s.opt.Now()
	for id, record := range s.state.Sessions {
		s.expireLocked(&record)
		if (record.Delivery == "pending" || (record.Delivery == "failed" && record.DeliveryRetryAt > 0)) && record.DeliveryRetryAt <= now.Unix() {
			event := "update"
			if record.Status != "active" {
				event = "end"
			}
			if event == "end" || record.Snapshot != nil {
				s.queueNotificationLocked(record, event)
			}
		}
		if record.Status != "active" || now.Unix() >= record.ExpiresAt {
			continue
		}
		if record.NextRefresh != nil && now.Unix() >= *record.NextRefresh {
			due = append(due, id)
		}
	}
	return due
}

func (s *Service) apply(source string, ids []string, readings map[string]Reading) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.availableLocked() {
		return
	}
	previous := make(map[string]sessionRecord)
	updates := make(map[string]sessionRecord)
	for _, id := range ids {
		record, found := s.state.Sessions[id]
		if !found || record.Status != "active" || record.SourceID != source {
			continue
		}
		if s.opt.Now().Unix() >= record.ExpiresAt {
			s.expireLocked(&record)
			if !s.availableLocked() {
				return
			}
			continue
		}
		snapshot := s.snapshot(record, readings)
		if snapshot == nil {
			continue
		}
		sequence := uint64(1)
		if record.Snapshot != nil {
			if record.Snapshot.Sequence == math.MaxUint64 {
				// No representable content version remains. Preserve the final
				// observation instead of wrapping to zero; the lease still ends.
				continue
			}
			sequence = record.Snapshot.Sequence + 1
		}
		snapshot.Sequence = sequence
		previous[id] = record
		identities := make(map[string]string, len(record.AccountIdentities))
		for account, identity := range record.AccountIdentities {
			identities[account] = identity
		}
		record.AccountIdentities = identities
		for _, account := range record.AccountIDs {
			if identity := readings[account].Identity; identity != "" {
				record.AccountIdentities[account] = identity
			}
		}
		record.Snapshot = snapshot
		record.Delivery = pendingDelivery(record, s.opt.Config.DryRun)
		record.Pending = false
		next := s.lastRound[source] + int64(refreshSpacing/time.Second)
		if s.lastRound[source] == 0 {
			next = s.opt.Now().Unix() + int64(refreshSpacing/time.Second)
		}
		record.NextRefresh = &next
		updates[id] = record
	}
	if len(updates) == 0 {
		return
	}
	for id, record := range updates {
		s.state.Sessions[id] = record
	}
	if s.persistLocked() != nil {
		for id, record := range previous {
			s.state.Sessions[id] = record
		}
		return
	}
	for _, record := range updates {
		s.queueNotificationLocked(record, "update")
	}
}

func (s *Service) snapshot(record sessionRecord, readings map[string]Reading) *snapshotRecord {
	configured := map[string]AccountConfig{}
	for _, account := range s.sources[record.SourceID].Accounts {
		configured[account.ID] = account
	}
	out := &snapshotRecord{Version: protocolVersion, Phase: "ready", GeneratedAt: s.opt.Now().Unix()}
	var earliest int64
	for _, id := range record.AccountIDs {
		account := configured[id]
		reading := readings[id]
		unit := safeUnit(reading.Unit, account.Unit)
		if unit == "" && (reading.Unit != "" || reading.Value != nil) {
			reading = Reading{Status: "unavailable"}
		}
		sameIdentity := reading.Identity == "" || record.AccountIdentities[id] == reading.Identity
		if sameIdentity && reading.Status != "ok" && reading.Status != "unavailable" && reading.Remaining == nil && reading.Value == nil && record.Snapshot != nil {
			for _, old := range record.Snapshot.Accounts {
				if old.ID == account.SafeID && (old.Remaining != nil || old.Value != nil) {
					reading.Remaining, reading.Value, reading.Unit = old.Remaining, old.Value, old.Unit
					if old.Observed != nil {
						reading.ObservedAt = *old.Observed
					}
					reading.ExpiresAt, reading.Status = record.Snapshot.ExpiresAt, "stale"
					break
				}
			}
		}
		status := reading.Status
		if status == "" {
			status = "unavailable"
		}
		item := accountRecord{ID: account.SafeID, Label: account.Label, Provider: account.Provider, WindowID: account.WindowID, Window: account.WindowLabel, Status: status, Unit: safeUnit(reading.Unit, account.Unit)}
		if reading.ObservedAt > 0 {
			item.Observed = &reading.ObservedAt
		}
		if reading.Remaining != nil {
			item.Remaining = reading.Remaining
		}
		if reading.Value != nil {
			item.Value = reading.Value
		}
		if status != "ok" && out.Phase == "ready" {
			out.Phase = "partial"
		}
		if reading.ExpiresAt > 0 && (earliest == 0 || reading.ExpiresAt < earliest) {
			earliest = reading.ExpiresAt
		}
		out.Accounts = append(out.Accounts, item)
	}
	if earliest == 0 {
		earliest = out.GeneratedAt
	}
	out.ExpiresAt = earliest
	encoded, err := json.Marshal(out)
	if err != nil || len(encoded) > contentBudget {
		return nil
	}
	return out
}

func safeUnit(actual, configured string) string {
	if actual == "" || !safeText(actual) ||
		(configured != "" && !strings.EqualFold(strings.TrimSpace(actual), strings.TrimSpace(configured))) {
		return ""
	}
	return actual
}

func displayText(value string) bool { return safeText(value) }

func (s *Service) notify(record sessionRecord, event string) {
	release, ok := s.lockDelivery(s.ctx, record.ID)
	if !ok {
		return
	}
	defer release()
	s.sendNotification(record, event)
}

func (s *Service) sendNotification(record sessionRecord, event string) {
	if s.opt.Config.DryRun || s.opt.Notifier == nil {
		return
	}
	s.mu.Lock()
	current, exists := s.state.Sessions[record.ID]
	valid := s.availableLocked() && exists && current.TokenInvalidReason == "" && current.Revision == record.Revision && current.DeliveryRetryAt <= s.opt.Now().Unix()
	if event == "update" {
		valid = valid && current.Delivery != "sent" && current.Status == "active" && s.opt.Now().Unix() < current.ExpiresAt &&
			current.Snapshot != nil && record.Snapshot != nil && current.Snapshot.Sequence == record.Snapshot.Sequence
	} else {
		valid = valid && current.Status != "active" && current.Delivery != "ended" && current.Delivery != "disabled"
	}
	s.mu.Unlock()
	if !valid {
		return
	}
	if record.Snapshot == nil {
		if event != "end" {
			return
		}
		record.Snapshot = s.snapshot(record, nil)
		if record.Snapshot == nil {
			return
		}
	}
	if event == "end" {
		terminal := *record.Snapshot
		terminal.Phase = record.Status
		record.Snapshot = &terminal
	}
	body, err := json.Marshal(record.Snapshot)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
	defer cancel()
	err = s.opt.Notifier.Notify(ctx, record.PushToken, event, body, s.opt.Now().Unix(), record.Snapshot.ExpiresAt)
	s.mu.Lock()
	defer s.mu.Unlock()
	current, found := s.state.Sessions[record.ID]
	// A token-specific rejection remains authoritative even when newer content
	// or lease expiry overtook this request. Generic success/failure still needs
	// the stricter revision/sequence check below. Never invalidate a replacement.
	if reason := invalidTokenReason(err); found && reason != "" && strings.EqualFold(current.PushToken, record.PushToken) {
		current.Version, current.TokenInvalidReason = 2, reason
		current.Delivery, current.DeliveryRetryAt = "failed", 0
		s.state.Sessions[record.ID] = current
		_ = s.persistLocked()
		return
	}
	if !found || current.Revision != record.Revision ||
		(event == "update" && (current.Snapshot == nil || current.Snapshot.Sequence != record.Snapshot.Sequence)) {
		return
	}
	if err != nil {
		current.Delivery = "failed"
		if current.DeliveryAttempts < 5 {
			current.DeliveryAttempts++
		}
		current.DeliveryRetryAt = deliveryRetry(err, current.DeliveryAttempts, s.opt.Now().Unix())
	} else {
		current.DeliveryAttempts, current.DeliveryRetryAt = 0, 0
		if event == "end" {
			current.Delivery = "ended"
		} else {
			current.Delivery = "sent"
		}
	}
	s.state.Sessions[record.ID] = current
	_ = s.persistLocked()
}
