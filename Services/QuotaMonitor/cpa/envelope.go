package cpa

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
)

// envelopeField follows the Swift wire contract: exact spelling first, then a
// case-insensitive match, with the first non-null alias taking precedence.
func envelopeField(root map[string]any, keys ...string) any {
	for _, key := range keys {
		if value, exists := root[key]; exists {
			if value != nil {
				return value
			}
			continue
		}
		for name, value := range root {
			if strings.EqualFold(name, key) && value != nil {
				return value
			}
		}
	}
	return nil
}

func envelopeJSON(body []byte) (any, bool) {
	if len(body) > maximumBody {
		return nil, false
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	var value, extra any
	if d.Decode(&value) != nil || d.Decode(&extra) != io.EOF {
		return nil, false
	}
	return value, true
}

func envelopeStatus(value any) (int, bool) {
	var number float64
	switch value := value.(type) {
	case json.Number:
		parsed, err := value.Float64()
		if err != nil {
			return 0, false
		}
		number = parsed
	case string:
		// Integer strings are supported by Swift's integerValue. A decimal
		// or fractional string is not silently truncated to an HTTP status.
		parsed, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil || parsed < 100 || parsed > 599 {
			return 0, false
		}
		return parsed, true
	default:
		return 0, false
	}
	if math.IsNaN(number) || math.IsInf(number, 0) || number < 100 || number > 599 || math.Trunc(number) != number {
		return 0, false
	}
	return int(number), true
}

func retryHeaderValue(value any) (string, bool) {
	switch value := value.(type) {
	case string:
		return value, true
	case json.Number:
		return value.String(), true
	case bool:
		return strconv.FormatBool(value), true
	default:
		return "", false
	}
}

func unwrap(body []byte) ([]byte, int, http.Header, bool) {
	decoded, ok := envelopeJSON(body)
	root, object := decoded.(map[string]any)
	if !ok || !object {
		return nil, 0, nil, false
	}
	status, ok := envelopeStatus(envelopeField(root, "status_code", "statusCode"))
	if !ok {
		return nil, 0, nil, false
	}
	header := http.Header{}
	if values, ok := envelopeField(root, "header", "headers").(map[string]any); ok {
		retry := envelopeField(values, "Retry-After")
		items, array := retry.([]any)
		if !array {
			items = []any{retry}
		}
		for _, item := range items {
			if value, scalar := retryHeaderValue(item); scalar {
				header.Add("Retry-After", value)
			}
		}
	}
	if status < 200 || status >= 300 {
		return nil, status, header, true
	}
	payload := envelopeField(root, "body")
	if text, stringBody := payload.(string); stringBody {
		payload, ok = envelopeJSON([]byte(text))
		if !ok {
			return nil, status, header, false
		}
	}
	switch payload.(type) {
	case map[string]any, []any:
		encoded, err := json.Marshal(payload)
		return encoded, status, header, err == nil
	default:
		return nil, status, header, false
	}
}
