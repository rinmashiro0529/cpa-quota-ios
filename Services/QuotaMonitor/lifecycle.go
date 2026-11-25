package monitor

import "math"

// terminalSnapshot preserves the last observation while versioning a phase
// change. At sequence exhaustion, the session status remains authoritative and
// the immutable final snapshot is retained; a counter must never wrap to zero.
func terminalSnapshot(previous *snapshotRecord, phase string) *snapshotRecord {
	if previous == nil || previous.Phase == phase || previous.Sequence == math.MaxUint64 {
		return previous
	}
	next := *previous
	next.Sequence++
	next.Phase = phase
	return &next
}

var revokedAccount = accountRecord{
	ID: "unavailable", Label: "Unavailable", Provider: "unavailable",
	WindowID: "unavailable", Window: "Unavailable", Status: "unavailable",
}

// Revocation must not disclose the previous labels, values or observation times.
// A bounded v1 placeholder keeps a client that already saw a snapshot able to
// accept the terminal state without weakening its monotonic-content checks.
func revokedSnapshot(previous *snapshotRecord, now int64) (*snapshotRecord, error) {
	if previous == nil || (previous.Phase == "stopped" && len(previous.Accounts) == 1 && previous.Accounts[0] == revokedAccount) {
		return previous, nil
	}
	if previous.Sequence == math.MaxUint64 {
		// No representable version can safely redact this record. Fail closed;
		// neither expose the revoked content nor reset its content sequence.
		return nil, ErrUnavailable
	}
	return &snapshotRecord{
		Version: protocolVersion, Sequence: previous.Sequence + 1, Phase: "stopped",
		GeneratedAt: now, ExpiresAt: now, Accounts: []accountRecord{revokedAccount},
	}, nil
}
