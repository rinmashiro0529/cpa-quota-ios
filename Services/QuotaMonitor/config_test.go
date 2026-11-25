package monitor

import (
	"encoding/json"
	"strings"
	"testing"
)

func validConfig() Config {
	return Config{StatePath: "state.enc", StateKeyEnv: "TEST_STATE_KEY", DryRun: true, Sources: []SourceConfig{{ID: "personal", BaseURL: "https://cpa.example.invalid", ManagementKeyEnv: "TEST_CPA_KEY", Accounts: []AccountConfig{{ID: "fixture-upstream-account", SafeID: "account-1", Label: "Account 1", Provider: "codex", Selection: "primary", WindowID: "primary", WindowLabel: "5 hours"}}}}, Principals: []PrincipalConfig{{ID: "phone", BearerTokenEnv: "TEST_BRIDGE_TOKEN", SourceAccounts: map[string][]string{"personal": {"fixture-upstream-account"}}}}}
}

func TestConfigurationFailsClosed(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Config)
	}{
		{"no authorization", func(c *Config) { c.Principals = nil }}, {"HTTP upstream", func(c *Config) { c.Sources[0].BaseURL = "http://cpa.example.invalid" }},
		{"URL credentials", func(c *Config) { c.Sources[0].BaseURL = "https://user:pass@cpa.example.invalid" }}, {"unscoped principal", func(c *Config) { c.Principals[0].SourceAccounts["personal"] = []string{"unknown"} }},
		{"unsafe alias", func(c *Config) { c.Sources[0].Accounts[0].Label = "private@example.invalid" }}, {"exposed plaintext listener", func(c *Config) { c.Listen = "0.0.0.0:9000" }},
		{"no state encryption", func(c *Config) { c.StateKeyEnv = "" }}, {"live without APNs", func(c *Config) { c.DryRun = false }},
		{"duplicate canonical origin", func(c *Config) {
			second := c.Sources[0]
			second.ID = "mirror"
			second.BaseURL = "https://cpa.example.invalid:443"
			second.ManagementKeyEnv = "TEST_OTHER_KEY"
			c.Sources = append(c.Sources, second)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := validConfig()
			tc.mutate(&c)
			if c.Validate() == nil {
				t.Fatal("unsafe configuration accepted")
			}
		})
	}
	c := validConfig()
	c.Sources[0].Accounts[0].WindowLabel = "5小时 · 80%"
	c.Sources[0].BaseURL = "https://cpa.example.invalid/proxy/v0/management"
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Listen != "127.0.0.1:8787" {
		t.Fatal("missing safe listener default")
	}
}

func TestDecodeRejectsUnknownAndTrailingJSON(t *testing.T) {
	b, _ := json.Marshal(validConfig())
	for _, s := range []string{strings.TrimSuffix(string(b), "}") + `,"management_key":"secret"}`, string(b) + ` {}`, string(b) + strings.Repeat(" ", 1024*1024)} {
		if _, e := DecodeConfig(strings.NewReader(s)); e == nil {
			t.Fatal("ambiguous configuration accepted")
		}
	}
}
