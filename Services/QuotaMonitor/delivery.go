package monitor

import (
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"

	"icu.nahida/cpaquota/monitor/apns"
)

// Waiters own a reference as well as the current sender. Reclaiming only after
// the last reference is released preserves serialization without retaining every
// UUID ever supplied to DELETE (including rejected and foreign requests).
type deliveryGate struct {
	token chan struct{}
	users int
}

func pendingDelivery(record sessionRecord, dryRun bool) string {
	if dryRun {
		return "disabled"
	}
	if record.TokenInvalidReason != "" {
		return "failed"
	}
	return "pending"
}

func invalidTokenReason(err error) string {
	var rejected *apns.HTTPError
	if !errors.As(err, &rejected) {
		return ""
	}
	if rejected.Status == http.StatusGone {
		return "Unregistered"
	}
	if rejected.Status == http.StatusBadRequest &&
		(rejected.Reason == "BadDeviceToken" || rejected.Reason == "DeviceTokenNotForTopic") {
		return rejected.Reason
	}
	return ""
}

func validTokenFailure(reason string) bool {
	switch reason {
	case "", "Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic":
		return true
	default:
		return false
	}
}

func deliveryRetry(err error, attempts uint8, now int64) int64 {
	var rejected *apns.HTTPError
	if errors.As(err, &rejected) && rejected.Status != 429 && rejected.Status < 500 &&
		!(rejected.Status == http.StatusForbidden && rejected.Reason == "ExpiredProviderToken") {
		return 0
	}
	delay := int64(60)
	for i := uint8(1); i < attempts && delay < 600; i++ {
		delay *= 2
	}
	if delay > 600 {
		delay = 600
	}
	deadline := now + delay
	if rejected == nil {
		return deadline
	}
	value := strings.TrimSpace(rejected.RetryAfter)
	if seconds, parseErr := strconv.ParseFloat(value, 64); parseErr == nil {
		if !math.IsInf(seconds, 0) && !math.IsNaN(seconds) && seconds > 0 && seconds < float64(math.MaxInt64-now) {
			candidate := now + int64(math.Ceil(seconds))
			if candidate > deadline {
				deadline = candidate
			}
		}
	} else if date, parseErr := http.ParseTime(value); parseErr == nil && date.Unix() > deadline {
		deadline = date.Unix()
	}
	return deadline
}
