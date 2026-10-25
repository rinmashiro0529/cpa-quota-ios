import Foundation
import Testing
@testable import CPAQuotaKit

private let fixedNow = Date(timeIntervalSince1970: 1_792_900_000)

private func payload(_ text: String) -> Data { Data(text.utf8) }

private func captureCPAError(_ body: () throws -> Void) -> CPAError? {
    do {
        try body()
        return nil
    } catch {
        return error as? CPAError
    }
}

private func window(in snapshot: QuotaSnapshot, id: String) throws -> QuotaWindow {
    try #require(snapshot.windows.first { $0.id == id })
}

private let codexAccount = CPAAccount(id: "codex-account", authIndex: "idx-codex",
                                      provider: "codex", displayName: "Codex Account")

private let pluginAccount = CPAAccount(id: "plugin-account", authIndex: "idx-plugin",
                                       provider: "freetier", displayName: "Free Tier")

private let xaiAccount = CPAAccount(id: "xai-account", authIndex: "idx-xai",
                                    provider: "xai", displayName: "xAI Account",
                                    status: "disabled", isDisabled: true)

@Suite("Wire date parsing")
struct WireDateParsingTests {
    @Test("RFC3339 nanoseconds resolve Z and +08:00 to the same instant")
    func parsesRFC3339Offsets() throws {
        let utc = try #require(WireDate.parse("2026-10-25T10:03:40.760859731Z"))
        let offset = try #require(WireDate.parse("2026-10-25T18:03:40.760859731+08:00"))
        let compactOffset = try #require(WireDate.parse("2026-10-25T18:03:40.760859731+0800"))
        #expect(abs(utc.timeIntervalSince1970 - 1_792_922_620.760_859_731) < 0.000_001)
        #expect(abs(utc.timeIntervalSince1970 - offset.timeIntervalSince1970) < 0.000_001)
        #expect(abs(utc.timeIntervalSince1970 - compactOffset.timeIntervalSince1970) < 0.000_001)
    }

    @Test("Unix seconds arrive as numeric strings")
    func parsesUnixSecondsString() throws {
        let parsed = try #require(WireDate.parse("1792922620"))
        #expect(parsed == Date(timeIntervalSince1970: 1_792_922_620))
    }

    @Test("Retry-After accepts delays and HTTP dates")
    func parsesRetryAfter() {
        #expect(WireDate.retryAfter("120", now: fixedNow) == fixedNow.addingTimeInterval(120))
        #expect(WireDate.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: fixedNow)
            == Date(timeIntervalSince1970: 1_445_412_480))
        #expect(WireDate.retryAfter("1e100", now: fixedNow) == nil)
        #expect(WireDate.retryAfter(nil, now: fixedNow) == nil)
        #expect(WireDate.retryAfter("soon", now: fixedNow) == nil)
    }

    @Test("rejects RFC3339 values without a timezone")
    func rejectsMissingTimeZone() {
        #expect(WireDate.parse("2026-10-25T10:03:40") == nil)
        #expect(WireDate.parse("2026-10-25T10:03:40.123") == nil)
        #expect(WireDate.parse("2026-10-25 10:03:40") == nil)
    }

    @Test("HTTP-date requires an explicit supported zone and no trailing fields")
    func validatesHTTPDateZones() {
        let expected = Date(timeIntervalSince1970: 784_111_777)
        #expect(WireDate.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: fixedNow) == expected)
        #expect(WireDate.retryAfter("Sun, 06 Nov 1994 08:49:37 UTC", now: fixedNow) == expected)
        #expect(WireDate.retryAfter("Sunday, 06-Nov-94 08:49:37 GMT", now: fixedNow) == expected)
        #expect(WireDate.retryAfter("Sun Nov  6 08:49:37 1994", now: fixedNow) == expected)
        #expect(WireDate.retryAfter("Sun, 06 Nov 1994 08:49:37 PST", now: fixedNow) == nil)
        #expect(WireDate.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT extra", now: fixedNow) == nil)
        #expect(WireDate.retryAfter("Sunday, 06-Nov-94 08:49:37 PST", now: fixedNow) == nil)
        #expect(WireDate.retryAfter("Sunday, 06-Nov-94 08:49:37 GMT extra", now: fixedNow) == nil)
        #expect(WireDate.retryAfter("Sun Nov  6 08:49:37 1994 PST", now: fixedNow) == nil)
        #expect(WireDate.retryAfter("Sun, 06 Nov 1994 08:49:37", now: fixedNow) == nil)
    }

    @Test("rejects epochs outside the representable calendar range")
    func rejectsOutOfRangeEpochs() {
        #expect(WireDate.parse("253402300799") != nil)
        #expect(WireDate.parse("253402300800") == nil)
        #expect(WireDate.parse("-62135596800") != nil)
        #expect(WireDate.parse("-62135596801") == nil)
        #expect(WireDate.parse("1e100") == nil)
    }

    @Test("malformed calendar values are rejected")
    func rejectsMalformedDates() {
        #expect(WireDate.parse("") == nil)
        #expect(WireDate.parse("2026-13-01T00:00:00Z") == nil)
        #expect(WireDate.parse("2026-02-30T00:00:00Z") == nil)
        #expect(WireDate.parse("2026-10-25T25:00:00Z") == nil)
    }
}

@Suite("Inventory")
struct InventoryTests {
    @Test("decodes identities, status, and per-entry passive snapshots")
    func decodesInventory() throws {
        let json = #"""
        {
          "files": [
            {
              "id": "auth-1",
              "name": "codex-one.json",
              "auth_index": "idx-1",
              "provider": "codex",
              "status": "active",
              "disabled": false,
              "label": "Codex One",
              "email": "one@example.invalid",
              "id_token": {"chatgpt_account_id": "chatgpt-1", "plan_type": "team"},
              "quota": {
                "observed_at": "2026-10-25T18:03:40.760859731+08:00",
                "signals": {
                  "X-Codex-Primary-Used-Percent": "47",
                  "X-Codex-Secondary-Used-Percent": "7",
                  "X-Codex-Primary-Window-Minutes": "300",
                  "X-Codex-Secondary-Window-Minutes": "10080",
                  "X-Codex-Primary-Reset-At": "1792933413",
                  "X-Codex-Primary-Reset-After-Seconds": "10798",
                  "X-Codex-Secondary-Reset-At": "1793520213",
                  "X-Codex-Secondary-Reset-After-Seconds": "597598",
                  "X-Codex-Plan-Type": "team",
                  "X-Codex-Credits-Has-Credits": "False",
                  "X-Codex-Credits-Unlimited": "FALSE"
                }
              }
            },
            {
              "name": "codex-two",
              "provider": "codex",
              "status": "active",
              "quota": {"observed_at": "2026-10-25T10:00:00Z", "signals": {}}
            },
            {
              "id": "xai-3",
              "auth_index": 42,
              "type": "xai",
              "status": "disabled",
              "disabled": 1,
              "email": "three@example.invalid"
            }
          ],
          "observed_at": "2026-10-25T10:03:42.082710028Z"
        }
        """#

        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        #expect(inventory.entries.count == 3)
        #expect(inventory.observedAt == WireDate.parse("2026-10-25T10:03:42.082710028Z"))

        let first = inventory.entries[0]
        #expect(first.account.id == "auth-1")
        #expect(first.account.authIndex == "idx-1")
        #expect(first.account.provider == "codex")
        #expect(first.account.displayName == "Codex One")
        #expect(first.account.email == "one@example.invalid")
        #expect(first.account.status == "active")
        #expect(first.account.plan == "team")
        #expect(first.codexAccountID == "chatgpt-1")

        let passive = try #require(first.passiveSnapshot)
        let quotaObservedAt = try #require(WireDate.parse("2026-10-25T18:03:40.760859731+08:00"))
        #expect(passive.source == .passive)
        #expect(passive.observedAt == quotaObservedAt)
        #expect(passive.observedAt != inventory.observedAt)
        #expect(passive.plan == "team")

        let primary = try window(in: passive, id: "primary")
        #expect(primary.usedFraction == 0.47)
        #expect(primary.durationSeconds == 18_000)
        #expect(primary.resetAt == Date(timeIntervalSince1970: 1_792_933_413))
        #expect(primary.title == "5-hour limit")
        #expect(primary.allowed == nil)
        #expect(primary.limitReached == nil)

        let secondary = try window(in: passive, id: "secondary")
        #expect(secondary.usedFraction == 0.07)
        #expect(secondary.durationSeconds == 604_800)
        #expect(secondary.resetAt == Date(timeIntervalSince1970: 1_793_520_213))

        let credits = try #require(passive.credits)
        #expect(credits.hasCredits == false)
        #expect(credits.unlimited == false)
        #expect(credits.balance == nil)

        let second = inventory.entries[1]
        #expect(second.account.id == "codex-two")
        #expect(second.account.authIndex == nil)
        #expect(second.passiveSnapshot == nil)

        let third = inventory.entries[2]
        #expect(third.account.provider == "xai")
        #expect(third.account.authIndex == "42")
        #expect(third.account.isDisabled)
        #expect(third.account.status == "disabled")
        #expect(third.account.displayName == "three@example.invalid")
    }

    @Test("does not substitute the list observation time for quota observation time")
    func rootObservationIsNotQuotaObservation() throws {
        let json = #"""
        {"observed_at": "2026-10-25T10:03:42Z", "files": [
          {"id": "c1", "provider": "codex",
           "quota": {"signals": {"X-Codex-Primary-Used-Percent": "50"}}}
        ]}
        """#
        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        #expect(inventory.observedAt != nil)
        #expect(inventory.entries[0].passiveSnapshot == nil)
    }

    @Test("falls back to the newest valid model quota")
    func newestModelQuota() throws {
        let json = #"""
        {"files": [{"id": "m1", "provider": "codex", "model_quotas": {
          "gpt-5": {"observed_at": "2026-10-25T09:00:00Z",
                    "signals": {"X-Codex-Primary-Used-Percent": "10"}},
          "gpt-6": {"observed_at": "2026-10-25T10:00:00Z",
                    "signals": {"X-Codex-Primary-Used-Percent": "20"}},
          "gpt-7": {"signals": {"X-Codex-Primary-Used-Percent": "99"}}
        }}]}
        """#
        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        let snapshot = try #require(inventory.entries[0].passiveSnapshot)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.usedFraction == 0.2)
        #expect(snapshot.observedAt == WireDate.parse("2026-10-25T10:00:00Z"))
    }

    @Test("handles extreme passive window values without trapping")
    func handlesExtremePassiveValues() throws {
        let json = #"""
        {"files": [{"id": "extreme", "provider": "codex", "quota": {
          "observed_at": "2026-10-25T10:00:00Z",
          "signals": {
            "X-Codex-Primary-Used-Percent": "1",
            "X-Codex-Primary-Window-Minutes": "1e100",
            "X-Codex-Primary-Reset-At": "1e100",
            "X-Codex-Primary-Reset-After-Seconds": "1e100"
          }
        }}]}
        """#
        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        let snapshot = try #require(inventory.entries[0].passiveSnapshot)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.durationSeconds == nil)
        #expect(primary.resetAt == nil)
        #expect(primary.title == "Quota window")
    }

    @Test("reads parsed identity from metadata when id_token is not top-level")
    func readsMetadataIdentity() throws {
        let json = #"""
        {"files": [{"id": "m2", "provider": "codex",
          "metadata": {"id_token": {"chatgpt_account_id": "meta-id", "plan_type": "plus"}}}]}
        """#
        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        #expect(inventory.entries[0].codexAccountID == "meta-id")
        #expect(inventory.entries[0].account.plan == "plus")
    }

    @Test("rejects duplicate account identifiers")
    func rejectsDuplicateIdentifiers() throws {
        let json = #"""
        {"files": [{"id": "dup", "provider": "codex"}, {"id": "dup", "provider": "codex"}]}
        """#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }

    @Test("rejects entries with no id, name, or auth index")
    func rejectsMissingIdentifier() throws {
        let json = #"{"files": [{"provider": "codex", "status": "active"}]}"#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }

    @Test("keeps unknown providers without inventing quota")
    func keepsUnknownProvider() throws {
        let json = #"{"files": [{"id": "u1", "status": "active"}]}"#
        let inventory = try PayloadDecoder.inventory(payload(json), now: fixedNow)
        #expect(inventory.entries[0].account.provider == "unknown")
        #expect(inventory.entries[0].passiveSnapshot == nil)
    }
}

@Suite("Provider discovery")
struct ProviderDiscoveryTests {
    @Test("reads provider names from the capability response")
    func readsProviderNames() throws {
        let json = #"""
        {"providers": [{"plugin_id": "freetier2api", "provider": "freetier",
                        "supported_providers": ["freetier"]}]}
        """#
        let providers = try PayloadDecoder.providers(payload(json))
        #expect(providers == ["freetier"])
    }

    @Test("accepts an empty provider list")
    func acceptsEmptyList() throws {
        let providers = try PayloadDecoder.providers(payload(#"{"providers": []}"#))
        #expect(providers.isEmpty)
    }

    @Test("rejects a malformed envelope")
    func rejectsMalformedEnvelope() throws {
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.providers(payload(#"{"providers": {}}"#))
        })
        #expect(error.kind == .invalidResponse)
    }
}

@Suite("api-call envelope")
struct APICallEnvelopeTests {
    @Test("returns a JSON string body as data")
    func unwrapsStringBody() throws {
        let json = #"""
        {"status_code": 200, "header": {}, "body": "{\"plan_type\": \"team\"}"}
        """#
        let body = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["plan_type"] as? String == "team")
    }

    @Test("returns an object body as data")
    func unwrapsObjectBody() throws {
        let json = #"{"status_code": 201, "body": {"ok": true}}"#
        let body = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
    }

    @Test("maps an upstream 401 with an array Retry-After")
    func unwrapsUnauthorized() throws {
        let json = #"""
        {"status_code": 401, "header": {"Retry-After": ["30"]}, "body": "denied"}
        """#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        })
        #expect(error.kind == .upstreamUnauthorized)
        #expect(error.layer == .upstream)
        #expect(error.statusCode == 401)
        #expect(error.retryAfter == fixedNow.addingTimeInterval(30))
    }

    @Test("maps an upstream 429 with a scalar Retry-After")
    func unwrapsRateLimited() throws {
        let json = #"""
        {"status_code": 429, "header": {"retry-after": "120"}, "body": {"error": "slow down"}}
        """#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        })
        #expect(error.kind == .rateLimited)
        #expect(error.layer == .upstream)
        #expect(error.statusCode == 429)
        #expect(error.retryAfter == fixedNow.addingTimeInterval(120))
    }

    @Test("maps other upstream failures without surfacing the body")
    func unwrapsOtherFailures() throws {
        let json = #"""
        {"status_code": 503, "body": "internal detail that must not be surfaced"}
        """#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        })
        #expect(error.kind == .upstreamFailure)
        #expect(error.statusCode == 503)
    }

    @Test("rejects envelopes without a status code")
    func rejectsMissingStatus() throws {
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.unwrapAPICall(payload(#"{"body": "{}"}"#), now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }

    @Test("rejects a non-JSON body string")
    func rejectsNonJSONBody() throws {
        let json = #"{"status_code": 200, "body": "not json"}"#
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }

    @Test("accepts numeric status codes encoded as strings")
    func acceptsStringStatus() throws {
        let json = #"{"status_code": "200", "body": {"ok": true}}"#
        let body = try PayloadDecoder.unwrapAPICall(payload(json), now: fixedNow)
        #expect(!body.isEmpty)
    }
}

private let codexUsageJSON = #"""
{
  "plan_type": "team",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 58,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 9700,
      "reset_at": 1792933413
    },
    "secondary_window": {
      "used_percent": 9,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 596500
    }
  },
  "code_review_rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {"used_percent": 10, "limit_window_seconds": 18000}
  },
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5 Codex",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {"used_percent": 25, "limit_window_seconds": 18000},
        "secondary_window": {"used_percent": 50, "limit_window_seconds": 604800}
      }
    }
  ],
  "credits": {"has_credits": true, "unlimited": false, "balance": null}
}
"""#

@Suite("Codex quota")
struct CodexQuotaTests {
    @Test("normalizes primary, secondary, review, and additional windows")
    func decodesActiveWindows() throws {
        let snapshot = try PayloadDecoder.codex(payload(codexUsageJSON),
                                                account: codexAccount, now: fixedNow)
        #expect(snapshot.source == .live)
        #expect(snapshot.plan == "team")
        #expect(snapshot.windows.count == 5)

        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.usedFraction == 0.58)
        #expect(primary.durationSeconds == 18_000)
        #expect(primary.resetAt == Date(timeIntervalSince1970: 1_792_933_413))
        #expect(primary.title == "5-hour limit")
        #expect(primary.allowed == true)
        #expect(primary.limitReached == false)

        let secondary = try window(in: snapshot, id: "secondary")
        #expect(secondary.usedFraction == 0.09)
        #expect(secondary.resetAt == fixedNow.addingTimeInterval(596_500))

        let review = try window(in: snapshot, id: "code-review-primary")
        #expect(review.usedFraction == 0.10)
        #expect(review.title == "Code review · 5-hour limit")

        let additionalPrimary = try window(in: snapshot, id: "gpt-5-codex-1-primary")
        #expect(additionalPrimary.usedFraction == 0.25)
        let additionalSecondary = try window(in: snapshot, id: "gpt-5-codex-1-secondary")
        #expect(additionalSecondary.usedFraction == 0.50)

        let credits = try #require(snapshot.credits)
        #expect(credits.hasCredits == true)
        #expect(credits.unlimited == false)
        #expect(credits.balance == nil)
    }

    @Test("accepts string percentages and window lengths")
    func acceptsStringPercentages() throws {
        let json = #"""
        {"rate_limit": {"primary_window": {"used_percent": "42", "limit_window_seconds": "18000"}}}
        """#
        let snapshot = try PayloadDecoder.codex(payload(json), account: codexAccount, now: fixedNow)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.usedFraction == 0.42)
        #expect(primary.durationSeconds == 18_000)
    }

    @Test("keeps null credits unknown while preserving a real zero percent")
    func keepsNullCreditsUnknown() throws {
        let json = #"""
        {"plan_type": "team",
         "rate_limit": {"primary_window": {"used_percent": 0}},
         "credits": null}
        """#
        let snapshot = try PayloadDecoder.codex(payload(json), account: codexAccount, now: fixedNow)
        #expect(snapshot.credits == nil)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.usedFraction == 0)
    }

    @Test("rejects bodies without any recognizable quota data")
    func rejectsUnrecognizedBody() throws {
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.codex(payload(#"{"plan_type": "team"}"#),
                                         account: codexAccount, now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }

    @Test("handles extreme finite window seconds without trapping")
    func handlesExtremeWindowSeconds() throws {
        let json = #"""
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 1e100}}}
        """#
        let snapshot = try PayloadDecoder.codex(payload(json), account: codexAccount, now: fixedNow)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.durationSeconds == nil)
        #expect(primary.title == "Quota window")
    }

    @Test("rejects extreme finite reset values")
    func rejectsExtremeResetValues() throws {
        let json = #"""
        {"rate_limit": {"primary_window": {
          "used_percent": 1,
          "reset_at": 1e100,
          "reset_after_seconds": 1e100
        }}}
        """#
        let snapshot = try PayloadDecoder.codex(payload(json), account: codexAccount, now: fixedNow)
        let primary = try window(in: snapshot, id: "primary")
        #expect(primary.resetAt == nil)
    }

    @Test("keeps additional window identifiers unique when labels repeat")
    func uniqueAdditionalWindowIdentifiers() throws {
        let json = #"""
        {"additional_rate_limits": [
          {"limit_name": "Extra", "rate_limit": {"primary_window": {"used_percent": 1}}},
          {"limit_name": "Extra", "rate_limit": {"primary_window": {"used_percent": 2}}}
        ]}
        """#
        let snapshot = try PayloadDecoder.codex(payload(json), account: codexAccount, now: fixedNow)
        #expect(snapshot.windows.count == 2)
        #expect(Set(snapshot.windows.map(\.id)).count == 2)
        #expect(snapshot.windows.map(\.id) == ["extra-1-primary", "extra-2-primary"])
    }
}

@Suite("Plugin quota")
struct PluginQuotaTests {
    @Test("decodes a summary-only response without groups")
    func decodesSummaryOnly() throws {
        let json = #"""
        {
          "subscription": {"plan": "free", "tierName": "Free", "tierId": "free-tier"},
          "summary": [
            {"key": "requests", "label": "Requests", "value": 1000, "unit": "requests"},
            {"key": "balance", "label": "Balance", "value": 12.5,
             "unit": "credit", "format": "currency", "currency": "EUR"}
          ]
        }
        """#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        #expect(snapshot.plan == "free")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.metrics.count == 2)

        let requests = try #require(snapshot.metrics.first { $0.id == "requests" })
        #expect(requests.value == 1000)
        #expect(requests.unit == "requests")

        let balance = try #require(snapshot.metrics.first { $0.id == "balance" })
        #expect(balance.value == 12.5)
        #expect(balance.currency == "EUR")
        #expect(balance.format == "currency")
    }

    @Test("converts remaining fractions into used fractions")
    func convertsRemainingFraction() throws {
        let json = #"""
        {"groups": [{"display_name": "Daily", "buckets": [
          {"window": "requests", "remaining_fraction": "0.25",
           "reset_time": "2026-11-01T00:00:00Z", "description": "Daily requests"},
          {"window": "tokens", "remainingFraction": 1}
        ]}]}
        """#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        #expect(snapshot.windows.count == 2)

        let daily = try #require(snapshot.windows.first { $0.title == "Daily requests" })
        #expect(daily.usedFraction == 0.75)
        #expect(daily.resetAt == Date(timeIntervalSince1970: 1_793_491_200))

        let tokens = try #require(snapshot.windows.first { $0.title == "tokens" })
        #expect(tokens.usedFraction == 0)
    }

    @Test("keeps missing metric values unknown")
    func keepsMissingMetricValueUnknown() throws {
        let json = #"{"summary": [{"key": "x", "label": "X"}]}"#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        let metric = try #require(snapshot.metrics.first)
        #expect(metric.value == nil)
    }

    @Test("keeps metric identifiers unique when keys repeat")
    func keepsMetricIdentifiersUnique() throws {
        let json = #"""
        {"summary": [
          {"key": "x-3", "label": "First", "value": 1},
          {"key": "x", "label": "Second", "value": 2},
          {"key": "x", "label": "Third", "value": 3}
        ]}
        """#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        #expect(snapshot.metrics.count == 3)
        #expect(Set(snapshot.metrics.map(\.id)).count == 3)
        #expect(snapshot.metrics.map(\.id) == ["x-3", "x", "x-4"])
    }

    @Test("keeps bucket identifiers unique when names repeat")
    func keepsBucketIdentifiersUnique() throws {
        let json = #"""
        {"groups": [{"display_name": "Same", "buckets": [
          {"window": "w", "remainingFraction": 0.5},
          {"window": "w", "remainingFraction": 0.25}
        ]}]}
        """#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        #expect(snapshot.windows.count == 2)
        #expect(Set(snapshot.windows.map(\.id)).count == 2)
    }

    @Test("tolerates null summary and groups")
    func toleratesNullCollections() throws {
        let json = #"{"subscription": {"plan": "free"}, "summary": null, "groups": null}"#
        let snapshot = try PayloadDecoder.pluginQuota(payload(json), account: pluginAccount, now: fixedNow)
        #expect(snapshot.plan == "free")
        #expect(snapshot.metrics.isEmpty)
        #expect(snapshot.windows.isEmpty)
    }

    @Test("rejects responses without a quota shape")
    func rejectsUnknownShape() throws {
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.pluginQuota(payload(#"{}"#), account: pluginAccount, now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }
}

@Suite("xAI billing")
struct XAIBillingTests {
    // Structural fixture only: the live xAI account was disabled and was not queried.
    @Test("converts USD cents and computes the monthly ratio")
    func convertsCents() throws {
        let json = #"""
        {"config": {
          "monthlyLimit": {"val": 2000},
          "used": {"val": 500},
          "onDemandCap": 1000,
          "billingPeriodEnd": "2026-11-01T00:00:00Z"
        }}
        """#
        let snapshot = try PayloadDecoder.xai(payload(json), account: xaiAccount, now: fixedNow)

        let monthly = try window(in: snapshot, id: "monthly")
        #expect(monthly.usedFraction == 0.25)
        #expect(monthly.resetAt == Date(timeIntervalSince1970: 1_793_491_200))

        let limit = try #require(snapshot.metrics.first { $0.id == "monthly-limit" })
        #expect(limit.value == 20)
        #expect(limit.format == "currency")
        #expect(limit.currency == "USD")

        let used = try #require(snapshot.metrics.first { $0.id == "used" })
        #expect(used.value == 5)

        let cap = try #require(snapshot.metrics.first { $0.id == "on-demand-cap" })
        #expect(cap.value == 10)
    }

    @Test("rejects responses without a billing config")
    func rejectsMissingConfig() throws {
        let error = try #require(captureCPAError {
            _ = try PayloadDecoder.xai(payload(#"{"ok": true}"#),
                                       account: xaiAccount, now: fixedNow)
        })
        #expect(error.kind == .invalidResponse)
    }
}
