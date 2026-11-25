package quota

import "strings"

// ValidateSelection is shared by configuration and normalization. Plugin
// summary keys must be confirmed against the upstream schema by the operator.
// Positional selections and buckets without a proven stable identity are not
// supported: display labels and equal units cannot identify a quota window.
func ValidateSelection(provider, selection string) error {
	switch strings.ToLower(provider) {
	case "codex":
		if selection == "primary" || selection == "secondary" {
			return nil
		}
	case "xai":
		if selection == "monthly" || selection == "monthly-limit-usd" || selection == "used-usd" {
			return nil
		}
	case "plugin":
		key, ok := strings.CutPrefix(selection, "summary-key:")
		if !ok || len(key) == 0 || len(key) > 128 {
			return ErrInvalid
		}
		for _, r := range key {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
				return ErrInvalid
			}
		}
		return nil
	}
	return ErrInvalid
}
