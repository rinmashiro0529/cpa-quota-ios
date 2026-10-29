package cpa

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestConfigValidation(t *testing.T) {
	for _, value := range []string{"http://example.com", "https://key@example.com", "https://example.com?", "https://example.com#", "https://example.com/a/../b", "https://example.com/%2e%2e", "https://example.com/%252e%252e", "https://example.com/a%2fb", "https://example.com:0", "https://example.com:99999", "https://example.com/a\\b", "https://example.com//b"} {
		if ValidateBaseURL(value) == nil {
			t.Errorf("accepted invalid base URL case %q", value)
		}
	}
	for _, value := range []string{"https://example.com", "https://example.com/prefix/", "https://example.com/prefix/v0/management/", "https://example.com/management.html"} {
		if ValidateBaseURL(value) != nil {
			t.Errorf("rejected valid base URL case %q", value)
		}
	}
	for _, a := range []Account{{ID: "a", Provider: "codex", Selection: "primary"}, {ID: "a", Provider: "codex", Selection: "secondary"}, {ID: "a", Provider: "xai", Selection: "monthly"}, {ID: "a", Provider: "xai", Selection: "used-usd"}, {ID: "a", Provider: "xai", Selection: "monthly-limit-usd"}, {ID: "a", Provider: "plugin", Selection: "summary-key:requests"}} {
		if err := ValidateSelection(a.Provider, a.Selection); err != nil {
			t.Errorf("valid selection rejected: %v", a)
		}
	}
	for _, a := range []Account{{ID: "a", Provider: "codex", Selection: "https://evil.test"}, {ID: "a", Provider: "xai", Selection: "primary"}, {ID: "a", Provider: "plugin", Selection: "bucket:-1:0"}, {ID: "a", Provider: "plugin", Selection: "summary:0"}, {ID: "a", Provider: "plugin", Selection: "bucket:0:2"}, {ID: "a", Provider: "plugin", Selection: "summary:01"}, {ID: "a", Provider: "plugin", Selection: "summary-key:"}, {ID: "a", Provider: "plugin", Selection: "summary-key:requests remaining"}, {ID: "a", Provider: "other", Selection: "primary"}} {
		if ValidateSelection(a.Provider, a.Selection) == nil {
			t.Errorf("invalid selection accepted: %v", a)
		}
	}
	base := Config{BaseURL: "https://example.com", ManagementKey: "fixture", Accounts: []Account{{ID: "a", Provider: "codex", Selection: "primary"}}}
	for _, mutate := range []func(*Config){func(c *Config) { c.ManagementKey = "" }, func(c *Config) { c.ManagementKey = "x\r\ny" }, func(c *Config) { c.Accounts = nil }, func(c *Config) { c.Accounts = append(c.Accounts, c.Accounts[0]) }, func(c *Config) { c.Accounts[0].ID = "" }, func(c *Config) { c.Client = &http.Client{} }} {
		cfg := base
		cfg.Accounts = append([]Account(nil), base.Accounts...)
		mutate(&cfg)
		if _, err := New(cfg); err == nil {
			t.Error("invalid config accepted")
		}
	}
}

func TestExplicitLoopbackTLSOnly(t *testing.T) {
	s := httptest.NewTLSServer(http.NotFoundHandler())
	defer s.Close()
	cfg := Config{BaseURL: s.URL, ManagementKey: "fixture", Accounts: []Account{{ID: "a", Provider: "codex", Selection: "primary"}}, Client: s.Client()}
	if _, err := New(cfg); err != nil {
		t.Fatal("TLS fixture client rejected", err)
	}
	for _, base := range []string{"https://localhost:1234", "https://127.0.0.1", "https://example.com:1234", "http://127.0.0.1:1234"} {
		cfg.BaseURL = base
		if _, err := New(cfg); err == nil {
			t.Errorf("custom client accepted for non-explicit TLS loopback %q", base)
		}
	}
}
