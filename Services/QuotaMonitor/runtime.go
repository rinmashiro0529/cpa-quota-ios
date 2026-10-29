package monitor

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode"

	"icu.nahida/cpaquota/monitor/apns"
	"icu.nahida/cpaquota/monitor/cpa"
)

type configuredCollector struct {
	sources map[string]SourceConfig
	keys    map[string]string
}

func (c *configuredCollector) Collect(ctx context.Context, sourceID string, ids []string) map[string]Reading {
	source, ok := c.sources[sourceID]
	if !ok {
		return nil
	}
	allowed := map[string]AccountConfig{}
	for _, account := range source.Accounts {
		allowed[account.ID] = account
	}
	selected := make([]cpa.Account, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		account, exists := allowed[id]
		if !exists || seen[id] {
			return nil
		}
		seen[id] = true
		selected = append(selected, cpa.Account{ID: account.ID, Provider: account.Provider, Selection: account.Selection, Reader: account.Reader})
	}
	if len(selected) == 0 {
		return nil
	}
	client, err := cpa.New(cpa.Config{BaseURL: source.BaseURL, ManagementKey: c.keys[source.ManagementKeyEnv], Accounts: selected})
	if err != nil {
		return nil
	}
	result := client.Collect(ctx)
	out := make(map[string]Reading, len(result))
	for id, reading := range result {
		out[id] = Reading{Identity: reading.Identity, Remaining: reading.Result.Remaining, Value: reading.Result.Value, Unit: reading.Result.Unit,
			Status: reading.Status, ObservedAt: reading.ObservedAt, ExpiresAt: reading.ExpiresAt}
	}
	return out
}

type apnsNotifier struct{ provider *apns.Provider }

func (n apnsNotifier) Notify(ctx context.Context, token, event string, state []byte, timestamp, staleDate int64) error {
	return n.provider.Send(ctx, token, event, json.RawMessage(state), timestamp)
}

func environmentSecret(name string, minimum int, bearer bool) (string, error) {
	value, ok := os.LookupEnv(name)
	if !ok || len(value) < minimum || len(value) > 4096 || strings.TrimSpace(value) != value ||
		strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return "", ErrUnavailable
	}
	if bearer {
		for _, r := range value {
			if r <= 32 || r > 126 {
				return "", ErrUnavailable
			}
		}
	}
	return value, nil
}

// Run reads operator-owned environment secrets only after configuration and cancellation checks.
func Run(ctx context.Context, config Config) error {
	if ctx == nil {
		return ErrUnavailable
	}
	if ctx.Err() != nil {
		return nil
	}
	if config.Validate() != nil {
		return ErrUnavailable
	}
	keyText, ok := os.LookupEnv(config.StateKeyEnv)
	if !ok {
		return ErrUnavailable
	}
	stateKey, err := base64.StdEncoding.DecodeString(keyText)
	if err != nil || len(stateKey) != 32 {
		return ErrUnavailable
	}
	keys, tokens := map[string]string{}, map[string]string{}
	collector := &configuredCollector{sources: map[string]SourceConfig{}, keys: keys}
	for _, source := range config.Sources {
		secret, err := environmentSecret(source.ManagementKeyEnv, 1, false)
		if err != nil {
			return ErrUnavailable
		}
		keys[source.ManagementKeyEnv] = secret
		accounts := make([]cpa.Account, 0, len(source.Accounts))
		for _, account := range source.Accounts {
			accounts = append(accounts, cpa.Account{ID: account.ID, Provider: account.Provider, Selection: account.Selection, Reader: account.Reader})
		}
		if _, err := cpa.New(cpa.Config{BaseURL: source.BaseURL, ManagementKey: secret, Accounts: accounts}); err != nil {
			return ErrUnavailable
		}
		collector.sources[source.ID] = source
	}
	for _, principal := range config.Principals {
		secret, err := environmentSecret(principal.BearerTokenEnv, 32, true)
		if err != nil {
			return ErrUnavailable
		}
		tokens[principal.BearerTokenEnv] = secret
	}
	var notifier Notifier
	if !config.DryRun {
		pem, ok := os.LookupEnv(config.APNs.PrivateKeyEnv)
		if !ok || len(pem) > 16384 {
			return ErrUnavailable
		}
		key, err := apns.ParseKey([]byte(pem))
		if err != nil {
			return ErrUnavailable
		}
		provider, err := apns.New(apns.Config{TeamID: config.APNs.TeamID, KeyID: config.APNs.KeyID, BundleID: config.APNs.BundleID, Environment: config.APNs.Environment, Key: key})
		if err != nil {
			return ErrUnavailable
		}
		notifier = apnsNotifier{provider}
	}
	if ctx.Err() != nil {
		return nil
	}
	store, err := OpenFileStore(config.StatePath, stateKey)
	if err != nil {
		return ErrUnavailable
	}
	defer store.Close()
	service, err := NewService(Options{Context: ctx, Config: config, Store: store, Tokens: tokens, Keys: keys, CPA: collector, Notifier: notifier})
	if err != nil {
		return ErrUnavailable
	}
	defer service.Close()
	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		return ErrUnavailable
	}
	defer listener.Close()
	server := &http.Server{Addr: config.Listen, Handler: service.Handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 15 * time.Second, WriteTimeout: 75 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}, BaseContext: func(net.Listener) context.Context { return service.ctx }}
	schedulerDone := make(chan struct{})
	go func() { defer close(schedulerDone); service.Schedule(service.ctx, time.Second) }()
	served := make(chan error, 1)
	go func() {
		if config.TLSCertFile != "" {
			served <- server.ServeTLS(listener, config.TLSCertFile, config.TLSKeyFile)
		} else {
			served <- server.Serve(listener)
		}
	}()
	select {
	case <-ctx.Done():
	case <-service.ctx.Done():
	case <-served:
		service.Close()
		server.Close()
		<-schedulerDone
		return ErrUnavailable
	}
	service.Close()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if server.Shutdown(shutdown) != nil {
		server.Close()
	}
	<-schedulerDone
	if ctx.Err() != nil {
		return nil
	}
	return ErrUnavailable
}
