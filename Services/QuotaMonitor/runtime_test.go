package monitor

import (
	"bytes"
	"context"
	"encoding/base64"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRuntimeServesLocalHealthAndStopsWithoutUpstreamOrAPNs(t *testing.T) {
	config := validConfig()
	config.StatePath = filepath.Join(t.TempDir(), "state.enc")
	config.StateKeyEnv = "CPA_QUOTA_TEST_RUNTIME_STATE_20261028"
	config.Sources[0].ManagementKeyEnv = "CPA_QUOTA_TEST_RUNTIME_CPA_20261028"
	config.Principals[0].BearerTokenEnv = "CPA_QUOTA_TEST_RUNTIME_TOKEN_20261028"
	t.Setenv(config.StateKeyEnv, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32)))
	t.Setenv(config.Sources[0].ManagementKeyEnv, "synthetic-management-key")
	t.Setenv(config.Principals[0].BearerTokenEnv, strings.Repeat("synthetic", 5))
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	config.Listen = reserved.Addr().String()
	reserved.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, config) }()
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 100 * time.Millisecond}
	ready := false
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); {
		response, err := client.Get("http://" + config.Listen + "/healthz")
		if err == nil {
			response.Body.Close()
			if response.StatusCode == 200 {
				ready = true
				break
			}
		}
		select {
		case err := <-done:
			t.Fatalf("runtime failed before readiness: %v", err)
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not stop")
	}
	if !ready {
		t.Fatal("runtime did not expose local health")
	}
}

func TestCancelledStartupDoesNotStartOrReadCredentials(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Run(ctx, validConfig()); err != nil {
		t.Fatal("cancelled startup should exit without starting the service")
	}
}
