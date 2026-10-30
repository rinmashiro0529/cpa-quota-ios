#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

/// A value row that keeps the full unit, timestamp, or identifier available.
/// Large accessibility text and long values use a vertical arrangement.
public struct QuotaLabeledValue: View {
    public let title: String
    public let value: String
    public let monospaced: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    public init(title: String, value: String, monospaced: Bool = true) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        titleText.fixedSize()
                        Spacer(minLength: 12)
                        valueText.fixedSize()
                    }
                    stacked
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText
            valueText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(BrandPalette(colorScheme: colorScheme).textSecondary)
    }

    private var valueText: some View {
        Text(value)
            .font(monospaced ? QuotaTypography.dataDetail : .body)
            .foregroundStyle(BrandPalette(colorScheme: colorScheme).textPrimary)
            .monospacedDigit()
    }
}

/// Severity is conveyed by a symbol and words, as well as the preserved colors.
public struct QuotaErrorNotice: View {
    public let presentation: ErrorPresentation
    public let showsRecoveryAdvice: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(presentation: ErrorPresentation, showsRecoveryAdvice: Bool = true) {
        self.presentation = presentation
        self.showsRecoveryAdvice = showsRecoveryAdvice
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(presentation.title)
                    .foregroundStyle(palette.textPrimary)
            } icon: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(tint(palette))
            }
            .font(.headline)
            Text(presentation.summary)
                .font(.body)
                .foregroundStyle(palette.textSecondary)
            if showsRecoveryAdvice {
                Text(presentation.recoveryAdvice)
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func tint(_ palette: BrandPalette) -> Color {
        switch presentation.severity {
        case .neutral: palette.textSecondary
        case .warning: palette.statusWarn
        case .critical: palette.statusError
        }
    }
}

public struct QuotaFreshnessLabel: View {
    public let snapshot: QuotaSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    public init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        Group {
            if scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    label(at: context.date)
                }
            } else {
                label(at: .now)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(at date: Date) -> some View {
        let badge = QuotaFormatter.freshnessBadge(for: snapshot, now: date)
        let palette = BrandPalette(colorScheme: colorScheme)
        return Label {
            Text(badge.badgeText).foregroundStyle(palette.textSecondary)
        } icon: {
            Image(systemName: badge.isStale ? "clock.badge.exclamationmark" : "clock")
                .foregroundStyle(badge.isStale ? palette.statusWarn : palette.statusOK)
        }
    }
}

/// Uses a native determinate progress view only when a percentage is known.
/// Zero stays zero, and over-quota values remain visible in the text.
public struct QuotaWindowView: View {
    public let window: WindowPresentation
    public let displayMode: QuotaDisplayMode
    @Environment(\.colorScheme) private var colorScheme

    public init(window: WindowPresentation, displayMode: QuotaDisplayMode) {
        self.window = window
        self.displayMode = displayMode
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            Text(window.title)
                .font(.headline)
                .foregroundStyle(palette.textPrimary)
            Text(window.durationText)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Text(window.primaryPercentageText(for: displayMode))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
            if let fraction = window.progressBarFraction(for: displayMode) {
                ProgressView(value: fraction, total: 1)
                    .tint(progressTint(palette))
                    .accessibilityHidden(true)
            }
            if window.isOverQuota {
                Label("已达额度限制", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            } else if window.isLowRemainingWarning {
                Label("剩余额度偏低", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            }
            Text(window.secondaryComparisonText)
                .font(QuotaTypography.dataDetail)
                .foregroundStyle(palette.textSecondary)
            Text(window.resetTimeText())
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func progressTint(_ palette: BrandPalette) -> Color {
        if window.isOverQuota { return palette.statusError }
        if window.isLowRemainingWarning { return palette.statusWarn }
        return palette.accent
    }
}
#endif
