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

/// Each read-only endpoint owns its query, snapshot and retry state. A successful
/// response is usable immediately, even when another endpoint is unavailable.
public enum CAPUsageDetailResource: String, CaseIterable, Hashable, Sendable {
    case initial, trends, groups, costs
}

public struct CAPUsageResourceQuery: Equatable, Sendable {
    public let window: CAPUsageWindow
    public let groupOffset: Int
    public let groupLimit: Int

    public init(window: CAPUsageWindow, groupOffset: Int = 0, groupLimit: Int = 100) {
        self.window = window
        self.groupOffset = groupOffset
        self.groupLimit = groupLimit
    }
}

public struct CAPUsageResourceSnapshot<Value: Sendable>: Sendable {
    public let query: CAPUsageResourceQuery
    public let value: Value
    public var window: CAPUsageWindow { query.window }
}

public struct CAPUsageResourceState<Value: Sendable>: Sendable {
    public fileprivate(set) var snapshot: CAPUsageResourceSnapshot<Value>?
    public fileprivate(set) var requestedQuery: CAPUsageResourceQuery?
    public fileprivate(set) var error: CAPUsageError?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var isShowingPreviousResult = false

    fileprivate mutating func begin(_ query: CAPUsageResourceQuery) {
        requestedQuery = query
        error = nil
        isLoading = true
        isShowingPreviousResult = snapshot != nil
    }

    fileprivate mutating func accept(_ value: Value, query: CAPUsageResourceQuery) {
        snapshot = CAPUsageResourceSnapshot(query: query, value: value)
        error = nil
        isLoading = false
        isShowingPreviousResult = false
    }

    fileprivate mutating func fail(_ error: CAPUsageError) {
        self.error = error
        isLoading = false
    }
}

@MainActor @Observable
public final class CAPUsageStore {
    public private(set) var initialState = CAPUsageResourceState<CAPUsageInitialStats>()
    public private(set) var trendsState = CAPUsageResourceState<CAPUsageTrends>()
    public private(set) var groupsState = CAPUsageResourceState<CAPUsageGroups>()
    public private(set) var costsState = CAPUsageResourceState<CAPUsageCosts>()

    /// Compatibility view of the last set whose resources share a window.
    /// New consumers should use the independent states: fixed windows do not
    /// prove that endpoint responses share an atomic database snapshot.
    public private(set) var details: CAPUsageDetailSnapshot?
    public var detailsError: CAPUsageError? {
        initialState.error ?? trendsState.error ?? groupsState.error ?? costsState.error
    }
    public var isLoadingDetails: Bool {
        initialState.isLoading || trendsState.isLoading || groupsState.isLoading || costsState.isLoading
    }
    public var failedDetailResources: [CAPUsageDetailResource] {
        CAPUsageDetailResource.allCases.filter { detailError(for: $0) != nil }
    }

    private var detailsGeneration = UUID()
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
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

    public func refreshDetails(window: CAPUsageWindow, groupOffset: Int = 0, groupLimit: Int = 100,
                               onResourceUpdate: (@MainActor @Sendable (CAPUsageDetailResource) -> Void)? = nil) async {
        let query = CAPUsageResourceQuery(window: window, groupOffset: groupOffset, groupLimit: groupLimit)
        await loadDetails(CAPUsageDetailResource.allCases.map { ($0, query) }, onResourceUpdate: onResourceUpdate)
    }

    public func refreshGroupPage(window: CAPUsageWindow, groupOffset: Int, groupLimit: Int,
                                 onResourceUpdate: (@MainActor @Sendable (CAPUsageDetailResource) -> Void)? = nil) async {
        let query = CAPUsageResourceQuery(window: window, groupOffset: groupOffset, groupLimit: groupLimit)
        await loadDetails([(.groups, query)], onResourceUpdate: onResourceUpdate)
    }

    /// Reuses the failed region's attempted query, including its page offset.
    /// This cannot switch credentials, clear a cooldown or reopen a circuit.
    public func retryDetailResource(_ resource: CAPUsageDetailResource,
                                    onResourceUpdate: (@MainActor @Sendable (CAPUsageDetailResource) -> Void)? = nil) async {
        guard detailError(for: resource) != nil, let query = requestedQuery(for: resource) else { return }
        await loadDetails([(resource, query)], onResourceUpdate: onResourceUpdate)
    }

    public func retryFailedDetails(
        onResourceUpdate: (@MainActor @Sendable (CAPUsageDetailResource) -> Void)? = nil
    ) async {
        let reads = failedDetailResources.compactMap { resource -> (CAPUsageDetailResource, CAPUsageResourceQuery)? in
            guard let query = requestedQuery(for: resource) else { return nil }
            return (resource, query)
        }
        guard !reads.isEmpty else { return }
        await loadDetails(reads, onResourceUpdate: onResourceUpdate)
    }

    public func cancelDetails() {
        detailsGeneration = UUID()
        detailsTask?.cancel()
        detailsTask = nil
        clearDetailsLoading()
    }

    private func loadDetails(_ reads: [(CAPUsageDetailResource, CAPUsageResourceQuery)],
                             onResourceUpdate: (@MainActor @Sendable (CAPUsageDetailResource) -> Void)?) async {
        guard !Task.isCancelled else { return }
        cancelDetails()
        let token = detailsGeneration
        for (resource, query) in reads { begin(resource, query: query) }
        // Sequential, independently recoverable reads retain the existing
        // shared request permit and bound in-flight work to one endpoint.
        let task = Task { @MainActor in
            for (resource, query) in reads {
                guard !Task.isCancelled, self.detailsGeneration == token else { break }
                await self.load(resource, query: query, generation: token)
                guard !Task.isCancelled, self.detailsGeneration == token else { break }
                onResourceUpdate?(resource)
            }
        }
        detailsTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if detailsGeneration == token {
            detailsTask = nil
            clearDetailsLoading()
        }
    }

    private func load(_ resource: CAPUsageDetailResource, query: CAPUsageResourceQuery, generation token: UUID) async {
        do {
            guard query.groupOffset >= 0, (1...500).contains(query.groupLimit) else {
                throw CAPUsageError.invalidResponse
            }
            switch resource {
            case .initial:
                let value = try await client.loadInitialStats(window: query.window, access: access)
                guard !Task.isCancelled, detailsGeneration == token else { return }
                initialState.accept(value, query: query)
            case .trends:
                let value = try await client.loadTrends(window: query.window, access: access)
                guard !Task.isCancelled, detailsGeneration == token else { return }
                trendsState.accept(value, query: query)
            case .groups:
                let value = try await client.loadGroups(window: query.window, offset: query.groupOffset,
                                                        limit: query.groupLimit, access: access)
                guard !Task.isCancelled, detailsGeneration == token else { return }
                groupsState.accept(value, query: query)
            case .costs:
                let value = try await client.loadCosts(window: query.window, access: access)
                guard !Task.isCancelled, detailsGeneration == token else { return }
                costsState.accept(value, query: query)
            }
            publishCoherentDetails()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, detailsGeneration == token else { return }
            let failure = (error as? CAPUsageError) ?? (error as? CPAError).map(CAPUsageError.management) ?? .network
            switch resource {
            case .initial: initialState.fail(failure)
            case .trends: trendsState.fail(failure)
            case .groups: groupsState.fail(failure)
            case .costs: costsState.fail(failure)
            }
        }
    }

    private func begin(_ resource: CAPUsageDetailResource, query: CAPUsageResourceQuery) {
        switch resource {
        case .initial: initialState.begin(query)
        case .trends: trendsState.begin(query)
        case .groups: groupsState.begin(query)
        case .costs: costsState.begin(query)
        }
    }

    private func clearDetailsLoading() {
        initialState.isLoading = false
        trendsState.isLoading = false
        groupsState.isLoading = false
        costsState.isLoading = false
    }

    private func detailError(for resource: CAPUsageDetailResource) -> CAPUsageError? {
        switch resource {
        case .initial: initialState.error
        case .trends: trendsState.error
        case .groups: groupsState.error
        case .costs: costsState.error
        }
    }

    private func requestedQuery(for resource: CAPUsageDetailResource) -> CAPUsageResourceQuery? {
        switch resource {
        case .initial: initialState.requestedQuery
        case .trends: trendsState.requestedQuery
        case .groups: groupsState.requestedQuery
        case .costs: costsState.requestedQuery
        }
    }

    private func publishCoherentDetails() {
        guard let initial = initialState.snapshot, let trends = trendsState.snapshot,
              let groups = groupsState.snapshot, let costs = costsState.snapshot,
              initial.window == trends.window, initial.window == groups.window,
              initial.window == costs.window else { return }
        details = CAPUsageDetailSnapshot(window: initial.window, groupOffset: groups.query.groupOffset,
            groupLimit: groups.query.groupLimit, initial: initial.value, trends: trends.value,
            groups: groups.value, costs: costs.value)
    }

    public func cancelOverview() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
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
