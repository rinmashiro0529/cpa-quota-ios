package monitor

import (
	"encoding/json"
	"math"
	"strings"
)

func (s *Service) registrationFits(record sessionRecord) bool {
	snapshot := s.snapshot(record, nil)
	if snapshot == nil {
		return false
	}
	fraction, value, observed := 0.0000012345678901234567, -0.0000012345678901234567, int64(math.MaxInt64)
	snapshot.Sequence = math.MaxUint64
	snapshot.GeneratedAt, snapshot.ExpiresAt = math.MaxInt64, math.MaxInt64
	for i := range snapshot.Accounts {
		account := &snapshot.Accounts[i]
		account.Remaining, account.Value, account.Observed = &fraction, &value, &observed
		account.Status = "cooling_down"
		if account.Unit == "" {
			account.Unit = strings.Repeat("/", 128)
		}
	}
	body, err := json.Marshal(snapshot)
	// Swift may escape slashes and encode integral seconds as floating-point numbers.
	return err == nil && len(body)+strings.Count(string(body), "/")+32 <= contentBudget
}
