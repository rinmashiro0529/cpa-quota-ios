package cpa

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
)

var (
	ErrConfig    = errors.New("invalid CPA configuration")
	ErrBaseURL   = errors.New("invalid CPA base URL")
	ErrSelection = errors.New("invalid CPA quota selection")
)

const requestTimeout = 75 * time.Second
const collectionTimeout = 240 * time.Second
const maximumBody = 4 * 1024 * 1024

// ValidateBaseURL applies the same validation as New without doing any I/O.
// Paths may contain a deployment prefix and optionally /v0/management or
// /management.html. Percent-encoded paths are deliberately rejected.
func ValidateBaseURL(value string) error { _, err := parseBase(value); return err }

func parseBase(value string) (*url.URL, error) {
	if value != strings.TrimSpace(value) || strings.ContainsAny(value, "\\%?#") || strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return nil, ErrBaseURL
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Opaque != "" || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return nil, ErrBaseURL
	}
	host := u.Hostname()
	if net.ParseIP(host) == nil {
		if len(host) > 253 || strings.Contains(host, ":") {
			return nil, ErrBaseURL
		}
		for _, label := range strings.Split(strings.TrimSuffix(host, "."), ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return nil, ErrBaseURL
			}
			for _, r := range label {
				if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
					return nil, ErrBaseURL
				}
			}
		}
	}
	if strings.HasSuffix(u.Host, ":") {
		return nil, ErrBaseURL
	}
	if port := u.Port(); port != "" {
		n, e := strconv.Atoi(port)
		if e != nil || n < 1 || n > 65535 {
			return nil, ErrBaseURL
		}
	}
	path := strings.TrimRight(u.Path, "/")
	if strings.Contains(u.Path, "//") {
		return nil, ErrBaseURL
	}
	for _, part := range strings.Split(path, "/") {
		if part == "." || part == ".." {
			return nil, ErrBaseURL
		}
	}
	for _, suffix := range []string{"/v0/management", "/management.html"} {
		if strings.HasSuffix(path, suffix) {
			path = strings.TrimSuffix(path, suffix)
			break
		}
	}
	u.Path = path + "/v0/management"
	u.RawPath = ""
	u.Host = strings.ToLower(u.Host)
	return u, nil
}

// ValidateSelection accepts only the fixed selections understood by quota.Normalize.
// The argument is the reader (codex, xai or plugin), never the inventory provider.
func ValidateSelection(reader, selection string) error {
	switch strings.ToLower(reader) {
	case "codex":
		if selection == "primary" || selection == "secondary" {
			return nil
		}
	case "xai":
		if selection == "monthly" || selection == "monthly-limit-usd" || selection == "used-usd" {
			return nil
		}
	case "plugin":
		parts := strings.Split(selection, ":")
		if !(len(parts) == 2 && parts[0] == "summary" || len(parts) == 3 && parts[0] == "bucket") {
			return ErrSelection
		}
		for _, p := range parts[1:] {
			n, e := strconv.Atoi(p)
			if e != nil || n < 0 || strconv.Itoa(n) != p {
				return ErrSelection
			}
		}
		return nil
	}
	return ErrSelection
}

func New(cfg Config) (*Client, error) {
	base, err := parseBase(cfg.BaseURL)
	if err != nil {
		return nil, err
	}
	key := strings.TrimSpace(cfg.ManagementKey)
	if key == "" || len(key) > 4096 || strings.IndexFunc(cfg.ManagementKey, unicode.IsControl) >= 0 || len(cfg.Accounts) == 0 {
		return nil, ErrConfig
	}
	accounts := append([]Account(nil), cfg.Accounts...)
	seen := make(map[string]bool)
	for i, a := range accounts {
		if a.ID == "" || len(a.ID) > 512 || a.ID != strings.TrimSpace(a.ID) || strings.IndexFunc(a.ID, unicode.IsControl) >= 0 || seen[a.ID] {
			return nil, ErrConfig
		}
		reader := a.reader()
		if reader == "" || a.Provider == "" || len(a.Provider) > 128 || strings.IndexFunc(a.Provider, unicode.IsControl) >= 0 {
			return nil, ErrConfig
		}
		if err := ValidateSelection(reader, a.Selection); err != nil {
			return nil, err
		}
		seen[a.ID] = true
		accounts[i].Provider = strings.ToLower(a.Provider)
		accounts[i].Reader = reader
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if cfg.Client != nil {
		ip := net.ParseIP(base.Hostname())
		if ip == nil || !ip.IsLoopback() || base.Port() == "" {
			return nil, ErrConfig
		}
		caller, ok := cfg.Client.Transport.(*http.Transport)
		if !ok || caller == nil {
			return nil, ErrConfig
		}
		// Only a loopback fixture trust pool is accepted. Dialer, proxy, jar and redirect policy stay ours.
		if tc := caller.TLSClientConfig; tc != nil {
			if tc.InsecureSkipVerify {
				return nil, ErrConfig
			}
			if tc.RootCAs != nil {
				tlsConfig.RootCAs = tc.RootCAs.Clone()
			}
		}
	}
	transport := &http.Transport{
		Proxy: nil, TLSClientConfig: tlsConfig, ForceAttemptHTTP2: true,
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: requestTimeout,
		IdleConnTimeout: 90 * time.Second, MaxIdleConns: 3, MaxIdleConnsPerHost: 3, MaxConnsPerHost: 3,
		DisableCompression: true,
		DialContext:        (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	}
	hc := &http.Client{Transport: transport, Timeout: requestTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	request := func(ctx context.Context, method, path string, body []byte) (int, http.Header, []byte, error) {
		var reader io.Reader
		if body != nil {
			reader = bytes.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, base.String()+path, reader)
		if err != nil {
			return 0, nil, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Accept", "application/json")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		response, err := hc.Do(req)
		if err != nil {
			return 0, nil, nil, err
		}
		defer response.Body.Close()
		payload, err := io.ReadAll(io.LimitReader(response.Body, maximumBody+1))
		if err != nil || len(payload) > maximumBody {
			return response.StatusCode, response.Header, nil, ErrConfig
		}
		return response.StatusCode, response.Header.Clone(), payload, nil
	}
	return &Client{origin: originFor(base, now, request, accounts)}, nil
}
