#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct AccountsDiagnosticsTabView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    private var visibleAccounts: [CPAAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return session.accounts }
        return session.accounts.filter { account in
            let presentation = AccountDiagnosticPresentation(
                account: account, error: session.records[account.id]?.error, maskEmail: session.maskEmail
            )
            return [presentation.displayName, presentation.email, account.provider, account.authIndex ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    public var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        List {
            Section {
                connectionHealth
                DisclosureGroup("额度读取能力") {
                    Text("支持 Codex、xAI 及服务端发现的标准化额度插件。部分平台可能暂无法查询。")
                        .font(.body)
                        .foregroundStyle(palette.textSecondary)
                }
            } header: {
                Text("服务健康").font(QuotaTypography.brandHeadline)
            }
            .listRowBackground(palette.contentSurface)

            if let error = session.store?.error {
                Section("连接错误") {
                    QuotaErrorNotice(presentation: ErrorPresentation(error: error, records: session.records))
                }
                .listRowBackground(palette.contentSurface)
            }
            if let warning = session.store?.capabilityWarning {
                Section("可选能力告警") {
                    QuotaErrorNotice(presentation: ErrorPresentation(error: warning))
                }
                .listRowBackground(palette.contentSurface)
            }

            if session.accounts.isEmpty {
                Section {
                    if session.isBusy {
                        ProgressView("正在读取授权账号")
                    } else if session.store?.error != nil {
                        ContentUnavailableView {
                            Label("账号尚未读取成功", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("请先处理连接错误，当前结果不能用于判断账号数量。")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("暂无授权账号", systemImage: "person.2")
                        } description: {
                            Text("服务中新增授权账号后，可刷新查看其状态和读取能力。")
                        }
                    }
                }
                .listRowBackground(palette.contentSurface)
            } else if visibleAccounts.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(palette.contentSurface)
            } else {
                ForEach(visibleAccounts) { account in
                    Section {
                        accountRow(account)
                        DisclosureGroup("读取与服务详情") {
                            let presentation = AccountDiagnosticPresentation(
                                account: account, error: session.records[account.id]?.error, maskEmail: session.maskEmail
                            )
                            QuotaLabeledValue(title: "账号索引", value: account.authIndex ?? "未知")
                            QuotaLabeledValue(title: "服务报告状态", value: account.status, monospaced: false)
                            Text(presentation.readerDescription)
                                .font(.subheadline)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    .listRowBackground(palette.contentSurface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("账号诊断")
        .searchable(text: $searchText, prompt: "名称、平台或账号索引")
        .refreshable { await session.refreshAll(force: true) }
    }

    @ViewBuilder
    private var connectionHealth: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        if session.store?.error != nil {
            Label("账号读取未完成", systemImage: "exclamationmark.triangle")
                .foregroundStyle(palette.textPrimary)
        } else if session.store == nil || session.isBusy {
            ProgressView("正在检查读取通道")
        } else if session.store?.capabilityWarning != nil {
            Label("已读取账号，可选能力有告警", systemImage: "exclamationmark.circle")
                .foregroundStyle(palette.textPrimary)
        } else {
            Label("账号读取正常", systemImage: "checkmark.seal")
                .foregroundStyle(palette.textPrimary)
        }
    }

    private func accountRow(_ account: CPAAccount) -> some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        let presentation = AccountDiagnosticPresentation(
            account: account, error: session.records[account.id]?.error, maskEmail: session.maskEmail
        )
        return Button {
            session.selectedAccountIDForDetail = account.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.displayName)
                        .font(QuotaTypography.brandHeadline)
                        .foregroundStyle(palette.textPrimary)
                    Text(presentation.email)
                        .font(QuotaTypography.dataDetail)
                        .foregroundStyle(palette.textSecondary)
                    Text(account.provider.uppercased())
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                    Label(presentation.accountStatus, systemImage: presentation.statusSymbol)
                        .font(.subheadline)
                        .foregroundStyle(palette.textPrimary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看此账号的配额详情")
        .privacySensitive()
    }
}
#endif
