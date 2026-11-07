package monitor

import (
	"net/http"
	"sort"
)

// This authenticated inventory is intentionally separate from /healthz. It
// verifies only this service's authorization and configuration, not CPA access,
// APNs delivery, or device presentation. It never creates an activity or writes
// the state file.
type capabilitiesResponse struct {
	Version     int                `json:"version"`
	GeneratedAt int64              `json:"generated_at"`
	Sources     []capabilitySource `json:"sources"`
	Capacity    principalCapacity  `json:"capacity"`
}

type capabilitySource struct {
	ID       string              `json:"id"`
	Accounts []capabilityAccount `json:"accounts"`
}

type capabilityAccount struct {
	ID          string `json:"id"`
	SafeID      string `json:"safe_id"`
	Label       string `json:"label"`
	Provider    string `json:"provider"`
	WindowID    string `json:"window_id"`
	WindowLabel string `json:"window_label"`
}

type principalCapacity struct {
	Limit                 int    `json:"limit"`
	Used                  int    `json:"used"`
	Remaining             int    `json:"remaining"`
	WarningAt             int    `json:"warning_at"`
	Status                string `json:"status"`
	CanCreateSession      bool   `json:"can_create_session"`
	CanRecordCancellation bool   `json:"can_record_cancellation"`
}

func (s *Service) capabilities(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	principal, ok := s.authenticate(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	if !s.availableLocked() {
		s.mu.Unlock()
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	response := capabilitiesResponse{Version: protocolVersion, GeneratedAt: s.opt.Now().Unix(),
		Sources: make([]capabilitySource, 0, len(principal.accounts)), Capacity: s.principalCapacityLocked(principal.id)}
	for sourceID, authorized := range principal.accounts {
		source := capabilitySource{ID: sourceID, Accounts: make([]capabilityAccount, 0, len(authorized))}
		for _, account := range s.sources[sourceID].Accounts {
			if authorized[account.ID] {
				source.Accounts = append(source.Accounts, capabilityAccount{ID: account.ID, SafeID: account.SafeID,
					Label: account.Label, Provider: account.Provider, WindowID: account.WindowID, WindowLabel: account.WindowLabel})
			}
		}
		sort.Slice(source.Accounts, func(i, j int) bool { return source.Accounts[i].ID < source.Accounts[j].ID })
		response.Sources = append(response.Sources, source)
	}
	sort.Slice(response.Sources, func(i, j int) bool { return response.Sources[i].ID < response.Sources[j].ID })
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, response)
}

func (s *Service) principalCapacityLocked(principal string) principalCapacity {
	limits := s.opt.Config.Capacity
	used := 0
	for _, record := range s.state.Sessions {
		if record.Principal == principal {
			used++
		}
	}
	for _, owner := range s.state.Tombstones {
		if owner == principal {
			used++
		}
	}
	remaining := limits.MaxPrincipalIntents - used
	if remaining < 0 {
		remaining = 0
	}
	warningAt := (limits.MaxPrincipalIntents*4 + 4) / 5 // ceil(80%), including small test quotas.
	status := "ok"
	if remaining == 0 {
		status = "exhausted"
	} else if used >= warningAt {
		status = "warning"
	}
	// These flags disclose no other principal's counts. They are a count-only
	// preflight, not a reservation: exact payload/byte admission remains atomic
	// in POST/DELETE and may still reject a new intent with 507.
	return principalCapacity{Limit: limits.MaxPrincipalIntents, Used: used, Remaining: remaining,
		WarningAt: warningAt, Status: status,
		CanCreateSession:      remaining > 0 && len(s.state.Sessions) < limits.MaxSessions,
		CanRecordCancellation: remaining > 0 && len(s.state.Tombstones) < limits.MaxTombstones}
}
