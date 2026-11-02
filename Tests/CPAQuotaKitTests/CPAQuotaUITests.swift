import Foundation
import Testing
@testable import CPAQuotaKit
import CPAQuotaUI

@Suite("CPAQuotaUI session, presentation, and contract fidelity tests")
struct CPAQuotaUITests {
    @Test @MainActor
    func sessionConnectSavesCredentialsOnlyAfterSuccessfulLoadAndRestoresCleanly() async throws {
        let transport = try ScenarioTransport(accounts: [
            FixtureAccount("codex-1", provider: "codex"),
            FixtureAccount("free-1", provider: "freetier", plugin: true)
        ])
        await transport.setReply(FixtureReply(body: Fixtures.pluginBody), for: "index-free-1")

        let credentials = MemoryCredentialStore()
        let prefs = MemoryPreferencesStore()
        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: prefs,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )

        #expect(session.authState == .unconfigured)

        await session.connect(
            serverAddress: "https://ra2.cpa.example/v0/management/",
            managementKeyInput: "valid-management-secret",
            rememberInKeychain: true
        )

        let expectedServer = try CPAServer(baseURL: "https://ra2.cpa.example")
        #expect(session.authState == .connected(server: expectedServer, isRememberedInKeychain: true))
        #expect(prefs.loadSavedServerIdentifier() == "https://ra2.cpa.example")
        #expect(try await credentials.load(for: expectedServer) != nil)
        #expect(session.accounts.count == 2)
        #expect(session.managementKeyDraft.isEmpty)

        // Restore in a fresh session instance
        let restoredSession = CPAQuotaSession(
            credentialStore: credentials,
            preferences: prefs,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )
        await restoredSession.restoreSessionIfAvailable()
        #expect(restoredSession.authState == .connected(server: expectedServer, isRememberedInKeychain: true))
        #expect(restoredSession.accounts.count == 2)

        // Forget connection removes Keychain item and clears state
        await restoredSession.forgetCurrentConnection()
        #expect(restoredSession.authState == .unconfigured)
        #expect(prefs.loadSavedServerIdentifier() == nil)
        #expect(try await credentials.load(for: expectedServer) == nil)
    }

    @Test @MainActor
    func failedManagementConnectionDoesNotPersistInvalidKeyToKeychain() async throws {
        let transport = try ScenarioTransport(accounts: [FixtureAccount("codex-1")])
        await transport.setAccountStatus(401)

        let credentials = MemoryCredentialStore()
        let prefs = MemoryPreferencesStore()
        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: prefs,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )

        await session.connect(
            serverAddress: "https://ra2.cpa.example",
            managementKeyInput: "wrong-key",
            rememberInKeychain: true
        )

        let server = try CPAServer(baseURL: "https://ra2.cpa.example")
        #expect(session.authState == .unconfigured)
        #expect(session.connectionFormError?.kind == .managementUnauthorized)
        #expect(try await credentials.load(for: server) == nil)
        #expect(prefs.loadSavedServerIdentifier() == nil)
    }

    @Test @MainActor
    func upstreamUnauthorizedIsolatesSingleAccountWithoutRemovingManagementKey() async throws {
        let transport = try ScenarioTransport(accounts: [
            FixtureAccount("codex-ok", provider: "codex"),
            FixtureAccount("codex-expired", provider: "codex")
        ])
        await transport.setReply(
            FixtureReply(upstreamStatus: 401, body: #"{"error":"expired"}"#),
            for: "index-codex-expired"
        )

        let credentials = MemoryCredentialStore()
        let prefs = MemoryPreferencesStore()
        let session = CPAQuotaSession(
            credentialStore: credentials,
            preferences: prefs,
            clientFactory: { server, key in
                CPAClient(server: server, managementKey: key, transport: transport)
            }
        )

        await session.connect(
            serverAddress: "https://ra2.cpa.example",
            managementKeyInput: "valid-mgmt-key",
            rememberInKeychain: true
        )

        let server = try CPAServer(baseURL: "https://ra2.cpa.example")
        #expect(try await credentials.load(for: server) != nil)
        #expect(session.records["codex-ok"]?.snapshot != nil)
        #expect(session.records["codex-ok"]?.error == nil)
        #expect(session.records["codex-expired"]?.error?.kind == .upstreamUnauthorized)
    }

    @Test
    func windowAndMetricPresentationsFollowStrictUnitAndOverQuotaContracts() {
        let overWindow = QuotaWindow(
            id: "w-over",
            title: "24h Window",
            durationSeconds: 86_400,
            usedFraction: 1.08,
            resetAt: Date(timeIntervalSince1970: 1_900_000_000),
            allowed: false,
            limitReached: true
        )
        let winPres = WindowPresentation(window: overWindow)
        #expect(winPres.durationText == "1 天窗口 (86400s)")
        #expect(winPres.isOverQuota)
        #expect(winPres.primaryPercentageText(for: .used) == "108% 已用")
        #expect(winPres.primaryPercentageText(for: .remaining) == "0% 剩余")
        #expect(winPres.progressBarFraction(for: .used) == 1.0)
        #expect(winPres.progressBarFraction(for: .remaining) == 0.0)

        let unknownWindow = QuotaWindow(id: "w-nil", title: "Unknown", durationSeconds: nil, usedFraction: nil)
        let nilPres = WindowPresentation(window: unknownWindow)
        #expect(nilPres.durationText == "窗口长度未知")
        #expect(nilPres.primaryPercentageText(for: .remaining) == "剩余比例未知")
        #expect(nilPres.progressBarFraction(for: .remaining) == nil)

        // Currency formatting only when currency is explicitly provided
        let eurMetric = QuotaMetric(id: "m1", label: "Balance", value: 25.0, unit: nil, format: "currency", currency: "EUR")
        #expect(MetricPresentation(metric: eurMetric).formattedValue == "25.00 EUR")

        let rawUnitMetric = QuotaMetric(id: "m2", label: "Requests", value: 1840, unit: "requests", format: "integer", currency: nil)
        #expect(MetricPresentation(metric: rawUnitMetric).formattedValue == "1840 requests")

        let nilMetric = QuotaMetric(id: "m3", label: "Unknown", value: nil)
        #expect(MetricPresentation(metric: nilMetric).formattedValue == "数值未知")
    }

    @Test
    func futureObservationsAreStaleWithoutClaimingExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for source in [QuotaSource.live, .passive] {
            let snapshot = QuotaSnapshot(accountID: "future", provider: "codex", source: source,
                                         fetchedAt: now, observedAt: now.addingTimeInterval(120))
            let badge = QuotaFormatter.freshnessBadge(for: snapshot, now: now)
            #expect(badge.isStale)
            #expect(badge.badgeText.contains("时效待确认"))
            #expect(badge.badgeText.contains("时间偏移异常"))
            #expect(!badge.badgeText.contains("过期"))
        }
    }

    @Test
    func freshnessAndEmailMaskingFollowPrivacyAndPassiveContracts() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let passiveWithoutObserved = QuotaSnapshot(
            accountID: "acc-1",
            provider: "codex",
            source: .passive,
            fetchedAt: now,
            observedAt: nil
        )
        let badge = QuotaFormatter.freshnessBadge(for: passiveWithoutObserved, now: now)
        #expect(badge == .passiveStaleOrUnknown(ageText: nil))
        #expect(badge.isStale)

        #expect(QuotaFormatter.maskEmail("rin.primary@workspace.dev", enabled: true) == "ri***y@workspace.dev")
        #expect(QuotaFormatter.maskEmail("rin.primary@workspace.dev", enabled: false) == "rin.primary@workspace.dev")
        #expect(QuotaFormatter.maskEmail(nil, enabled: true) == "未提供邮箱标识")
    }
}
