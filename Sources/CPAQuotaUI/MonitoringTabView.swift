#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit
import CPAQuotaActivity
#if os(iOS)
import UIKit
#endif

public struct MonitoringTabView: View {
    @Bindable public var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingForget = false

    public init(session: CPAQuotaSession) { self.session = session }

    private var monitor: MonitoringWorkspaceCoordinator { session.monitoringCoordinator }
    private var palette: BrandPalette { BrandPalette(colorScheme: colorScheme) }
    private var hasUnfinishedSession: Bool {
        if monitor.pendingCreateUUID != nil { return true }
        guard let store = monitor.store, store.sessionID != nil else { return false }
        return store.cancellationReceipt == nil && (store.session?.status ?? .active) == .active
    }

    public var body: some View {
        @Bindable var monitor = session.monitoringCoordinator
        Form {
            Section {
                Text("在需要连续关注配额变化时开启监控。到期自动结束，日常查看可使用额度页或小组件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let message = userFacingMessage {
                    Label(message, systemImage: monitor.bridgeFormError == nil ? "info.circle" : "exclamationmark.triangle")
                        .font(.subheadline)
                        .accessibilityIdentifier("monitoring.notice")
                }
            }
            .listRowBackground(palette.contentSurface)

            Section("监控服务") {
                switch monitor.bridgeState {
                case .unconfigured:
                    Label("尚未连接监控服务", systemImage: "network.slash")
                        .accessibilityIdentifier("monitoring.unconfigured")
                    NavigationLink {
                        MonitoringConnectionEditor(monitor: monitor)
                    } label: {
                        Label("连接监控服务", systemImage: "link")
                    }
                case .connected(let address, let saved):
                    LabeledContent("服务", value: address.host ?? "已配置")
                    LabeledContent("连接保存", value: saved ? "已安全保存" : "仅本次使用")
                    NavigationLink("更改服务连接") {
                        MonitoringConnectionEditor(monitor: monitor)
                    }
                    Button("断开与忘记连接", role: .destructive) { isConfirmingForget = true }
                }
            }
            .listRowBackground(palette.contentSurface)

            Section {
                TextField("监控服务提供的来源标识", text: $monitor.sourceIDDraft)
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled()
                    .accessibilityLabel("授权来源")
                    .accessibilityIdentifier("monitor.source")
                NavigationLink {
                    MonitoringAccountSelectionView(session: session)
                } label: {
                    LabeledContent("监控账号", value: "\(monitor.selectedAccountIDsDraft.count) / 5")
                }
                Picker("持续时间", selection: $monitor.durationDraft) {
                    Text("1 小时").tag(MonitoringDuration.oneHour)
                    Text("4 小时").tag(MonitoringDuration.fourHours)
                    Text("8 小时").tag(MonitoringDuration.eightHours)
                }
                .pickerStyle(.menu)
            } header: {
                Text("监控范围")
            } footer: {
                Text(hasUnfinishedSession
                     ? "本次范围已固定。结束当前监控后，可以选择新的范围。"
                     : "请使用监控服务授权的来源与账号。可显示的指标和窗口由服务配置决定。")
            }
            .disabled(monitor.isBusy || hasUnfinishedSession)
            .listRowBackground(palette.contentSurface)

            Section {
                LabeledContent("本机实时活动",
                               value: monitor.localActivityID == nil ? "未显示" : "已建立系统活动")
                if !monitor.isSystemActivitySupported {
                    Label("当前平台可在应用内查看监控；系统实时活动需要支持的 iPhone 或 iPad。", systemImage: "info.circle")
                        .font(.subheadline)
                } else if !monitor.activitiesEnabled {
                    Label("实时活动尚未允许，可在系统设置中开启。", systemImage: "hand.raised")
                        .font(.subheadline)
                    #if os(iOS)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    #endif
                }

                if monitor.isWaitingForPushToken {
                    ProgressView("正在准备系统实时活动")
                        .accessibilityIdentifier("monitoring.waitingForToken")
                }
                if monitor.isSessionActionInProgress || monitor.isChangingBridge {
                    ProgressView("正在处理")
                }

                if !hasUnfinishedSession {
                    Button {
                        Task { await monitor.startOrReconcileMonitoringSession() }
                    } label: {
                        Label("开始监控", systemImage: "play.fill")
                    }
                    .quotaPrimaryButtonStyle()
                    .disabled(monitor.isBusy || monitor.bridgeState == .unconfigured
                              || !monitor.isSystemActivitySupported || !monitor.activitiesEnabled
                              || monitor.selectedAccountIDsDraft.isEmpty
                              || monitor.sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("monitor.start")
                } else {
                    if !monitor.isWaitingForPushToken {
                        Button {
                            Task { await monitor.reconcileCurrentSession() }
                        } label: {
                            Label("核对监控状态", systemImage: "arrow.clockwise")
                        }
                        .disabled(monitor.isBusy)
                        if monitor.store?.session?.status == .active {
                            Button {
                                Task { await monitor.refreshActiveMonitoringSession() }
                            } label: {
                                Label("请求更新读数", systemImage: "arrow.down.circle")
                            }
                            .disabled(monitor.isBusy)
                        }
                    }
                    Button(monitor.isWaitingForPushToken ? "取消本次启动" : "停止监控", role: .destructive) {
                        Task { await monitor.stopActiveMonitoringSession() }
                    }
                    .disabled(monitor.isChangingBridge)
                    .accessibilityIdentifier("monitor.stopRemote")
                }
                if monitor.localActivityID != nil {
                    Button("仅停止本机实时活动显示", role: .destructive) {
                        Task { await monitor.stopLocalActivityDisplay() }
                    }
                    .disabled(monitor.isEndingLocalActivity)
                    .accessibilityIdentifier("monitor.stopLocal")
                }
            } header: {
                Text("实时活动")
            } footer: {
                Text("系统决定锁屏与灵动岛的呈现。停止本机显示不会取消远端监控；停止监控需要服务确认。")
            }
            .listRowBackground(palette.contentSurface)

            if let active = monitor.store?.session {
                Section("当前监控") {
                    LabeledContent("状态", value: sessionStatus(active))
                    LabeledContent("来源", value: active.sourceID)
                    LabeledContent("账号", value: "\(active.accountIDs.count) 个")
                    LabeledContent("结束时间") {
                        Text(Date(timeIntervalSince1970: active.expiresAt), format: .dateTime.month().day().hour().minute())
                    }
                    if let snapshot = monitor.localActivitySnapshot ?? active.snapshot {
                        MonitoringSnapshotRows(snapshot: snapshot)
                    } else {
                        Label("等待首次采集", systemImage: "clock")
                        Text("监控服务已建立会话。首次读数可能需要几分钟，也可以主动请求更新。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            if !monitor.unassociatedActivities.isEmpty {
                Section {
                    Label("发现未关联的本机实时活动", systemImage: "exclamationmark.circle")
                    Text("可在诊断中确认并关闭。应用不会推测它属于哪个监控服务。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                NavigationLink {
                    MonitoringDiagnosticsView(session: session)
                } label: {
                    Label("监控诊断与恢复记录", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("monitor.diagnostics")
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .tint(palette.actionTint)
        .navigationTitle("监控")
        .confirmationDialog("忘记监控服务连接？", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("先停止监控，再忘记连接", role: .destructive) {
                Task { await monitor.stopAndForgetBridge() }
            }
            Button("仅忘记本机连接", role: .destructive) {
                Task { await monitor.forgetBridgeLocallyOnly() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅忘记连接不会取消远端监控或移除现有系统活动。恢复记录会保留，远端监控按原定时限结束。")
        }
        // App bootstrap and scene activation own restoration. Entering this
        // tab never creates or restores a second session as a view side effect.
    }

    private var userFacingMessage: String? {
        if let error = monitor.store?.error { return monitoringErrorSummary(error) }
        if monitor.bridgeFormError != nil {
            return "未能完成操作。请检查监控设置，或在诊断中查看原因与恢复操作。"
        }
        if monitor.store?.cancellationReceipt != nil { return "监控服务已记录停止请求。本机与远端状态可分别在诊断中查看。" }
        if monitor.bridgeStatusNotice != nil {
            if monitor.isWaitingForPushToken { return "正在等待系统准备完成，无需重复开始。" }
            if monitor.store?.state == .uncertain { return "当前状态尚未确认，请核对原监控会话。" }
            return "操作结果已更新，详细状态可在监控诊断中查看。"
        }
        return nil
    }

    private func sessionStatus(_ value: MonitoringSession) -> String {
        if monitor.store?.cancellationReceipt != nil { return "停止请求已确认" }
        if monitor.store?.state == .uncertain { return "等待确认" }
        switch value.status {
        case .active: return "正在监控"
        case .stopped: return "已停止"
        case .expired: return "已到期"
        }
    }
}

private struct MonitoringConnectionEditor: View {
    @Bindable var monitor: MonitoringWorkspaceCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, token }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            Section {
                TextField("https://monitor.example.com", text: $monitor.bridgeURLDraft)
                    .monitoringURLKeyboard()
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .token }
                    .accessibilityLabel("监控服务地址")
                    .accessibilityIdentifier("monitor.bridgeAddress")
                SecureField("独立监控访问令牌", text: $monitor.bridgeTokenDraft)
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .token)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .accessibilityIdentifier("monitor.bridgeToken")
                Toggle("记住监控服务连接", isOn: $monitor.rememberBridgeDraft)
            } header: {
                Text("服务连接")
            } footer: {
                Text("使用部署方提供的 HTTPS 地址和独立监控令牌。此令牌与 CPA 管理密钥不同；地址中的服务路径会保留。")
            }
            .listRowBackground(palette.contentSurface)

            if let error = monitor.bridgeFormError {
                Section {
                    MonitoringOperationError(message: error)
                        .accessibilityIdentifier("monitor.connectionError")
                }
                .listRowBackground(palette.contentSurface)
            }
            if case .connected(let address, let saved) = monitor.bridgeState {
                Section("当前连接") {
                    Text(address.absoluteString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Label(saved ? "已保存到本机安全存储" : "仅在本次使用期间保留", systemImage: "lock")
                        .font(.subheadline)
                    Text("连接配置就绪；服务授权会在读取或开启监控时校验。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(palette.contentSurface)
            }
            Section {
                Button(action: connect) {
                    if monitor.isChangingBridge { ProgressView("正在连接") }
                    else { Label("连接监控服务", systemImage: "link") }
                }
                .quotaPrimaryButtonStyle()
                .disabled(monitor.isChangingBridge || monitor.bridgeURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || monitor.bridgeTokenDraft.isEmpty)
                .accessibilityIdentifier("monitor.connect")
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .tint(palette.actionTint)
        .navigationTitle("监控服务")
    }

    private func connect() {
        guard !monitor.isChangingBridge, !monitor.bridgeTokenDraft.isEmpty else { return }
        focusedField = nil
        Task {
            await monitor.connectBridge(rawURLString: monitor.bridgeURLDraft,
                                        rawTokenString: monitor.bridgeTokenDraft,
                                        rememberInKeychain: monitor.rememberBridgeDraft)
        }
    }
}

private struct MonitoringAccountSelectionView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var monitor = session.monitoringCoordinator
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            if !session.accounts.isEmpty {
                Section {
                    ForEach(session.accounts) { account in
                        Toggle(isOn: Binding(
                            get: { monitor.selectedAccountIDsDraft.contains(account.id) },
                            set: { selected in
                                if selected { monitor.addAccountIDDraft(account.id) }
                                else { monitor.removeAccountIDDraft(account.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(QuotaFormatter.maskEmail(account.displayName, enabled: session.maskEmail))
                                Text(account.provider.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if account.isDisabled {
                                    Text("当前 CPA 连接中已禁用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!monitor.selectedAccountIDsDraft.contains(account.id)
                                  && (account.isDisabled || monitor.selectedAccountIDsDraft.count >= 5))
                    }
                } header: {
                    Text("当前 CPA 连接中的账号")
                } footer: {
                    Text("这些账号仅作为候选，是否可监控由独立服务授权决定。")
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                ForEach(monitor.selectedAccountIDsDraft, id: \.self) { id in
                    HStack(alignment: .firstTextBaseline) {
                        Text(QuotaFormatter.maskEmail(id, enabled: session.maskEmail))
                            .font(.body.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(role: .destructive) { monitor.removeAccountIDDraft(id) } label: {
                            Label("移除", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除 \(QuotaFormatter.maskEmail(id, enabled: session.maskEmail))")
                    }
                }
                if monitor.selectedAccountIDsDraft.isEmpty {
                    Text("尚未选择账号").foregroundStyle(.secondary)
                }
            } header: {
                Text("已选择 \(monitor.selectedAccountIDsDraft.count) / 5")
            }
            .listRowBackground(palette.contentSurface)

            Section {
                TextField("部署方提供的账号标识", text: $monitor.newAccountIDDraft)
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled()
                    .onSubmit { monitor.addAccountIDDraft(monitor.newAccountIDDraft) }
                    .accessibilityLabel("授权账号标识")
                Button("添加授权账号") { monitor.addAccountIDDraft(monitor.newAccountIDDraft) }
                    .disabled(monitor.newAccountIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || monitor.selectedAccountIDsDraft.count >= 5)
                if let error = monitor.bridgeFormError {
                    MonitoringOperationError(message: error)
                }
            } header: {
                Text("手动添加")
            } footer: {
                Text("保留原账号标识。不要将系统活动中的安全别名反推为真实账号，或以邮箱、昵称猜测服务授权。")
            }
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .tint(palette.actionTint)
        .navigationTitle("监控账号")
    }
}

private struct MonitoringSnapshotRows: View {
    let snapshot: MonitoringSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ForEach(snapshot.accounts, id: \.id) { account in
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.label).font(.headline)
                    Text("\(account.provider.uppercased()) · \(account.windowLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    QuotaLabeledValue(title: account.remainingFraction == nil ? "读数" : "剩余",
                                      value: CPAQuotaActivityPresentation.value(account))
                    Label(CPAQuotaActivityPresentation.status(snapshot: snapshot, account: account,
                                                               isStale: context.date >= snapshot.expiresAt),
                          systemImage: context.date >= snapshot.expiresAt ? "clock.badge.exclamationmark" : "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let observed = account.observedAt {
                        Text("观察于 \(observed, format: .dateTime.month().day().hour().minute())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("观察时间未知").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct MonitoringDiagnosticsView: View {
    @Bindable var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    private var monitor: MonitoringWorkspaceCoordinator { session.monitoringCoordinator }

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            if let error = monitor.bridgeFormError {
                Section("最近操作") { MonitoringOperationError(message: error) }
                    .listRowBackground(palette.contentSurface)
            }
            if let notice = monitor.bridgeStatusNotice {
                Section("状态说明") { MonitoringOperationStatus(message: notice) }
                    .listRowBackground(palette.contentSurface)
            }
            Section("本机系统活动") {
                LabeledContent("系统支持", value: monitor.isSystemActivitySupported ? "支持" : "当前平台不支持")
                LabeledContent("系统授权", value: monitor.activitiesEnabled ? "允许" : "未允许")
                if let id = monitor.localActivityID {
                    QuotaLabeledValue(title: "活动 ID", value: id)
                }
                Button("检查本机活动") { monitor.refreshLocalActivityInventory() }
                Text("结束本机显示不会停止服务端监控。推送服务接受与设备实际展示也是不同状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(palette.contentSurface)

            if !monitor.unassociatedActivities.isEmpty {
                Section {
                    ForEach(monitor.unassociatedActivities) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.sourceID).font(.headline)
                            QuotaLabeledValue(title: "活动 ID", value: activity.id)
                            Button("关闭此本机实时活动", role: .destructive) {
                                Task { await monitor.endUnassociatedActivity(activity) }
                            }
                        }
                    }
                } header: {
                    Text("未关联的本机活动")
                } footer: {
                    Text("可能来自启动期间的中断。只提供明确关闭，不猜测来源凭据，不创建替代会话。")
                }
                .listRowBackground(palette.contentSurface)
            }

            let otherLocalActivities = monitor.localActivities.filter {
                $0.id != monitor.localActivityID && !monitor.unassociatedActivities.contains($0)
            }
            if !otherLocalActivities.isEmpty {
                Section {
                    ForEach(otherLocalActivities) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.sourceID).font(.headline)
                            QuotaLabeledValue(title: "活动 ID", value: activity.id)
                            Button("仅关闭此本机显示", role: .destructive) {
                                Task { await monitor.endLocalActivity(activity) }
                            }
                        }
                    }
                } header: {
                    Text("其他已记录的本机活动")
                } footer: {
                    Text("即使已经忘记连接，也可关闭本机显示。停止远端监控仍需核对原服务。")
                }
                .listRowBackground(palette.contentSurface)
            }

            Section("会话详情") {
                if let store = monitor.store {
                    LabeledContent("读取状态", value: monitoringStateSummary(store.state))
                    if let error = store.error { Text(monitoringErrorSummary(error)) }
                    if store.cancellationReceipt != nil {
                        Label("已记录服务端持久取消回执", systemImage: "checkmark.circle")
                    }
                    DisclosureGroup("会话详情（高级）") {
                        LabeledContent("读取状态", value: String(describing: store.state))
                        if let error = store.error { Text(monitor.monitoringErrorText(error)) }
                        if let id = store.sessionID ?? monitor.pendingCreateUUID {
                            QuotaLabeledValue(title: "会话 UUID", value: id.uuidString)
                        }
                        if let active = store.session {
                            QuotaLabeledValue(title: "活动 ID", value: active.activityID)
                            LabeledContent("Source", value: active.sourceID)
                            LabeledContent("Revision", value: String(active.revision))
                            LabeledContent("远端状态", value: active.status.rawValue)
                            LabeledContent("推送状态", value: active.deliveryState.rawValue)
                            if let next = active.nextRefreshAt {
                                LabeledContent("服务预计下次采集") {
                                    Text(Date(timeIntervalSince1970: next), format: .dateTime.month().day().hour().minute())
                                }
                            }
                        }
                        Text("sent / ended 表示推送服务接受，不证明设备显示或移除。刷新返回受理状态不代表新读数已经产生。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("monitor.sessionDetails")
                } else {
                    Text("尚未配置监控服务")
                }
            }
            .listRowBackground(palette.contentSurface)

            Section {
                Button {
                    Task { await monitor.loadCachedQuotaForDraftSource() }
                } label: {
                    Label("读取当前来源缓存", systemImage: "tray.and.arrow.down")
                }
                .disabled(monitor.isBusy || monitor.bridgeState == .unconfigured
                          || monitor.sourceIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let cached = monitor.cachedSourceSnapshot {
                    LabeledContent("缓存来源", value: monitor.cachedSourceID ?? "未知")
                    LabeledContent("Sequence", value: String(cached.sequence))
                    MonitoringSnapshotRows(snapshot: cached)
                }
            } header: {
                Text("来源缓存")
            } footer: {
                Text("缓存只用于检查来源数据，不证明它包含本次选择的账号，也不会作为新的活动注册内容。")
            }
            .listRowBackground(palette.contentSurface)

            if let detached = monitor.store?.detachedSessions, !detached.isEmpty {
                Section("当前进程保留的原服务会话") {
                    ForEach(detached, id: \.handle) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            QuotaLabeledValue(title: "会话 UUID", value: item.id.uuidString)
                            Text(item.stopIntentRecorded ? "停止请求已确认" : "仍需核对原服务")
                                .font(.subheadline)
                            Button("查询原会话") { Task { await monitor.reconcileDetached(handle: item.handle) } }
                            Button("停止原会话", role: .destructive) {
                                Task { await monitor.stopDetached(handle: item.handle) }
                            }
                            Button("移除已结束记录", role: .destructive) { monitor.removeDetached(handle: item.handle) }
                                .disabled(!item.stopIntentRecorded && item.lastSession?.status != .stopped
                                          && item.lastSession?.status != .expired)
                        }
                    }
                }
                .listRowBackground(palette.contentSurface)
            }

            Section {
                if monitor.persistedRecords.isEmpty {
                    Text("暂无恢复记录").foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.persistedRecords) { record in
                        NavigationLink {
                            MonitoringRecoveryRecordView(record: record, monitor: monitor, maskEmail: session.maskEmail)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.sourceID).font(.headline)
                                Text(record.stopIntentRecorded ? "停止请求已确认" : "可核对原服务")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(record.savedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("持久恢复记录")
            } footer: {
                Text("记录保留原服务与凭据绑定。另一凭据必须先证明会话可见，应用不会将旧 UUID 直接提交给新的服务。")
            }
            .listRowBackground(palette.contentSurface)

            Section("更新与隐私") {
                Text("监控服务通常约每十分钟采集一次；首次读取可能需要等待，可主动请求首次更新。系统掌握后台推送与呈现时机。")
                Text("系统界面只接收安全别名、数值、状态和观察时间。CPA 管理密钥、监控访问令牌和推送令牌彼此独立，服务端推送私钥不会进入应用。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowBackground(palette.contentSurface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .tint(palette.actionTint)
        .navigationTitle("监控诊断")
    }
}

private struct MonitoringRecoveryRecordView: View {
    let record: PersistedMonitoringRecord
    @Bindable var monitor: MonitoringWorkspaceCoordinator
    let maskEmail: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = BrandPalette(colorScheme: colorScheme)
        Form {
            Section("原会话") {
                QuotaLabeledValue(title: "服务", value: record.bridgeBaseURLString)
                QuotaLabeledValue(title: "来源", value: record.sourceID)
                QuotaLabeledValue(title: "会话 UUID", value: record.sessionID.uuidString)
                QuotaLabeledValue(title: "活动 ID", value: record.activityID.isEmpty ? "启动中断，尚未保存" : record.activityID)
                QuotaLabeledValue(title: "账号", value: record.accountIDs.map { QuotaFormatter.maskEmail($0, enabled: maskEmail) }.joined(separator: "、"))
                LabeledContent("Revision", value: String(record.lastKnownRevision))
                LabeledContent("停止回执", value: record.stopIntentRecorded ? "已记录" : "未确认")
                LabeledContent("终态", value: record.terminalStatus?.rawValue ?? "未确认")
            }
            .listRowBackground(palette.contentSurface)
            Section {
                Button("核对并载入原会话") {
                    Task { await monitor.loadPersistedRecord(record) }
                }
                .disabled(monitor.isBusy)
                Button("移除已结束记录", role: .destructive) { monitor.removePersistedRecord(record) }
                    .disabled(!record.stopIntentRecorded && record.terminalStatus != .stopped && record.terminalStatus != .expired)
            } footer: {
                Text("确认载入后，返回监控页可停止该会话。未确认结束的记录不能删除，404 也不代表停止成功。")
            }
            .listRowBackground(palette.contentSurface)
            if let error = monitor.bridgeFormError {
                Section("处理结果") { MonitoringOperationError(message: error) }.listRowBackground(palette.contentSurface)
            }
            if let notice = monitor.bridgeStatusNotice {
                Section("状态") { MonitoringOperationStatus(message: notice) }.listRowBackground(palette.contentSurface)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandCanvasBackground())
        .navigationTitle("恢复记录")
    }
}

private struct MonitoringOperationError: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("未能完成操作，请查看详情并核对监控设置。", systemImage: "exclamationmark.triangle")
            DisclosureGroup("操作详情（高级）") { Text(message) }
        }
        .font(.subheadline)
    }
}

private struct MonitoringOperationStatus: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("操作状态已更新；如需停止监控，请核对原服务的确认状态。")
            DisclosureGroup("状态详情（高级）") { Text(message) }
        }
        .font(.subheadline)
    }
}

private func monitoringStateSummary(_ state: MonitoringStore.State) -> String {
    switch state {
    case .idle: "尚未读取"
    case .working: "正在处理"
    case .available: "已读取"
    case .stopIntentRecorded: "服务已记录停止请求"
    case .uncertain: "状态尚未确认"
    }
}

private func monitoringErrorSummary(_ error: MonitoringError) -> String {
    switch error {
    case .unauthorized: return "监控访问令牌已失效，请更新服务连接。"
    case .forbidden: return "此来源或账号尚未获得监控服务授权。"
    case .notFound: return "暂未找到原会话；不能据此确认已经停止。"
    case .conflict: return "原会话需要先核对，才能继续操作。"
    case .rateLimited: return "服务正在冷却，请稍后再试。"
    case .capacityExceeded: return "监控服务的历史记录容量已满。原会话仍可查询和停止，请联系服务维护者。"
    case .network, .serviceUnavailable: return "暂时无法联系监控服务，原会话状态已保留。"
    case .invalidConfiguration: return "请检查来源、账号和连接设置。"
    case .redirectRefused: return "服务返回了不安全的跳转，请检查连接地址。"
    case .rejected, .invalidResponse: return "监控服务未能确认此次操作，请查看诊断后重试。"
    }
}

private extension View {
    @ViewBuilder
    func monitoringInputCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func monitoringURLKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }
}
#endif
