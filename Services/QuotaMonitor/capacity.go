package monitor

import (
	"encoding/json"
	"errors"
	"math"
	"strings"
)

// ErrCapacity is a rejected new intent, not an uncertain disk write. Callers
// must not turn it into the fail-closed persistence path.
var ErrCapacity = errors.New("monitoring capacity exhausted")

// CapacityLimits bound all retained UUIDs, including terminal sessions and
// cancellation tombstones. Zero selects a conservative default. Tombstones
// cannot be expired safely while v1 registrations have no replay deadline.
type CapacityLimits struct {
	MaxSessions         int `json:"max_sessions,omitempty"`
	MaxTombstones       int `json:"max_tombstones,omitempty"`
	MaxPrincipalIntents int `json:"max_principal_intents,omitempty"`
}

func (l *CapacityLimits) normalize() error {
	if l.MaxSessions == 0 {
		l.MaxSessions = 1024
	}
	if l.MaxTombstones == 0 {
		l.MaxTombstones = 4096
	}
	if l.MaxPrincipalIntents == 0 {
		l.MaxPrincipalIntents = 256
	}
	if l.MaxSessions < 1 || l.MaxSessions > 16384 || l.MaxTombstones < 1 || l.MaxTombstones > 65536 || l.MaxPrincipalIntents < 1 || l.MaxPrincipalIntents > 65536 {
		return ErrConfig
	}
	return nil
}

// reservedStateBytes accounts for the largest supported future state of every
// admitted session. Admission therefore reserves room for token rotation,
// quota snapshots, stop/expiry, counters, and delivery retries before any write.
// Existing state is never edited while estimating its size.
func reservedStateBytes(state persisted) (int, error) {
	body, err := json.Marshal(state)
	if err != nil {
		return 0, err
	}
	total := len(body)
	for _, record := range state.Sessions {
		actual, err := json.Marshal(record)
		if err != nil {
			return 0, err
		}
		reserved := record
		reserved.PushToken = strings.Repeat("f", 4096)
		reserved.Snapshot = nil
		reserved.AccountIdentities = make(map[string]string, len(record.AccountIDs))
		for _, id := range record.AccountIDs {
			reserved.AccountIdentities[id] = strings.Repeat("f", 64)
		}
		reserved.StartsAt, reserved.ExpiresAt = math.MinInt64, math.MinInt64
		next := int64(math.MinInt64)
		reserved.NextRefresh = &next
		reserved.Revision = math.MaxUint64
		reserved.Status, reserved.Delivery = "expired", "disabled"
		reserved.Pending = false // JSON false is longer than true.
		reserved.DeliveryRetryAt, reserved.DeliveryAttempts = math.MinInt64, math.MaxUint8
		for i := range reserved.RequestHash {
			reserved.RequestHash[i], reserved.SourceConfigHash[i] = 255, 255
		}
		maxBody, err := json.Marshal(reserved)
		if err != nil {
			return 0, err
		}
		// The snapshot is individually bounded by contentBudget. The extra 512
		// bytes include its field framing and the bounded token-invalid reason,
		// even for a v1 record that has not yet acquired that optional field.
		maximum := len(maxBody) + contentBudget + 512
		if maximum > len(actual) {
			total += maximum - len(actual)
		}
		if total > maxStateBytes-128 {
			return total, nil
		}
	}
	return total, nil
}

func validateCapacity(state persisted, limits CapacityLimits) error {
	if limits.normalize() != nil || len(state.Sessions) > limits.MaxSessions || len(state.Tombstones) > limits.MaxTombstones {
		return ErrCapacity
	}
	counts := make(map[string]int)
	for _, record := range state.Sessions {
		counts[record.Principal]++
	}
	for _, principal := range state.Tombstones {
		counts[principal]++
	}
	for _, count := range counts {
		if count > limits.MaxPrincipalIntents {
			return ErrCapacity
		}
	}
	size, err := reservedStateBytes(state)
	if err != nil || size > maxStateBytes-128 {
		return ErrCapacity
	}
	return nil
}

func (s *Service) admitSessionLocked(principal string, candidate sessionRecord) error {
	if candidate.Principal != principal || len(s.state.Sessions) >= s.opt.Config.Capacity.MaxSessions {
		return ErrCapacity
	}
	copyState := persisted{Sessions: make(map[string]sessionRecord, len(s.state.Sessions)+1), Tombstones: s.state.Tombstones}
	for id, record := range s.state.Sessions {
		copyState.Sessions[id] = record
	}
	copyState.Sessions[candidate.ID] = candidate
	return validateCapacity(copyState, s.opt.Config.Capacity)
}

func (s *Service) admitTombstoneLocked(principal, id string) error {
	if len(s.state.Tombstones) >= s.opt.Config.Capacity.MaxTombstones {
		return ErrCapacity
	}
	copyState := persisted{Sessions: s.state.Sessions, Tombstones: make(map[string]string, len(s.state.Tombstones)+1)}
	for key, owner := range s.state.Tombstones {
		copyState.Tombstones[key] = owner
	}
	copyState.Tombstones[principal+"\x00"+id] = principal
	return validateCapacity(copyState, s.opt.Config.Capacity)
}
