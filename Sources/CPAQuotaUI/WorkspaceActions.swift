import Foundation

@MainActor
public extension CPAQuotaSession {
    /// The global control belongs to the visible workspace, not always to quota reads.
    var isCurrentWorkspaceBusy: Bool {
        switch activeTab {
        case .usage:
            return capUsageCoordinator.store?.isRefreshing == true
                || capUsageCoordinator.store?.isLoadingDetails == true
                || capUsageCoordinator.isLoadingManagementStats
                || capUsageCoordinator.isLoadingRequestPage
        case .monitoring:
            return monitoringCoordinator.isBusy
        case .quotas, .accounts, .connection:
            return isBusy
        }
    }

    var currentWorkspaceActionDisabled: Bool {
        activeTab == .monitoring
            && (monitoringCoordinator.activeAddress == nil || monitoringCoordinator.isBusy)
    }

    var currentWorkspaceCanCancelRead: Bool {
        activeTab != .monitoring && isCurrentWorkspaceBusy
    }

    var currentWorkspaceActionLabel: String {
        if currentWorkspaceCanCancelRead { return "取消当前读取" }
        switch activeTab {
        case .usage: return "刷新 CAP 用量总览"
        case .monitoring: return "核对当前监控会话"
        case .quotas, .accounts, .connection: return "刷新全部账号额度"
        }
    }

    /// Pull-to-refresh is read-only. In particular it never registers or stops monitoring.
    func refreshCurrentWorkspace() async {
        switch activeTab {
        case .usage:
            await capUsageCoordinator.refreshOverview()
        case .monitoring:
            guard !monitoringCoordinator.isBusy else { return }
            await monitoringCoordinator.reconcileCurrentSession()
        case .quotas, .accounts, .connection:
            guard case .connected = authState else { return }
            await refreshAll(force: true)
        }
    }

    func performCurrentWorkspaceAction() async {
        guard !currentWorkspaceActionDisabled else { return }
        if currentWorkspaceCanCancelRead {
            if activeTab == .usage {
                capUsageCoordinator.cancelAll()
            } else {
                await cancelActiveOperation()
            }
            return
        }
        if activeTab != .monitoring, case .unconfigured = authState {
            isPresentingConnectionSheet = true
            return
        }
        await refreshCurrentWorkspace()
    }
}
