package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var ErrPayloadTooLarge = errors.New("APNs payload exceeds reserved budget")

type HTTPError struct {
	Status     int
	RetryAfter string
	// Reason is a recognized APNs reason only, never an arbitrary response body.
	Reason string
}

func (e *HTTPError) Error() string { return fmt.Sprintf("APNs rejected request: HTTP %d", e.Status) }

type Config struct {
	TeamID, KeyID, BundleID, Environment string
	Key                                  *ecdsa.PrivateKey
	Client                               *http.Client
	// Endpoint is restricted to a loopback TLS server for local testing.
	Endpoint string
}
type Provider struct {
	config   Config
	endpoint string
	client   *http.Client
	mu       sync.Mutex
	token    string
	issued   time.Time
}

func ParseKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("invalid PKCS8 private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid PKCS8 private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("APNs key must be P256")
	}
	return key, nil
}

func New(c Config) (*Provider, error) {
	if c.TeamID == "" || c.KeyID == "" || c.BundleID == "" || c.Key == nil || c.Key.Curve != elliptic.P256() {
		return nil, errors.New("invalid APNs configuration")
	}
	endpoint := ""
	switch c.Environment {
	case "sandbox":
		endpoint = "https://api.sandbox.push.apple.com"
	case "production":
		endpoint = "https://api.push.apple.com"
	default:
		return nil, errors.New("invalid APNs environment")
	}
	client := c.Client
	if c.Endpoint != "" {
		u, err := url.Parse(c.Endpoint)
		if err != nil || u.Scheme != "https" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || net.ParseIP(u.Hostname()) == nil || !net.ParseIP(u.Hostname()).IsLoopback() || client == nil {
			return nil, errors.New("test endpoint must be loopback HTTPS")
		}
		endpoint = c.Endpoint
	} else if client != nil {
		return nil, errors.New("custom HTTP client requires loopback endpoint")
	}
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	safeClient := *client
	safeClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Provider{config: c, endpoint: endpoint, client: &safeClient}, nil
}

func (p *Provider) authorization(now time.Time) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.token != "" && now.Sub(p.issued) >= 0 && now.Sub(p.issued) < 50*time.Minute {
		return p.token, nil
	}
	encode := base64.RawURLEncoding.EncodeToString
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": p.config.KeyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": p.config.TeamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	unsigned := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, p.config.Key, digest[:])
	if err != nil {
		return "", errors.New("APNs signing failed")
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	p.token = unsigned + "." + encode(signature)
	p.issued = now
	return p.token, nil
}

func (p *Provider) Send(ctx context.Context, token, event string, state any, timestamp int64) error {
	decoded, err := hex.DecodeString(token)
	if err != nil || len(token) == 0 || len(token) > 4096 || len(decoded) != len(token)/2 {
		return errors.New("invalid activity push token")
	}
	if event != "update" && event != "end" {
		return errors.New("invalid activity event")
	}
	stateJSON, err := json.Marshal(state)
	if err != nil {
		return errors.New("invalid activity payload")
	}
	var times struct {
		ExpiresAt *float64 `json:"expires_at"`
	}
	if err := json.Unmarshal(stateJSON, &times); err != nil || times.ExpiresAt == nil || math.IsNaN(*times.ExpiresAt) || math.IsInf(*times.ExpiresAt, 0) {
		return errors.New("invalid activity expiry")
	}
	stale := int64(math.Trunc(*times.ExpiresAt))
	if len(stateJSON) > 3584 {
		return ErrPayloadTooLarge
	}
	aps := map[string]any{"timestamp": timestamp, "event": event, "content-state": json.RawMessage(stateJSON), "stale-date": stale}
	if event == "end" {
		aps["dismissal-date"] = timestamp
	}
	body, err := json.Marshal(map[string]any{"aps": aps})
	if err != nil {
		return errors.New("invalid activity payload")
	}
	if len(body) > 4096 {
		return ErrPayloadTooLarge
	}
	jwt, err := p.authorization(time.Now())
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint+"/3/device/"+strings.ToLower(token), bytes.NewReader(body))
	if err != nil {
		return errors.New("invalid APNs request")
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", p.config.BundleID+".push-type.liveactivity")
	req.Header.Set("apns-push-type", "liveactivity")
	req.Header.Set("apns-priority", "5")
	req.Header.Set("content-type", "application/json")
	response, err := p.client.Do(req)
	if err != nil {
		return errors.New("APNs transport failed")
	}
	defer response.Body.Close()
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 4097))
	if response.ProtoMajor != 2 {
		return errors.New("APNs requires HTTP/2")
	}
	if response.StatusCode != http.StatusOK {
		reason := ""
		if readErr == nil && len(responseBody) <= 4096 {
			var failure struct {
				Reason string `json:"reason"`
			}
			if json.Unmarshal(responseBody, &failure) == nil {
				reason = safeReason(failure.Reason)
			}
		}
		if response.StatusCode == http.StatusForbidden && reason == "ExpiredProviderToken" {
			p.mu.Lock()
			if p.token == jwt {
				p.token = ""
			}
			p.mu.Unlock()
		}
		return &HTTPError{Status: response.StatusCode, RetryAfter: response.Header.Get("Retry-After"), Reason: reason}
	}
	return nil
}

func safeReason(reason string) string {
	switch reason {
	case "Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic",
		"ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken",
		"BadTopic", "TopicDisallowed", "Forbidden", "BadCertificate", "BadCertificateEnvironment",
		"TooManyRequests", "TooManyProviderTokenUpdates", "InternalServerError", "ServiceUnavailable", "Shutdown":
		return reason
	default:
		return ""
	}
}
