import Foundation

extension PayloadDecoder {
    static func codex(_ data: Data, account: CPAAccount, now: Date) throws -> QuotaSnapshot {
        let root = try WireJSON.decode(data)
        guard case .object = root else { throw CPAError(.invalidResponse) }

        let primaryLimit = root.objectAt("rate_limit", "rateLimit")
        let reviewLimit = root.objectAt("code_review_rate_limit", "codeReviewRateLimit")
        let additionalLimits = root.arrayAt("additional_rate_limits", "additionalRateLimits") ?? []
        let credits = codexCredits(root.lookup("credits"))
        guard primaryLimit != nil || reviewLimit != nil || !additionalLimits.isEmpty || credits != nil else {
            throw CPAError(.invalidResponse)
        }

        var windows: [QuotaWindow] = []
        if let primaryLimit {
            windows += codexRateLimitWindows(primaryLimit, idPrefix: "", titlePrefix: nil, now: now)
        }
        if let reviewLimit {
            windows += codexRateLimitWindows(reviewLimit, idPrefix: "code-review",
                                             titlePrefix: "Code review", now: now)
        }
        if !additionalLimits.isEmpty {
            windows += codexAdditionalWindows(additionalLimits, now: now)
        }

        return QuotaSnapshot(
            accountID: account.id,
            provider: account.provider,
            source: .live,
            fetchedAt: now,
            observedAt: nil,
            plan: nonEmptyWireString(root.stringAt("plan_type", "planType")),
            windows: windows,
            metrics: [],
            credits: credits
        )
    }

    static func pluginQuota(_ data: Data, account: CPAAccount, now: Date) throws -> QuotaSnapshot {
        let root = try WireJSON.decode(data)
        guard case .object = root else { throw CPAError(.invalidResponse) }

        var recognized = false
        var plan: String?
        if let subscription = root.objectAt("subscription") {
            recognized = true
            plan = nonEmptyWireString(subscription.stringAt("plan", "tierName", "tier_name",
                                                            "tierId", "tier_id"))
        }

        var metrics: [QuotaMetric] = []
        if let summaryValue = root.lookup("summary"), summaryValue != .null {
            guard let summary = summaryValue.arrayItems else { throw CPAError(.invalidResponse) }
            recognized = true
            var usedIdentifiers = Set<String>()
            for (index, item) in summary.enumerated() {
                guard case .object = item else { continue }
                let baseID = nonEmptyWireString(item.stringAt("key", "id")) ?? "summary-\(index + 1)"
                let identifier = uniqueWireIdentifier(baseID, used: &usedIdentifiers,
                                                      startingAt: index + 1)
                metrics.append(QuotaMetric(
                    id: identifier,
                    label: nonEmptyWireString(item.stringAt("label", "name")) ?? baseID,
                    value: item.numberAt("value", "val"),
                    unit: nonEmptyWireString(item.stringAt("unit")),
                    format: nonEmptyWireString(item.stringAt("format")),
                    currency: nonEmptyWireString(item.stringAt("currency"))
                ))
            }
        }

        var windows: [QuotaWindow] = []
        if let groupsValue = root.lookup("groups"), groupsValue != .null {
            guard let groups = groupsValue.arrayItems else { throw CPAError(.invalidResponse) }
            recognized = true
            for (groupIndex, group) in groups.enumerated() {
                guard case .object = group else { continue }
                let groupName = nonEmptyWireString(group.stringAt("displayName", "display_name", "name"))
                guard let bucketsValue = group.lookup("buckets"), bucketsValue != .null else { continue }
                guard let buckets = bucketsValue.arrayItems else { throw CPAError(.invalidResponse) }
                for (bucketIndex, bucket) in buckets.enumerated() {
                    guard case .object = bucket else { continue }
                    let remaining = bucket.numberAt("remainingFraction", "remaining_fraction")
                    let resetAt = bucket.dateAt("resetTime", "reset_time", "resetAt", "reset_at")
                    let windowName = nonEmptyWireString(bucket.stringAt("window", "windowName", "window_name"))
                    let description = nonEmptyWireString(bucket.stringAt("description"))
                    let title = description ?? windowName ?? groupName ?? "Quota bucket"
                    let slug = wireSlug([groupName, windowName].compactMap { $0 }.joined(separator: "-"))
                    let identifier = slug.isEmpty
                        ? "group-\(groupIndex + 1)-bucket-\(bucketIndex + 1)"
                        : "group-\(groupIndex + 1)-\(slug)-\(bucketIndex + 1)"
                    windows.append(QuotaWindow(
                        id: identifier,
                        title: title,
                        usedFraction: remaining.map { 1 - $0 },
                        resetAt: resetAt
                    ))
                }
            }
        }

        guard recognized else { throw CPAError(.invalidResponse) }
        // The plugin contract does not establish a sign for serverTimeOffsetMs, so times stay as provided.
        return QuotaSnapshot(
            accountID: account.id,
            provider: account.provider,
            source: .live,
            fetchedAt: now,
            observedAt: nil,
            plan: plan,
            windows: windows,
            metrics: metrics,
            credits: nil
        )
    }

    static func xai(_ data: Data, account: CPAAccount, now: Date) throws -> QuotaSnapshot {
        let root = try WireJSON.decode(data)
        guard case .object = root else { throw CPAError(.invalidResponse) }
        guard let config = root.objectAt("config") else { throw CPAError(.invalidResponse) }

        let monthlyLimit = config.numberAt("monthlyLimit", "monthly_limit")
        let used = config.numberAt("used", "usedAmount", "used_amount")
        let onDemandCap = config.numberAt("onDemandCap", "on_demand_cap")
        guard monthlyLimit != nil || used != nil || onDemandCap != nil else {
            throw CPAError(.invalidResponse)
        }

        let periodEnd = config.dateAt("billingPeriodEnd", "billing_period_end")
            ?? root.dateAt("billingPeriodEnd", "billing_period_end")

        var windows: [QuotaWindow] = []
        if let monthlyLimit, monthlyLimit > 0, let used {
            windows.append(QuotaWindow(
                id: "monthly",
                title: "Monthly limit",
                usedFraction: used / monthlyLimit,
                resetAt: periodEnd
            ))
        }

        // xAI billing amounts are USD cents, not dollars.
        var metrics: [QuotaMetric] = []
        func appendCurrencyMetric(id: String, label: String, cents: Double?) {
            guard let cents, cents.isFinite else { return }
            metrics.append(QuotaMetric(id: id, label: label, value: cents / 100,
                                       format: "currency", currency: "USD"))
        }
        appendCurrencyMetric(id: "monthly-limit", label: "Monthly limit", cents: monthlyLimit)
        appendCurrencyMetric(id: "used", label: "Used", cents: used)
        appendCurrencyMetric(id: "on-demand-cap", label: "On-demand cap", cents: onDemandCap)

        return QuotaSnapshot(
            accountID: account.id,
            provider: account.provider,
            source: .live,
            fetchedAt: now,
            observedAt: nil,
            plan: nil,
            windows: windows,
            metrics: metrics,
            credits: nil
        )
    }
}

enum PassiveQuotaParser {
    static func snapshot(from entry: WireJSON, account: CPAAccount, fetchedAt: Date) -> QuotaSnapshot? {
        guard account.provider.lowercased() == "codex" else { return nil }

        if let quota = entry.objectAt("quota"),
           let observedAt = quota.dateAt("observed_at", "observedAt"),
           let snapshot = CodexSignals.snapshot(from: quota, account: account,
                                                observedAt: observedAt, fetchedAt: fetchedAt) {
            return snapshot
        }

        guard let models = entry.objectAt("model_quotas", "modelQuotas")?.objectEntries else {
            return nil
        }
        var best: (observedAt: Date, snapshot: QuotaSnapshot)?
        for key in models.keys.sorted() {
            guard let model = models[key], case .object = model,
                  let observedAt = model.dateAt("observed_at", "observedAt"),
                  let snapshot = CodexSignals.snapshot(from: model, account: account,
                                                       observedAt: observedAt, fetchedAt: fetchedAt) else {
                continue
            }
            if let current = best, observedAt <= current.observedAt { continue }
            best = (observedAt, snapshot)
        }
        return best?.snapshot
    }
}

enum CodexSignals {
    static func snapshot(from container: WireJSON, account: CPAAccount,
                         observedAt: Date, fetchedAt: Date) -> QuotaSnapshot? {
        guard let rawSignals = container.objectAt("signals")?.objectEntries else { return nil }
        var signals: [String: String] = [:]
        for (key, value) in rawSignals {
            guard let text = WireJSON.scalarString(value) else { continue }
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            signals[normalizedKey] = text
        }
        guard !signals.isEmpty else { return nil }

        var windows: [QuotaWindow] = []
        for identifier in ["primary", "secondary"] {
            if let window = window(id: identifier, signals: signals, observedAt: observedAt) {
                windows.append(window)
            }
        }
        let creditInfo = credits(from: signals)
        guard !windows.isEmpty || creditInfo != nil else { return nil }

        return QuotaSnapshot(
            accountID: account.id,
            provider: account.provider,
            source: .passive,
            fetchedAt: fetchedAt,
            observedAt: observedAt,
            plan: nonEmptyWireString(signals["x-codex-plan-type"]) ?? account.plan,
            windows: windows,
            metrics: [],
            credits: creditInfo
        )
    }

    private static func window(id: String, signals: [String: String],
                               observedAt: Date) -> QuotaWindow? {
        let base = "x-codex-\(id)-"
        let usedPercent = numeric(signals[base + "used-percent"])
        let windowMinutes = numeric(signals[base + "window-minutes"])
        let resetSeconds = numeric(signals[base + "reset-at"])
        let resetAfter = numeric(signals[base + "reset-after-seconds"])
        guard usedPercent != nil || windowMinutes != nil
                || resetSeconds != nil || resetAfter != nil else {
            return nil
        }

        let duration = windowMinutes.map { $0 * 60 }
        let resetAt: Date?
        if let resetSeconds {
            resetAt = WireDate.epochDate(resetSeconds)
        } else if let resetAfter {
            resetAt = WireDate.date(byAdding: resetAfter, to: observedAt)
        } else {
            resetAt = nil
        }

        return QuotaWindow(
            id: id,
            title: codexWindowTitle(duration),
            durationSeconds: duration,
            usedFraction: usedPercent.map { $0 / 100 },
            resetAt: resetAt
        )
    }

    private static func credits(from signals: [String: String]) -> QuotaCredits? {
        let hasCredits = boolean(signals["x-codex-credits-has-credits"])
        let unlimited = boolean(signals["x-codex-credits-unlimited"])
        guard hasCredits != nil || unlimited != nil else { return nil }
        return QuotaCredits(hasCredits: hasCredits, unlimited: unlimited, balance: nil)
    }

    private static func numeric(_ text: String?) -> Double? {
        guard let text,
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else { return nil }
        return value
    }

    private static func boolean(_ text: String?) -> Bool? {
        guard let text else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}

private func codexRateLimitWindows(_ limit: WireJSON, idPrefix: String,
                                   titlePrefix: String?, now: Date) -> [QuotaWindow] {
    let allowed = limit.boolAt("allowed")
    let limitReached = limit.boolAt("limit_reached", "limitReached")
    let specs: [(snake: String, camel: String, id: String)] = [
        ("primary_window", "primaryWindow", "primary"),
        ("secondary_window", "secondaryWindow", "secondary")
    ]
    var windows: [QuotaWindow] = []
    for spec in specs {
        guard let window = limit.objectAt(spec.snake, spec.camel) else { continue }
        let duration = window.numberAt("limit_window_seconds", "limitWindowSeconds")
        let usedFraction = window.numberAt("used_percent", "usedPercent").map { $0 / 100 }
        let resetAt = window.dateAt("reset_at", "resetAt")
            ?? window.numberAt("reset_after_seconds", "resetAfterSeconds")
                .flatMap { WireDate.date(byAdding: $0, to: now) }
        let title = codexWindowTitle(duration)
        windows.append(QuotaWindow(
            id: idPrefix.isEmpty ? spec.id : "\(idPrefix)-\(spec.id)",
            title: titlePrefix.map { "\($0) · \(title)" } ?? title,
            durationSeconds: duration,
            usedFraction: usedFraction,
            resetAt: resetAt,
            allowed: allowed,
            limitReached: limitReached
        ))
    }
    return windows
}

private func codexAdditionalWindows(_ items: [WireJSON], now: Date) -> [QuotaWindow] {
    var windows: [QuotaWindow] = []
    for (index, item) in items.enumerated() {
        guard case .object = item,
              let rateLimit = item.objectAt("rate_limit", "rateLimit") else { continue }
        let label = nonEmptyWireString(item.stringAt("limit_name", "limitName",
                                                     "metered_feature", "meteredFeature"))
            ?? "Additional \(index + 1)"
        let slug = wireSlug(label)
        let prefix = slug.isEmpty ? "additional-\(index + 1)" : "\(slug)-\(index + 1)"
        windows += codexRateLimitWindows(rateLimit, idPrefix: prefix, titlePrefix: label, now: now)
    }
    return windows
}

private func codexCredits(_ value: WireJSON?) -> QuotaCredits? {
    guard let value, case .object = value else { return nil }
    let hasCredits = value.boolAt("has_credits", "hasCredits")
    let unlimited = value.boolAt("unlimited")
    let balance = value.numberAt("balance")
    guard hasCredits != nil || unlimited != nil || balance != nil else { return nil }
    return QuotaCredits(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
}

func codexWindowTitle(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "Quota window" }
    if seconds == 18_000 { return "5-hour limit" }
    if seconds == 604_800 { return "7-day limit" }
    if seconds >= 2_419_200 && seconds <= 2_678_400 { return "Monthly limit" }
    let day: TimeInterval = 86_400
    let hour: TimeInterval = 3_600
    let minute: TimeInterval = 60
    if seconds.truncatingRemainder(dividingBy: day) == 0,
       let days = boundedInteger(seconds / day) {
        return "\(days)-day limit"
    }
    if seconds.truncatingRemainder(dividingBy: hour) == 0,
       let hours = boundedInteger(seconds / hour) {
        return "\(hours)-hour limit"
    }
    if seconds.truncatingRemainder(dividingBy: minute) == 0,
       let minutes = boundedInteger(seconds / minute) {
        return "\(minutes)-minute limit"
    }
    if let wholeSeconds = boundedInteger(seconds) {
        return "\(wholeSeconds)-second limit"
    }
    return "Quota window"
}

private func boundedInteger(_ value: Double) -> Int? {
    guard value.isFinite else { return nil }
    return Int(exactly: value.rounded(.towardZero))
}

func wireSlug(_ text: String) -> String {
    var result = ""
    var pendingDash = false
    for scalar in text.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            if pendingDash && !result.isEmpty { result.append("-") }
            pendingDash = false
            result.unicodeScalars.append(scalar)
        } else {
            pendingDash = true
        }
    }
    return result
}

private func uniqueWireIdentifier(_ base: String, used: inout Set<String>,
                                  startingAt suffix: Int) -> String {
    var candidate = base
    var nextSuffix = suffix
    while used.contains(candidate) {
        candidate = "\(base)-\(nextSuffix)"
        nextSuffix += 1
    }
    used.insert(candidate)
    return candidate
}
