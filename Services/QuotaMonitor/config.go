package monitor

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"regexp"
	"strings"
	"unicode"

	"icu.nahida/cpaquota/monitor/cpa"
)

type Config struct {
	Listen      string            `json:"listen"`
	StatePath   string            `json:"state_path"`
	StateKeyEnv string            `json:"state_key_env"`
	DryRun      bool              `json:"dry_run"`
	TLSCertFile string            `json:"tls_cert_file"`
	TLSKeyFile  string            `json:"tls_key_file"`
	Sources     []SourceConfig    `json:"sources"`
	Principals  []PrincipalConfig `json:"principals"`
	APNs        APNsConfig        `json:"apns"`
	Capacity    CapacityLimits    `json:"capacity,omitempty"`
}
type SourceConfig struct {
	ID               string          `json:"id"`
	BaseURL          string          `json:"base_url"`
	ManagementKeyEnv string          `json:"management_key_env"`
	Accounts         []AccountConfig `json:"accounts"`
}
type AccountConfig struct {
	ID          string `json:"id"`
	SafeID      string `json:"safe_id"`
	Label       string `json:"label"`
	Provider    string `json:"provider"`
	Reader      string `json:"reader,omitempty"`
	Selection   string `json:"selection"`
	WindowID    string `json:"window_id"`
	WindowLabel string `json:"window_label"`
	Unit        string `json:"unit,omitempty"`
}
type PrincipalConfig struct {
	ID             string              `json:"id"`
	BearerTokenEnv string              `json:"bearer_token_env"`
	SourceAccounts map[string][]string `json:"source_accounts"`
}
type APNsConfig struct {
	TeamID        string `json:"team_id"`
	KeyID         string `json:"key_id"`
	BundleID      string `json:"bundle_id"`
	Environment   string `json:"environment"`
	PrivateKeyEnv string `json:"private_key_env"`
}

var ErrConfig = errors.New("invalid secure configuration")
var envName = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,127}$`)

func safeText(s string) bool {
	if s == "" || len(s) > 128 || strings.Contains(s, "@") || strings.Contains(strings.ToLower(s), "://") || strings.Contains(strings.ToLower(s), "www.") {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) || (!unicode.IsLetter(r) && !unicode.IsNumber(r) && !strings.ContainsRune(" _-%/·.-", r)) {
			return false
		}
	}
	return true
}

func identifier(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, r := range s {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && !strings.ContainsRune("_-", r) {
			return false
		}
	}
	return true
}

func accountID(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, r := range s {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && !strings.ContainsRune("_-@.", r) {
			return false
		}
	}
	return true
}

// CanonicalOrigin folds default HTTPS port 443 so two spellings of one CPA
// origin cannot own separate cooldown and authentication circuits.
func CanonicalOrigin(value string) string {
	u, err := url.Parse(value)
	if err != nil {
		return ""
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	return "https://" + strings.ToLower(u.Hostname()) + ":" + port
}

func DecodeConfig(r io.Reader) (Config, error) {
	var c Config
	body, err := io.ReadAll(io.LimitReader(r, 1024*1024+1))
	if err != nil || len(body) > 1024*1024 {
		return c, ErrConfig
	}
	d := json.NewDecoder(bytes.NewReader(body))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil {
		return c, ErrConfig
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return c, ErrConfig
	}
	if c.Validate() != nil {
		return c, ErrConfig
	}
	return c, nil
}

func (c *Config) Validate() error {
	if c.Capacity.normalize() != nil {
		return ErrConfig
	}
	if c.Listen == "" {
		c.Listen = "127.0.0.1:8787"
	}
	host, port, err := net.SplitHostPort(c.Listen)
	if err != nil || port == "" {
		return ErrConfig
	}
	ip := net.ParseIP(host)
	if ip == nil || (!ip.IsLoopback() && (c.TLSCertFile == "" || c.TLSKeyFile == "")) {
		return ErrConfig
	}
	if (c.TLSCertFile == "") != (c.TLSKeyFile == "") || c.StatePath == "" || !envName.MatchString(c.StateKeyEnv) || len(c.Sources) == 0 || len(c.Sources) > 100 || len(c.Principals) == 0 || len(c.Principals) > 100 {
		return ErrConfig
	}
	sources := map[string]map[string]bool{}
	origins := map[string]bool{}
	for _, s := range c.Sources {
		if !identifier(s.ID) || sources[s.ID] != nil || !envName.MatchString(s.ManagementKeyEnv) || len(s.Accounts) == 0 || len(s.Accounts) > 100 || cpa.ValidateBaseURL(s.BaseURL) != nil {
			return ErrConfig
		}
		origin := CanonicalOrigin(s.BaseURL)
		if origins[origin] {
			return ErrConfig
		}
		origins[origin] = true
		ids := map[string]bool{}
		aliases := map[string]bool{}
		for _, a := range s.Accounts {
			if !accountID(a.ID) || ids[a.ID] || !identifier(a.SafeID) || aliases[a.SafeID] || !safeText(a.Label) || !identifier(a.WindowID) || !safeText(a.WindowLabel) || (a.Unit != "" && !safeText(a.Unit)) {
				return ErrConfig
			}
			reader := a.Reader
			if reader == "" {
				reader = a.Provider
			}
			if !identifier(a.Provider) || cpa.ValidateSelection(reader, a.Selection) != nil {
				return ErrConfig
			}
			ids[a.ID] = true
			aliases[a.SafeID] = true
		}
		sources[s.ID] = ids
	}
	principals := map[string]bool{}
	refs := map[string]bool{}
	for _, p := range c.Principals {
		if !identifier(p.ID) || principals[p.ID] || !envName.MatchString(p.BearerTokenEnv) || refs[p.BearerTokenEnv] || len(p.SourceAccounts) == 0 {
			return ErrConfig
		}
		principals[p.ID] = true
		refs[p.BearerTokenEnv] = true
		for src, ids := range p.SourceAccounts {
			if sources[src] == nil || len(ids) == 0 {
				return ErrConfig
			}
			seen := map[string]bool{}
			for _, id := range ids {
				if !sources[src][id] || seen[id] {
					return ErrConfig
				}
				seen[id] = true
			}
		}
	}
	if !c.DryRun {
		a := c.APNs
		if a.TeamID == "" || a.KeyID == "" || a.BundleID == "" || !envName.MatchString(a.PrivateKeyEnv) || (a.Environment != "production" && a.Environment != "sandbox") {
			return ErrConfig
		}
	}
	return nil
}
