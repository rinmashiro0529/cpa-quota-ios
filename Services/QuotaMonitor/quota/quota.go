package quota

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
)

var ErrInvalid = errors.New("invalid quota response or selection")

type Result struct {
	Remaining *float64
	Value     *float64
	// Unit is untrusted source data and must not be copied into system payloads without a safe mapping.
	Unit string
}

type object map[string]any

func field(m object, keys ...string) any {
	for _, k := range keys {
		for name, value := range m {
			if strings.EqualFold(name, k) && value != nil {
				return value
			}
		}
	}
	return nil
}
func obj(v any) object {
	if m, ok := v.(map[string]any); ok {
		return object(m)
	}
	return nil
}
func num(v any) *float64 {
	if m := obj(v); m != nil {
		return num(field(m, "val", "value"))
	}
	var n float64
	switch v := v.(type) {
	case json.Number:
		x, e := v.Float64()
		if e != nil {
			return nil
		}
		n = x
	case string:
		x, e := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if e != nil {
			return nil
		}
		n = x
	default:
		return nil
	}
	if math.IsNaN(n) || math.IsInf(n, 0) {
		return nil
	}
	return &n
}
func item(v any, n int) object {
	a, ok := v.([]any)
	if !ok || n < 0 || n >= len(a) {
		return nil
	}
	return obj(a[n])
}
func index(s string) (int, bool) {
	n, e := strconv.Atoi(s)
	return n, e == nil && n >= 0 && strconv.Itoa(n) == s
}

func Normalize(provider string, body []byte, selection string) (Result, error) {
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	var raw any
	if len(body) > 4*1024*1024 || d.Decode(&raw) != nil {
		return Result{}, ErrInvalid
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return Result{}, ErrInvalid
	}
	root := obj(raw)
	if root == nil {
		return Result{}, ErrInvalid
	}
	switch strings.ToLower(provider) {
	case "codex":
		if selection != "primary" && selection != "secondary" {
			return Result{}, ErrInvalid
		}
		limit := obj(field(root, "rate_limit", "rateLimit"))
		window := obj(field(limit, selection+"_window", selection+"Window"))
		if window == nil {
			return Result{}, ErrInvalid
		}
		used := num(field(window, "used_percent", "usedPercent"))
		if used == nil || *used < 0 {
			return Result{}, nil
		}
		remaining := 0.0
		if *used <= 100 {
			remaining = 1 - *used/100
		}
		return Result{Remaining: &remaining}, nil
	case "xai":
		config := obj(field(root, "config"))
		if config == nil {
			return Result{}, ErrInvalid
		}
		limit := num(field(config, "monthlyLimit", "monthly_limit"))
		used := num(field(config, "used", "usedAmount", "used_amount"))
		switch selection {
		case "monthly":
			if limit == nil || *limit <= 0 || used == nil || *used < 0 {
				return Result{}, nil
			}
			remaining := 1 - *used / *limit
			if remaining < 0 {
				remaining = 0
			}
			return Result{Remaining: &remaining}, nil
		case "monthly-limit-usd":
			if limit == nil || *limit < 0 {
				return Result{}, nil
			}
			value := *limit / 100
			return Result{Value: &value, Unit: "USD"}, nil
		case "used-usd":
			if used == nil || *used < 0 {
				return Result{}, nil
			}
			value := *used / 100
			return Result{Value: &value, Unit: "USD"}, nil
		default:
			return Result{}, ErrInvalid
		}
	case "plugin":
		parts := strings.Split(selection, ":")
		if len(parts) == 2 && parts[0] == "summary" {
			i, ok := index(parts[1])
			if !ok {
				return Result{}, ErrInvalid
			}
			metric := item(field(root, "summary"), i)
			if metric == nil {
				return Result{}, ErrInvalid
			}
			unit, _ := field(metric, "unit").(string)
			return Result{Value: num(field(metric, "value", "val")), Unit: unit}, nil
		}
		if len(parts) == 3 && parts[0] == "bucket" {
			i, ok := index(parts[1])
			if !ok {
				return Result{}, ErrInvalid
			}
			j, ok := index(parts[2])
			if !ok {
				return Result{}, ErrInvalid
			}
			group := item(field(root, "groups"), i)
			bucket := item(field(group, "buckets"), j)
			if bucket == nil {
				return Result{}, ErrInvalid
			}
			remaining := num(field(bucket, "remainingFraction", "remaining_fraction"))
			if remaining == nil || *remaining > 1 {
				return Result{}, nil
			}
			if *remaining < 0 {
				zero := 0.0
				return Result{Remaining: &zero}, nil
			}
			return Result{Remaining: remaining}, nil
		}
	}
	return Result{}, ErrInvalid
}
