package apns_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"icu.nahida/cpaquota/monitor/apns"
)

func TestSendRejectsFailuresAndOversize(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	calls := 0
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Retry-After", "42")
		w.WriteHeader(429)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	p, err := apns.New(apns.Config{TeamID: "T", KeyID: "K", BundleID: "app", Environment: "production", Key: key, Client: server.Client(), Endpoint: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("ab", 32)
	err = p.Send(context.Background(), token, "update", map[string]any{"value": strings.Repeat("x", 4000), "expires_at": 99}, 1)
	if !errors.Is(err, apns.ErrPayloadTooLarge) || calls != 0 {
		t.Fatalf("oversize: %v calls=%d", err, calls)
	}
	err = p.Send(context.Background(), token, "end", map[string]int{"version": 1, "expires_at": 99}, 1)
	var status *apns.HTTPError
	if !errors.As(err, &status) || status.Status != 429 || status.RetryAfter != "42" {
		t.Fatalf("failure lost: %v", err)
	}
}

func TestTokenLengthAndStaticReserve(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	var gotPath, gotState string
	var gotStale float64
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var body map[string]map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		gotState = string(must(json.Marshal(body["aps"]["content-state"])))
		gotStale = body["aps"]["stale-date"].(float64)
		w.WriteHeader(http.StatusOK)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	p, err := apns.New(apns.Config{TeamID: "T", KeyID: "K", BundleID: "app", Environment: "sandbox", Key: key, Client: server.Client(), Endpoint: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	short := strings.Repeat("ab", 8)
	if err := p.Send(context.Background(), short, "update", json.RawMessage(`{"expires_at":1800000000.9}`), 10); err != nil || gotPath != "/3/device/"+short || gotStale != 1800000000 {
		t.Fatalf("bounded token or fractional stale-date: %v path=%s stale=%v", err, gotPath, gotStale)
	}
	if err := p.Send(context.Background(), "abc", "update", map[string]int{"expires_at": 1}, 1); err == nil {
		t.Fatal("odd-length token accepted")
	}
	oversized := map[string]any{"expires_at": 1, "value": strings.Repeat("x", 3584)}
	if err := p.Send(context.Background(), short, "update", oversized, 1); !errors.Is(err, apns.ErrPayloadTooLarge) {
		t.Fatalf("content-state reserve not enforced: %v (%s)", err, gotState)
	}
}

func must(v []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return v
}

func TestEndRequestsImmediateDismissalWithoutClaimingDeviceOutcome(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["aps"]["event"] != "end" || body["aps"]["dismissal-date"] != float64(123) {
			t.Error("end must contain the explicit dismissal intent")
		}
		w.WriteHeader(http.StatusOK)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	provider, err := apns.New(apns.Config{TeamID: "TEAM", KeyID: "KEY", BundleID: "example.app", Environment: "sandbox", Key: key, Client: server.Client(), Endpoint: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	if err := provider.Send(context.Background(), "abcd", "end", map[string]any{"expires_at": 99}, 123); err != nil {
		t.Fatal(err)
	}
}

func TestParsePKCS8P256(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := apns.ParseKey(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	if err != nil || parsed.PublicKey.X.Cmp(key.X) != 0 {
		t.Fatalf("key parse failed: %v", err)
	}
	if _, err := apns.ParseKey([]byte("bad")); err == nil {
		t.Fatal("accepted invalid key")
	}
}

func TestSendActivityUpdateOverHTTP2(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 || r.URL.Path != "/3/device/"+strings.Repeat("ab", 32) || r.Header.Get("apns-topic") != "example.app.push-type.liveactivity" || r.Header.Get("apns-push-type") != "liveactivity" || r.Header.Get("apns-priority") != "5" {
			t.Errorf("invalid request: %s %s %v", r.Proto, r.URL.Path, r.Header)
		}
		token := strings.TrimPrefix(r.Header.Get("authorization"), "bearer ")
		parts := strings.Split(token, ".")
		if len(parts) != 3 {
			t.Error("invalid JWT")
			return
		}
		signature, e := base64.RawURLEncoding.DecodeString(parts[2])
		if e != nil || len(signature) != 64 {
			t.Error("invalid signature")
			return
		}
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if !ecdsa.Verify(&key.PublicKey, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
			t.Error("bad signature")
		}
		var body map[string]map[string]any
		if e := json.NewDecoder(r.Body).Decode(&body); e != nil || body["aps"]["event"] != "update" || body["aps"]["content-state"] == nil || body["aps"]["stale-date"] != float64(99) {
			t.Errorf("invalid payload: %v %v", body, e)
		}
		w.WriteHeader(http.StatusOK)
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	p, err := apns.New(apns.Config{TeamID: "TEAM", KeyID: "KEY", BundleID: "example.app", Environment: "sandbox", Key: key, Client: server.Client(), Endpoint: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Send(context.Background(), strings.Repeat("ab", 32), "update", map[string]any{"version": 1, "expires_at": 99}, 123); err != nil {
		t.Fatal(err)
	}
}
