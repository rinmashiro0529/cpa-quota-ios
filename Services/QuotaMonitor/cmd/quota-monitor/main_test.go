package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	monitor "icu.nahida/cpaquota/monitor"
)

func TestHelpNeverReadsConfigurationOrStartsServer(t *testing.T) {
	var stderr bytes.Buffer
	code := run(context.Background(), []string{"-h"}, &stderr, func(context.Context, monitor.Config) error {
		t.Fatal("help must not start the service")
		return nil
	})
	if code != 0 || !strings.Contains(stderr.String(), "Usage:") {
		t.Fatal("help should describe the required configuration")
	}
}

func TestInvalidConfigurationDoesNotExposeItsContents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"secret":"fixture-sensitive"}`), 0600); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	code := run(context.Background(), []string{"-config", path}, &stderr, func(context.Context, monitor.Config) error {
		t.Fatal("invalid configuration must not start the service")
		return nil
	})
	if code != 1 || strings.Contains(stderr.String(), "fixture-sensitive") {
		t.Fatal("configuration failure must be generic and fail closed")
	}
}

func TestConfigurationPathsUseConfigurationDirectoryAndStartupErrorIsSafe(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	body := `{"state_path":".state/state.enc","state_key_env":"FIXTURE_STATE_KEY","dry_run":true,"tls_cert_file":"tls/cert.pem","tls_key_file":"tls/key.pem","sources":[{"id":"personal","base_url":"https://cpa.invalid","management_key_env":"FIXTURE_CPA_KEY","accounts":[{"id":"fixture-account","safe_id":"account-1","label":"账号1","provider":"codex","selection":"primary","window_id":"primary","window_label":"主要窗口"}]}],"principals":[{"id":"owner","bearer_token_env":"FIXTURE_BRIDGE_TOKEN","source_accounts":{"personal":["fixture-account"]}}]}`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	started := false
	code := run(context.Background(), []string{"-config", path}, &stderr, func(ctx context.Context, config monitor.Config) error {
		started = true
		if config.StatePath != filepath.Join(directory, ".state", "state.enc") || config.TLSCertFile != filepath.Join(directory, "tls", "cert.pem") || config.TLSKeyFile != filepath.Join(directory, "tls", "key.pem") {
			t.Fatal("relative paths must resolve against the configuration directory")
		}
		if config.Listen != "127.0.0.1:8787" || ctx == nil {
			t.Fatal("default listener must remain loopback")
		}
		return errors.New("fixture-sensitive")
	})
	if code != 1 || !started || strings.Contains(stderr.String(), "fixture-sensitive") {
		t.Fatal("startup error must be safe and reported as failure")
	}
}

func TestMissingConfigurationNeverStartsServer(t *testing.T) {
	var stderr bytes.Buffer
	started := false
	code := run(context.Background(), nil, &stderr, func(context.Context, monitor.Config) error {
		started = true
		return nil
	})
	if code != 2 || started || stderr.Len() == 0 {
		t.Fatal("missing configuration must fail before starting a listener")
	}
}
