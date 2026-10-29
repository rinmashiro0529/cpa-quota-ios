#if canImport(SwiftUI)
import SwiftUI
import CPAQuotaKit

public struct MonitoringTabView: View {
    @Bindable public var session: CPAQuotaSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusedSnapshotIndex: Int = 0
    @State private var isConfirmingForgetLocallyOnly = false

    public init(session: CPAQuotaSession) {
        self.session = session
    }

    public var body: some View {
        let palette = LiquidGlassPalette(colorScheme: colorScheme)
        let monitor = session.monitoringCoordinator
        let store = monitor.store

        VStack(alignment: .leading, spacing: 16) {
                headerBanner(monitor: monitor, palette: palette)

                if let errorText = monitor.bridgeFormError {
                    noticeCard(title: "监控与桥接提示", message: errorText, tint: palette.statusError, palette: palette)
                }

                if let notice = monitor.bridgeStatusNotice {
                    noticeCard(title: "状态与对账回执", message: notice, tint: palette.statusWarn, palette: palette)
                }

                bridgeConfigurationCard(monitor: monitor, palette: palette)

                sessionRegistrationAndControlCard(monitor: monitor, store: store, palette: palette)

                if let activeSession = store?.session {
                    activeSessionDetailCard(activeSession: activeSession, store: store, monitor: monitor, palette: palette)
                    if let snapshot = activeSession.snapshot {
                        SystemLiveActivityPreviewCard(
                            sourceID: activeSession.sourceID,
                            snapshot: snapshot,
                            focusedIndex: $focusedSnapshotIndex,
                            palette: palette
                        )
                    }
                } else if let cached = monitor.cachedSourceSnapshot {
                    SystemLiveActivityPreviewCard(
                        sourceID: monitor.cachedSourceID ?? "cached-source",
                        snapshot: cached,
                        focusedIndex: $focusedSnapshotIndex,
                        palette: palette
                    )
                }

                if let detachedList = store?.detachedSessions, !detachedList.isEmpty {
                    detachedSessionsSection(detachedList: detachedList, monitor: monitor, palette: palette)
                }

                if !monitor.persistedRecords.isEmpty {
                    persistedReconciliationRecordsSection(monitor: monitor, palette: palette)
                }

                platformAndSecurityBoundaryCard(monitor: monitor, palette: palette)

        }
        .task {
            if monitor.bridgeState == .unconfigured {
                await monitor.restoreBridgeIfAvailable()
            }
        }
        .confirmationDialog(
            "确认仅在本机忘记桥接凭据？",
            isPresented: $isConfirmingForgetLocallyOnly,
            titleVisibility: .visible
        ) {
            Button("仅在本机移除 Keychain 桥接凭据（不代表服务端已停止）", role: .destructive) {
                Task { await monitor.forgetBridgeLocallyOnly() }
            }
            Button("先停止服务端会话 (DELETE 204) 再忘记", role: .none) {
                Task { await monitor.stopAndForgetBridge() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在本机忘记桥接 Token 不会停止服务端正在运行的监控租约。若服务端离线或未停止，监控会话将按 1/4/8 小时有限租约到期兜底。")
        }
    }

    @ViewBuilder
    private func headerBanner(monitor: MonitoringWorkspaceCoordinator, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("独立监控桥接与系统实时活动")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text("QuotaMonitor Bridge (v1) · ActivityKit / WidgetKit 协同")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }
                Spacer()
                switch monitor.bridgeState {
                case .unconfigured:
                    Text("未连接桥接")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.statusWarn)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlassPill(cornerRadius: 10)
                case .connected(_, let isSaved):
                    Text(isSaved ? "Keychain 已存" : "内存临时")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.statusOK)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .liquidGlassPill(cornerRadius: 10)
                }
            }
            Text("四种凭据严格隔离：CPA 管理密钥、MonitorBridgeToken、MonitoringPushToken 与服务端 APNs 私钥不可互换；APNs 私钥绝不进入客户端。")
                .font(.system(size: 10))
                .foregroundStyle(palette.textMuted)
                .lineSpacing(1.5)
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private func bridgeConfigurationCard(monitor: MonitoringWorkspaceCoordinator, palette: LiquidGlassPalette) -> some View {
        @Bindable var monitor = monitor
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 独立监控桥接配置 (CPAQuotaKit.MonitorBridgeCredentials)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            if case .connected(let url, let isSaved) = monitor.bridgeState {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前活动桥接地址")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textSecondary)
                        Text(url.absoluteString)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                    }
                    Spacer()
                    Text(isSaved ? "WhenUnlockedThisDeviceOnly" : "未持久化")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }
                .padding(10)
                .liquidGlassPill(cornerRadius: 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("HTTPS 桥接服务地址（保留反向代理路径前缀，不自动剥离 /v0/management）")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)
                TextField("https://monitor.example.com/bridge", text: $monitor.bridgeURLDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled(true)
                    .padding(10)
                    .liquidGlassPill(cornerRadius: 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MonitorBridgeToken（独立 Bearer 凭据，非 CPA 管理密钥）")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)
                SecureField("输入独立桥接访问 Token", text: $monitor.bridgeTokenDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .monitoringInputCapitalization()
                    .autocorrectionDisabled(true)
                    .padding(10)
                    .liquidGlassPill(cornerRadius: 12)
            }

            Toggle(isOn: $monitor.rememberBridgeDraft) {
                Text("安全保存至独立桥接 Keychain 命名空间")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
            }
            .tint(palette.accent)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await monitor.connectBridge(
                            rawURLString: monitor.bridgeURLDraft,
                            rawTokenString: monitor.bridgeTokenDraft,
                            rememberInKeychain: monitor.rememberBridgeDraft
                        )
                    }
                } label: {
                    Text("连接桥接")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.accent))
                }
                .buttonStyle(.plain)
                .disabled(monitor.isChangingBridge)

                if monitor.bridgeState != .unconfigured || monitor.isSavedInKeychain {
                    Button {
                        isConfirmingForgetLocallyOnly = true
                    } label: {
                        Text("停止 / 忘记桥接")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.statusError)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .liquidGlassPill(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private func sessionRegistrationAndControlCard(
        monitor: MonitoringWorkspaceCoordinator,
        store: MonitoringStore?,
        palette: LiquidGlassPalette
    ) -> some View {
        @Bindable var monitor = monitor
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("2. 有限期监控会话注册与对账控制")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                if let store {
                    Text("Store: \(String(describing: store.state))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(store.state == .uncertain ? palette.statusWarn : palette.accent)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("授权 Source ID（来自服务端部署配置，桥接无任意来源枚举接口）")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)
                HStack(spacing: 8) {
                    TextField("例如: personal", text: $monitor.sourceIDDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .monitoringInputCapitalization()
                        .autocorrectionDisabled(true)
                        .padding(10)
                        .liquidGlassPill(cornerRadius: 12)

                    Button {
                        Task { await monitor.loadCachedQuotaForDraftSource() }
                    } label: {
                        Text("读取缓存快照")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .liquidGlassPill(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(monitor.isBusy || monitor.bridgeState == .unconfigured)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("白名单授权 CPA 账号 ID（1–5 个，不按邮箱/昵称/数组位置猜测）")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    Text("已选 \(monitor.selectedAccountIDsDraft.count)/5")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }

                if !session.accounts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.accounts) { acc in
                                let isSelected = monitor.selectedAccountIDsDraft.contains(acc.id)
                                Button {
                                    if isSelected {
                                        monitor.removeAccountIDDraft(acc.id)
                                    } else {
                                        monitor.addAccountIDDraft(acc.id)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                                        Text("\(acc.displayName) (\(acc.id))")
                                    }
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(isSelected ? Color.white : palette.textPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background {
                                        if isSelected {
                                            Capsule().fill(palette.accent)
                                        } else {
                                            Capsule().fill(palette.pillTintOverlay)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("输入部署白名单授权的 account_id", text: $monitor.newAccountIDDraft)
                        .font(.system(size: 11, design: .monospaced))
                        .monitoringInputCapitalization()
                        .autocorrectionDisabled(true)
                        .padding(9)
                        .liquidGlassPill(cornerRadius: 10)

                    Button {
                        monitor.addAccountIDDraft(monitor.newAccountIDDraft)
                    } label: {
                        Text("添加 ID")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .liquidGlassPill(cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                }

                if !monitor.selectedAccountIDsDraft.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(monitor.selectedAccountIDsDraft, id: \.self) { id in
                                HStack(spacing: 4) {
                                    Text(id)
                                        .font(.system(size: 10, design: .monospaced))
                                    Button {
                                        monitor.removeAccountIDDraft(id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .foregroundStyle(palette.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .liquidGlassPill(cornerRadius: 8)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("监控租约时长 (MonitoringDuration)")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)
                HStack(spacing: 8) {
                    durationButton(title: "1 小时 (3600s)", duration: .oneHour, monitor: monitor, palette: palette)
                    durationButton(title: "4 小时 (14400s)", duration: .fourHours, monitor: monitor, palette: palette)
                    durationButton(title: "8 小时 (28800s)", duration: .eightHours, monitor: monitor, palette: palette)
                }
            }

            if let pendingID = monitor.pendingCreateUUID {
                Text("待对账会话 UUID: \(pendingID.uuidString)（超时恢复保持同一 UUID，不换新 UUID 盲目重发）")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.statusWarn)
            }

            if monitor.isWaitingForPushToken {
                Text("正在等待已创建活动的系统推送令牌；无需重复启动，可取消本次创建。")
                    .font(.footnote)
                    .foregroundStyle(palette.statusWarn)
            }

            if let storeError = store?.error {
                Text("Store 错误: \(monitor.monitoringErrorText(storeError))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.statusError)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Button {
                    Task { await monitor.startOrReconcileMonitoringSession() }
                } label: {
                    Text(monitor.pendingCreateUUID != nil ? "按原 UUID 对账/重试启动" : "启动有限期监控会话")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.accent))
                }
                .buttonStyle(.plain)
                .disabled(monitor.isBusy || monitor.isWaitingForPushToken || monitor.bridgeState == .unconfigured)

                Button {
                    Task { await monitor.reconcileCurrentSession() }
                } label: {
                    Text("查询对账 (GET)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .liquidGlassPill(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isBusy || monitor.bridgeState == .unconfigured)

                Button {
                    Task { await monitor.refreshActiveMonitoringSession() }
                } label: {
                    Text("触发刷新意图 (POST 202)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .liquidGlassPill(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isBusy || store?.session?.status != .active || monitor.bridgeState == .unconfigured)

                Button {
                    Task { await monitor.stopActiveMonitoringSession() }
                } label: {
                    Text("停止监控会话 (DELETE)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.statusError)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .liquidGlassPill(cornerRadius: 12)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isChangingBridge || monitor.bridgeState == .unconfigured ||
                          (store?.sessionID == nil && monitor.pendingCreateUUID == nil))
            }

            if store?.state == .working || monitor.isWaitingForPushToken {
                Button {
                    Task { await monitor.stopActiveMonitoringSession() }
                } label: {
                    Text("取消本次启动或停止原会话")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.statusError)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .liquidGlassPill(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private func durationButton(
        title: String,
        duration: MonitoringDuration,
        monitor: MonitoringWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        let isSelected = monitor.durationDraft == duration
        Button {
            monitor.durationDraft = duration
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .liquidGlassPill(cornerRadius: 10)
    }

    @ViewBuilder
    private func activeSessionDetailCard(
        activeSession: MonitoringSession,
        store: MonitoringStore?,
        monitor: MonitoringWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前监控会话状态")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text("status: \(activeSession.status.rawValue) · rev #\(activeSession.revision)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(activeSession.status == .active ? palette.statusOK : palette.statusWarn)
            }

            Text("UUID: \(activeSession.id.uuidString)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            Text("Source: \(activeSession.sourceID) · Activity: \(activeSession.activityID)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            Text("Delivery State: \(activeSession.deliveryState.rawValue)（注意：sent/ended 仅表示 APNs 接受推送，不证明真机已展示或移除）")
                .font(.system(size: 10))
                .foregroundStyle(palette.statusWarn)

            let startDate = Date(timeIntervalSince1970: activeSession.startsAt)
            let expireDate = Date(timeIntervalSince1970: activeSession.expiresAt)
            Text("租约起止: \(QuotaFormatter.exactTimestampString(startDate)) → \(QuotaFormatter.exactTimestampString(expireDate))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textMuted)

            if let receipt = store?.cancellationReceipt {
                Text("已持有 DELETE 204 取消墓碑回执: \(receipt.id.uuidString)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.statusOK)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func detachedSessionsSection(
        detachedList: [DetachedMonitoringSession],
        monitor: MonitoringWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分离的旧监控会话对账队列 (DetachedSessions)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("切换桥接配置或会话 UUID 后，未确认终态的旧会话保留在此处供独立查询或停止，不会静默遗忘。")
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)

            ForEach(detachedList, id: \.handle) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("UUID: \(item.id.uuidString.prefix(12))…")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text(item.stopIntentRecorded ? "204 取消回执已记录" : (item.lastSession?.status.rawValue ?? "状态待对账"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(item.stopIntentRecorded ? palette.statusOK : palette.statusWarn)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task { await monitor.reconcileDetached(handle: item.handle) }
                        } label: {
                            Text("查询对账")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlassPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await monitor.stopDetached(handle: item.handle) }
                        } label: {
                            Text("发送停止 (DELETE)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.statusError)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlassPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            monitor.removeDetached(handle: item.handle)
                        } label: {
                            Text("移除记录")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlassPill(cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .liquidGlassPill(cornerRadius: 12)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func persistedReconciliationRecordsSection(
        monitor: MonitoringWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会话恢复记录（桥接、账号 ID、活动与凭据标识；不含访问令牌）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            ForEach(monitor.persistedRecords) { rec in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(rec.sourceID) · UUID \(rec.sessionID.uuidString.prefix(8))… · rev #\(rec.lastKnownRevision)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                        Text("\(rec.bridgeBaseURLString) · \(rec.stopIntentRecorded ? "已获204回执" : "待对账")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await monitor.loadPersistedRecord(rec)
                        }
                    } label: {
                        Text("核对并载入")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .liquidGlassPill(cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(monitor.isBusy)
                }
                .padding(8)
                .liquidGlassPill(cornerRadius: 10)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func platformAndSecurityBoundaryCard(
        monitor: MonitoringWorkspaceCoordinator,
        palette: LiquidGlassPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("系统实时活动 (ActivityKit / WidgetKit) 与平台诚实边界")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("• 本地 ActivityKit 驱动支持: \(monitor.liveActivityDriver.isSupportedOnCurrentPlatform ? "已编译 ActivityKit 分支" : "当前非 iOS 运行时") · 系统授权状态: \(monitor.liveActivityDriver.areActivitiesEnabled ? "已允许" : "未启用或需真机签名权限")\n• 服务端 600 秒是采集目标周期，不是设备送达承诺。系统活动显示首个授权账号与其余账号数量，全部账号可在 App 查看；当前未实现系统后台自动轮播。\n• 退出 App 后的锁屏更新、APNs 实际送达与活动恢复仍需使用签名真机及已部署服务验收。")
                .font(.system(size: 10))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(2)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func noticeCard(title: String, message: String, tint: Color, palette: LiquidGlassPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(1.5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18)
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
}
#endif
