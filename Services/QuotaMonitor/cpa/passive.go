package cpa

import (
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"

	"icu.nahida/cpaquota/monitor/quota"
)

func wireNumber(value any) (float64, bool) {
	if text, ok := value.(string); ok {
		number, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
		return number, err == nil && !math.IsNaN(number) && !math.IsInf(number, 0)
	}
	return numberValue(value)
}

func observedTime(value any) int64 {
	if text, ok := value.(string); ok {
		if date, err := time.Parse(time.RFC3339Nano, text); err == nil {
			return date.Unix()
		}
	}
	if number, ok := wireNumber(value); ok && number > 0 && number < 253402300800 {
		return int64(number)
	}
	return 0
}

// Inventory/list timestamps are not quota observations. Only the signal container's own date qualifies.
func passiveReadings(file map[string]any) map[string]Reading {
	out := map[string]Reading{}
	containers := []map[string]any{}
	if value, ok := file["quota"].(map[string]any); ok {
		containers = append(containers, value)
	}
	for _, key := range []string{"model_quotas", "modelQuotas"} {
		if models, ok := file[key].(map[string]any); ok {
			for _, raw := range models {
				if container, ok := raw.(map[string]any); ok {
					containers = append(containers, container)
				}
			}
		}
	}
	for _, container := range containers {
		observed := observedTime(container["observed_at"])
		if observed == 0 {
			observed = observedTime(container["observedAt"])
		}
		if observed == 0 {
			continue
		}
		raw, ok := container["signals"].(map[string]any)
		if !ok {
			continue
		}
		signals := map[string]any{}
		for key, value := range raw {
			signals[strings.ToLower(key)] = value
		}
		for _, selection := range []string{"primary", "secondary"} {
			used, ok := wireNumber(signals["x-codex-"+selection+"-used-percent"])
			if !ok {
				continue
			}
			body, err := json.Marshal(map[string]any{"rate_limit": map[string]any{selection + "_window": map[string]any{"used_percent": used}}})
			if err != nil {
				continue
			}
			result, err := quota.Normalize("codex", body, selection)
			if err != nil || result.Remaining == nil {
				continue
			}
			if previous, exists := out[selection]; exists && previous.ObservedAt >= observed {
				continue
			}
			out[selection] = Reading{Result: result, Status: "stale", ObservedAt: observed}
		}
	}
	return out
}
