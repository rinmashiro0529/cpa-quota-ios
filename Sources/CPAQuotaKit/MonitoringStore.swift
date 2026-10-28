import Foundation
import Observation

public struct DetachedMonitoringSession: Sendable {
    public let handle: UUID
    public let id: UUID
    public let client: CPAMonitorClient
    public let lastSession: MonitoringSession?
    public let stopIntentRecorded: Bool

    fileprivate init(handle: UUID = UUID(), id: UUID, client: CPAMonitorClient,
                     lastSession: MonitoringSession?, stopIntentRecorded: Bool = false) {
        self.handle = handle; self.id = id; self.client = client
        self.lastSession = lastSession; self.stopIntentRecorded = stopIntentRecorded
    }
}

@MainActor
@Observable
public final class MonitoringStore {
    public enum State: Sendable, Equatable {
        case idle, working, available, stopIntentRecorded, uncertain
    }
    public private(set) var sessionID: UUID?
    public private(set) var session: MonitoringSession?
    public private(set) var state: State = .idle
    public private(set) var error: MonitoringError?
    public private(set) var detachedSessions: [DetachedMonitoringSession] = []
    @ObservationIgnored private var client: CPAMonitorClient
    @ObservationIgnored private var generation: UInt64 = 0

    public init(client: CPAMonitorClient) { self.client = client }

    public func replaceClient(_ client: CPAMonitorClient) {
        generation &+= 1
        if let sessionID {
            detachedSessions.append(DetachedMonitoringSession(id: sessionID, client: self.client, lastSession: session))
        }
        self.client = client
        sessionID = nil; session = nil; error = nil; state = .idle
    }

    public func cancelPending() async {
        await stop()
    }

    public func start(_ registration: MonitoringRegistration) async {
        if let existing = sessionID, existing != registration.id {
            guard let session, session.id == existing, session.status != .active else {
                error = .conflict
                return
            }
            if session.deliveryState != .ended && session.deliveryState != .disabled {
                detachedSessions.append(DetachedMonitoringSession(id: existing, client: client, lastSession: session))
            }
            self.session = nil
        }
        generation &+= 1
        let current = generation
        sessionID = registration.id; state = .working; error = nil
        do {
            let result = try await client.create(registration)
            guard current == generation else { return }
            try Task.checkCancellation()
            try accept(result)
            state = .available
        } catch {
            guard current == generation else { return }
            self.error = Self.normalize(error); state = .uncertain
        }
    }

    public func load(id: UUID) async {
        generation &+= 1
        let current = generation
        if let oldID = sessionID, oldID != id {
            detachedSessions.append(DetachedMonitoringSession(id: oldID, client: client, lastSession: session))
            session = nil
        }
        sessionID = id; state = .working; error = nil
        do {
            let result = try await client.get(id: id)
            guard current == generation else { return }
            try Task.checkCancellation()
            try accept(result)
            state = .available
        } catch {
            guard current == generation else { return }
            self.error = Self.normalize(error); state = .uncertain
        }
    }

    public func refresh() async {
        guard let id = sessionID else { return }
        generation &+= 1
        let current = generation
        state = .working; error = nil
        do {
            let result = try await client.refresh(id: id)
            guard current == generation else { return }
            try Task.checkCancellation()
            try accept(result)
            state = .available
        } catch {
            guard current == generation else { return }
            self.error = Self.normalize(error); state = .uncertain
        }
    }

    public func rotate(token: MonitoringPushToken, revision: UInt64) async {
        guard let session, let id = sessionID, session.id == id else { return }
        generation &+= 1
        let current = generation
        state = .working; error = nil
        do {
            let result = try await client.rotate(id: id, activityID: session.activityID, token: token, revision: revision)
            guard current == generation else { return }
            try Task.checkCancellation()
            try accept(result)
            state = .available
        } catch {
            guard current == generation else { return }
            self.error = Self.normalize(error); state = .uncertain
        }
    }

    public func stop() async {
        guard let id = sessionID else { return }
        generation &+= 1
        let current = generation
        state = .working; error = nil
        do {
            let result = try await client.stop(id: id)
            guard current == generation else { return }
            try Task.checkCancellation()
            if let result { try accept(result); state = .available }
            else { state = .stopIntentRecorded }
        } catch {
            guard current == generation else { return }
            self.error = Self.normalize(error); state = .uncertain
        }
    }

    private static func checkProgress(_ result: MonitoringSession, from previous: MonitoringSession?) throws {
        guard let previous else { return }
        guard result.id == previous.id, result.sourceID == previous.sourceID,
              result.accountIDs == previous.accountIDs, result.activityID == previous.activityID,
              result.revision >= previous.revision,
              previous.status == .active || result.status != .active else { throw MonitoringError.invalidResponse }
        if let old = previous.snapshot {
            guard let new = result.snapshot, new.sequence >= old.sequence,
                  new.sequence != old.sequence || new == old else { throw MonitoringError.invalidResponse }
        }
    }

    private func accept(_ result: MonitoringSession) throws {
        guard result.id == sessionID else { throw MonitoringError.invalidResponse }
        try Self.checkProgress(result, from: session)
        session = result
    }

    public func loadDetached(handle: UUID) async throws -> MonitoringSession {
        guard let item = detachedSessions.first(where: { $0.handle == handle }) else { throw MonitoringError.notFound }
        let result = try await item.client.get(id: item.id)
        guard let index = detachedSessions.firstIndex(where: { $0.handle == handle }) else { throw MonitoringError.notFound }
        try Self.checkProgress(result, from: detachedSessions[index].lastSession)
        detachedSessions[index] = DetachedMonitoringSession(handle: handle, id: item.id, client: item.client,
                                                             lastSession: result, stopIntentRecorded: detachedSessions[index].stopIntentRecorded)
        return result
    }

    public func stopDetached(handle: UUID) async throws -> MonitoringSession? {
        guard let item = detachedSessions.first(where: { $0.handle == handle }) else { throw MonitoringError.notFound }
        let result = try await item.client.stop(id: item.id)
        guard let index = detachedSessions.firstIndex(where: { $0.handle == handle }) else { throw MonitoringError.notFound }
        if let result { try Self.checkProgress(result, from: detachedSessions[index].lastSession) }
        detachedSessions[index] = DetachedMonitoringSession(handle: handle, id: item.id, client: item.client,
                                                             lastSession: result ?? detachedSessions[index].lastSession,
                                                             stopIntentRecorded: result == nil || detachedSessions[index].stopIntentRecorded)
        return result
    }

    public func removeDetached(handle: UUID) throws {
        guard let index = detachedSessions.firstIndex(where: { $0.handle == handle }),
              let last = detachedSessions[index].lastSession, last.status != .active else {
            throw MonitoringError.conflict
        }
        detachedSessions.remove(at: index)
    }

    private static func normalize(_ error: any Error) -> MonitoringError {
        (error as? MonitoringError) ?? .network
    }
}
