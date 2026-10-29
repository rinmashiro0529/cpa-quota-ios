package apns_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"icu.nahida/cpaquota/monitor/apns"
)

type responseTransport func(*http.Request) (*http.Response, error)

func (r responseTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return r(request)
}

func responseProvider(t *testing.T, transport responseTransport) *apns.Provider {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := apns.New(apns.Config{
		TeamID: "TEAM", KeyID: "KEY", BundleID: "example.fixture", Environment: "sandbox", Key: key,
		Endpoint: "https://127.0.0.1", Client: &http.Client{Transport: transport},
	})
	if err != nil {
		t.Fatal(err)
	}
	return provider
}

func TestRejectionReasonRetainsOnlyBoundedRecognizedValues(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"device token", `{"reason":"BadDeviceToken"}`, "BadDeviceToken"},
		{"unregistered", `{"reason":"Unregistered","timestamp":1800000000}`, "Unregistered"},
		{"provider token", `{"reason":"ExpiredProviderToken"}`, "ExpiredProviderToken"},
		{"untrusted reason", `{"reason":"synthetic-private-response-value"}`, ""},
		{"malformed", `{"reason":"BadDeviceToken"`, ""},
		{"oversized", `{"reason":"BadDeviceToken"}` + strings.Repeat(" ", 4096), ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			provider := responseProvider(t, func(request *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 400, ProtoMajor: 2, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(tc.body))}, nil
			})
			err := provider.Send(context.Background(), "abcd", "update", map[string]int{"expires_at": 1800000900}, 1800000000)
			var rejected *apns.HTTPError
			if !errors.As(err, &rejected) || rejected.Status != 400 || rejected.Reason != tc.want {
				t.Fatalf("unexpected safe classification: %v", err)
			}
			if strings.Contains(err.Error(), "synthetic-private-response-value") || strings.Contains(err.Error(), "abcd") {
				t.Fatal("rejection error disclosed an untrusted body or push token")
			}
		})
	}
}

func TestExpiredProviderTokenInvalidatesOnlyTheCachedJWT(t *testing.T) {
	var authorizations []string
	provider := responseProvider(t, func(request *http.Request) (*http.Response, error) {
		authorizations = append(authorizations, request.Header.Get("authorization"))
		status, body := http.StatusOK, ""
		if len(authorizations) == 1 {
			status, body = http.StatusForbidden, `{"reason":"ExpiredProviderToken"}`
		}
		return &http.Response{StatusCode: status, ProtoMajor: 2, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	first := provider.Send(context.Background(), "abcd", "update", map[string]int{"expires_at": 1800000900}, 1800000000)
	var rejected *apns.HTTPError
	if !errors.As(first, &rejected) || rejected.Reason != "ExpiredProviderToken" {
		t.Fatal("provider-token failure was not classified")
	}
	if err := provider.Send(context.Background(), "abcd", "update", map[string]int{"expires_at": 1800000900}, 1800000001); err != nil {
		t.Fatal(err)
	}
	if len(authorizations) != 2 || authorizations[0] == authorizations[1] {
		t.Fatal("provider cached the JWT after APNs rejected it as expired")
	}
}
