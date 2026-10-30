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
        let palette = BrandPalette(colorScheme: colorScheme)
        let record = session.records[account.id]
        let snapshot = record?.snapshot
        let diagnostic = AccountDiagnosticPresentation(
            account: account, error: record?.error, maskEmail: session.maskEmail
        )
        Form {
            Section {
                Text(diagnostic.displayName)
                    .font(QuotaTypography.brandTitle)
                    .foregroundStyle(palette.textPrimary)
                    .privacySensitive()
                    .accessibilityAddTraits(.isHeader)
                QuotaLabeledValue(title: "邮箱", value: diagnostic.email)
                    .privacySensitive()
                QuotaLabeledValue(title: "平台", value: account.provider.uppercased())
                QuotaLabeledValue(title: "套餐", value: snapshot?.plan ?? account.plan ?? "未知", monospaced: false)
                Label(diagnostic.accountStatus, systemImage: diagnostic.statusSymbol)
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            }
            .listRowBackground(palette.contentSurface)

            if let snapshot {
                Section("数据时效") {
                    QuotaFreshnessLabel(snapshot: snapshot)
                    if record?.error != nil {
                        Label("保留上次成功快照，非本次刷新结果", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                    }
                    QuotaLabeledValue(
                        title: "数据来源",
                        value: snapshot.source == .live ? "主动查询" : "被动观察",
                        monospaced: false
                    )
                    QuotaLabeledValue(title: "本机获取时间", value: QuotaFormatter.exactTimestampString(snapshot.fetchedAt))
                    QuotaLabeledValue(title: "上游观察时间", value: QuotaFormatter.exactTimestampString(snapshot.observedAt))
                }
                .listRowBackground(palette.contentSurface)

                if !snapshot.windows.isEmpty {
                    Section {
                        ForEach(snapshot.windows) { window in
                            QuotaWindowView(window: WindowPresentation(window: window), displayMode: session.displayMode)
                                .padding(.vertical, 8)
                        }
                    } header: {
                        Text("额度窗口")
                    } footer: {
                        Text(WindowPresentation.resetDisclaimer)
                    }
                    .listRowBackground(palette.contentSurface)
                }
                if !snapshot.metrics.isEmpty {
                    Section {
                        ForEach(snapshot.metrics.map(MetricPresentation.init)) { metric in
                            QuotaLabeledValue(title: metric.label, value: metric.formattedValue)
                        }
                    } header: {
                        Text("上游摘要指标")
                    } footer: {
                        Text("保留上游返回的单位，不将摘要指标转换成不存在的配额百分比。")
                    }
                    .listRowBackground(palette.contentSurface)
                }
                if let credits = CreditsPresentation(credits: snapshot.credits) {
                    Section {
                        QuotaLabeledValue(title: credits.title, value: credits.valueText)
                    } header: {
                        Text("附加 Credits")
                    } footer: {
                        Text(credits.footnote)
                    }
                    .listRowBackground(palette.contentSurface)
                }
                if snapshot.windows.isEmpty && snapshot.metrics.isEmpty && snapshot.credits == nil {
                    Section {
                        ContentUnavailableView {
                            Label("上游未提供额度数值", systemImage: "chart.bar")
                        } description: {
                            Text("账号已成功响应，但尚无可识别的额度窗口或摘要指标。")
                        }
                    }
                    .listRowBackground(palette.contentSurface)
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label(account.isDisabled ? "账号已停用" : "暂无成功快照", systemImage: "clock")
                    } description: {
                        Text(account.isDisabled ? "停用账号不发起额度查询。" : "查询成功后会在此显示窗口、摘要指标与数据时效。")
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            if let error = record?.error {
                Section("本次查询状态") {
                    let presentation = ErrorPresentation(error: error, hasPreservedSnapshot: snapshot != nil)
                    QuotaErrorNotice(presentation: presentation)
                    if presentation.isManagementBlocking {
                        Button {
                            session.selectedAccountIDForDetail = nil
                            session.activeTab = .connection
                        } label: {
                            Label("前往连接设置", systemImage: "key")
                                .frame(minHeight: 44)
                        }
                        .quotaPrimaryButtonStyle()
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                DisclosureGroup("读取与服务详情") {
                    QuotaLabeledValue(title: "账号索引", value: account.authIndex ?? "未知")
                    QuotaLabeledValue(title: "服务报告状态", value: account.status, monospaced: false)
                    Text(diagnostic.readerDescription)
                        .font(.subheadline)
                        .foregroundStyle(palette.textSecondary)
                    if let error = record?.error {
                        QuotaLabeledValue(title: "错误类型", value: error.kind.rawValue)
                    }
                }
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("账号详情")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { session.selectedAccountIDForDetail = nil }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.refreshAccount(account.id, force: true) }
                } label: {
                    Label("刷新此账号", systemImage: "arrow.clockwise")
                }
                .disabled(account.isDisabled || session.isBusy)
                .accessibilityIdentifier("quota.account.refresh")
            }
        }
    }
}
#endif
