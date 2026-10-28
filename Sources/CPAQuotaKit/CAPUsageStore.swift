import Foundation
import Observation

public struct CAPUsageSnapshot: Sendable {
    public let window: CAPUsageWindow
    public let requests: CAPUsageRequestCollection
    public let models: [CAPUsageModelSummary]
}

public struct CAPUsageDetailSnapshot: Sendable {
    public let window: CAPUsageWindow
    public let groupOffset: Int
    public let groupLimit: Int
    public let initial: CAPUsageInitialStats
    public let trends: CAPUsageTrends
    public let groups: CAPUsageGroups
    public let costs: CAPUsageCosts
}

@MainActor @Observable
public final class CAPUsageStore {
    public private(set) var details: CAPUsageDetailSnapshot?
    public private(set) var detailsError: CAPUsageError?
    public private(set) var isLoadingDetails = false
    private var detailsGeneration = UUID()
    @ObservationIgnored private var detailsTask: Task<CAPUsageDetailSnapshot, any Error>?
    @ObservationIgnored private var refreshTask: Task<CAPUsageRequestCollection, any Error>?
    public private(set) var snapshot: CAPUsageSnapshot?
    public private(set) var error: CAPUsageError?
    public private(set) var isRefreshing = false
    private var generation = UUID()
    private let client: CAPUsageClient
    private let access: CAPUsageResourceAccess

    public init(client: CAPUsageClient, access: CAPUsageResourceAccess) {
        self.client = client
        self.access = access
    }

    public func refreshDetails(window: CAPUsageWindow, groupOffset: Int = 0, groupLimit: Int = 100) async {
        let token = UUID()
        detailsGeneration = token
        detailsTask?.cancel()
        isLoadingDetails = true
        detailsError = nil
        let client = client
        let access = access
        let task = Task {
            guard groupOffset >= 0, (1...500).contains(groupLimit) else { throw CAPUsageError.invalidResponse }
            let initial = try await client.loadInitialStats(window: window, access: access)
            let trends = try await client.loadTrends(window: window, access: access)
            let groups = try await client.loadGroups(window: window, offset: groupOffset, limit: groupLimit, access: access)
            let costs = try await client.loadCosts(window: window, access: access)
            try Task.checkCancellation()
            return CAPUsageDetailSnapshot(window: window, groupOffset: groupOffset, groupLimit: groupLimit,
                                          initial: initial, trends: trends, groups: groups, costs: costs)
        }
        detailsTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard detailsGeneration == token else { return }
            details = result
        } catch is CancellationError {
        } catch let failure as CAPUsageError {
            guard detailsGeneration == token else { return }
            detailsError = failure
        } catch let failure as CPAError {
            guard detailsGeneration == token else { return }
            detailsError = .management(failure)
        } catch {
            guard detailsGeneration == token else { return }
            detailsError = .network
        }
        if detailsGeneration == token {
            detailsTask = nil
            isLoadingDetails = false
        }
    }

    public func refresh(window: CAPUsageWindow) async {
        let token = UUID()
        generation = token
        refreshTask?.cancel()
        isRefreshing = true
        error = nil
        let client = client
        let access = access
        let task = Task { try await client.loadWindowRequests(window: window, access: access) }
        refreshTask = task
        do {
            let requests = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            snapshot = CAPUsageSnapshot(window: window, requests: requests,
                                        models: CAPUsageAggregation.byModel(requests.items))
        } catch is CancellationError {
        } catch let failure as CAPUsageError {
            guard generation == token else { return }
            error = failure
        } catch let failure as CPAError {
            guard generation == token else { return }
            error = .management(failure)
        } catch {
            guard generation == token else { return }
            self.error = .network
        }
        if generation == token {
            refreshTask = nil
            isRefreshing = false
        }
    }
}
