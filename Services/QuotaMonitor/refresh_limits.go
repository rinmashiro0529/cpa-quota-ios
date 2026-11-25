package monitor

import (
	"net/http"
	"strconv"
	"time"
)

const (
	manualRefreshSpacing   = 10 * time.Second
	principalRefreshWindow = time.Minute
	principalRefreshBurst  = 6
)

// refreshLimits is protected by Service.mu. Only authenticated, visible active
// sessions may create entries, so memory is bounded by the configured principals
// and retained sessions. This process-local request budget never changes the
// durable source cooldown, lease, token, or cancellation contract.
type refreshLimits struct {
	principals map[string][]time.Time
	sessions   map[string]time.Time
}

func (l *refreshLimits) accept(principal, session string, now time.Time) time.Duration {
	var wait time.Duration
	if previous, exists := l.sessions[session]; exists && now.Before(previous.Add(manualRefreshSpacing)) {
		wait = previous.Add(manualRefreshSpacing).Sub(now)
	}
	previous := l.principals[principal]
	first := 0
	for first < len(previous) && !now.Before(previous[first].Add(principalRefreshWindow)) {
		first++
	}
	retained := previous[first:]
	if len(retained) >= principalRefreshBurst {
		if principalWait := retained[0].Add(principalRefreshWindow).Sub(now); principalWait > wait {
			wait = principalWait
		}
	}
	if wait > 0 {
		return wait
	}
	// Copy into the existing bounded buffer without retaining expired entries.
	count := copy(previous, retained)
	l.principals[principal] = append(previous[:count], now)
	l.sessions[session] = now
	return 0
}

func writeRefreshLimit(w http.ResponseWriter, wait time.Duration) {
	seconds := int64(wait / time.Second)
	if wait%time.Second > 0 {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.FormatInt(seconds, 10))
	w.Header().Set("Cache-Control", "no-store")
	http.Error(w, "refresh rate limit exceeded", http.StatusTooManyRequests)
}
