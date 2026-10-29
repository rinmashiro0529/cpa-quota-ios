#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct AccountDetailSheetView: View {
    @Bindable var session: CPAQuotaSession
    public let account: CPAAccount
    @Environment(\.colorScheme) private var colorScheme

    public init(session: CPAQuotaSession, account: CPAAccount) {
        self.session = session
        self.account = account
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let record = session.records[account.id]
        let snapshot = record?.snapshot
        let error = record?.error

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(palette: palette)

                metadataGrid(snapshot: snapshot, palette: palette)

                if let snapshot {
                    if !snapshot.windows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("额度窗口明细 (独立周期，不可相加)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.textSecondary)

                            ForEach(snapshot.windows) { window in
                                let pres = WindowPresentation(window: window)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(pres.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(palette.textPrimary)
                                        Spacer()
                                        Text(pres.durationText)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(palette.textSecondary)
                                    }

                                    Text(pres.secondaryComparisonText)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.accent)

                                    Text(pres.resetTimeText())
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(palette.textSecondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .liquidGlassPill(cornerRadius: 16)
                            }
                        }
                    }

                    if !snapshot.metrics.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("上游摘要指标 (按返回原单位展示)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.textSecondary)

                            ForEach(snapshot.metrics.map(MetricPresentation.init)) { metric in
                                HStack {
                                    Text(metric.label)
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.textSecondary)
                                    Spacer()
                                    Text(metric.formattedValue)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.textPrimary)
                                }
                                .padding(12)
                                .liquidGlassPill(cornerRadius: 14)
                            }
                        }
                    }

                    if let creditsPres = CreditsPresentation(credits: snapshot.credits) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(creditsPres.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Text(creditsPres.valueText)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(palette.accent)
                            }
                            Text(creditsPres.footnote)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textMuted)
                        }
                        .padding(12)
                        .liquidGlassPill(cornerRadius: 16)
                    }
                }

                if let error {
                    let pres = ErrorPresentation(error: error, hasPreservedSnapshot: snapshot != nil)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: pres.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(pres.title) (\(error.kind.rawValue))")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(palette.statusError)

                        Text(pres.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)

                        Text(pres.recoveryAdvice)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textMuted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassCard(cornerRadius: 20)
                }

                Text(WindowPresentation.resetDisclaimer)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)

                HStack(spacing: 10) {
                    if !account.isDisabled {
                        Button {
                            Task {
                                await session.refreshAccount(account.id, force: true)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("立即同步最新额度")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(palette.accent)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        session.selectedAccountIDForDetail = nil
                    } label: {
                        Text("收起详情")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .liquidGlassPill(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(AmbientGlassCanvasBackground())
    }

    @ViewBuilder
    private func headerSection(palette: LiquidGlassPalette) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.provider.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.accentSoft)
                        )

                    Text("auth_index: \(account.authIndex ?? "nil")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                }

                Text(QuotaFormatter.maskEmail(account.displayName, enabled: session.maskEmail))
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.textPrimary)

                Text(QuotaFormatter.maskEmail(account.email, enabled: session.maskEmail))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()

            Button {
                session.selectedAccountIDForDetail = nil
            } label: {
                Text("关闭")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassPill(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func metadataGrid(snapshot: QuotaSnapshot?, palette: LiquidGlassPalette) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            metadataCell(
                title: "套餐声明 (plan)",
                value: snapshot?.plan ?? account.plan ?? "未知",
                palette: palette
            )
            metadataCell(
                title: "数据来源 (source)",
                value: snapshot.map { $0.source == .live ? ".live (主动查询)" : ".passive (被动观察)" } ?? "无快照",
                palette: palette
            )
            metadataCell(
                title: "本机获取 (fetchedAt)",
                value: QuotaFormatter.exactTimestampString(snapshot?.fetchedAt),
                palette: palette
            )
            metadataCell(
                title: "上游观察 (observedAt)",
                value: QuotaFormatter.exactTimestampString(snapshot?.observedAt),
                palette: palette
            )
        }
    }

    @ViewBuilder
    private func metadataCell(title: String, value: String, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassPill(cornerRadius: 14)
    }
}
#endif
