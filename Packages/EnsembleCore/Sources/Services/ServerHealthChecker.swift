import Combine
import EnsembleAPI
import Foundation

/// Focused UI projection and refresh scheduling for canonical server clients.
@MainActor
public final class ServerHealthChecker: ObservableObject {
    struct CheckSummary: Equatable {
        let checkedCount: Int
        let skippedCount: Int
    }

    private struct Observation {
        let client: PlexAPIClient
        var task: Task<Void, Never>?
        var snapshot: PlexConnectionSnapshot?
        var checkedAt: Date?
    }

    @Published public private(set) var serverStates: [String: ServerConnectionState] = [:]
    @Published public private(set) var serverFailureReasons: [String: ServerConnectionFailureReason] = [:]
    var onConnectionsChanged: (() async -> Void)?
    private let accountManager: AccountManager
    private let cacheTTL: TimeInterval
    private let unavailableCacheTTL: TimeInterval
    private let nowProvider: () -> Date
    private var observations: [String: Observation] = [:]

    public convenience init(accountManager: AccountManager, networkMonitor: NetworkMonitor) {
        self.init(accountManager: accountManager)
    }

    internal init(
        accountManager: AccountManager,
        cacheTTL: TimeInterval = 120,
        unavailableCacheTTL: TimeInterval = 10,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.accountManager = accountManager
        self.cacheTTL = cacheTTL
        self.unavailableCacheTTL = unavailableCacheTTL
        self.nowProvider = nowProvider
    }

    deinit {
        for observation in observations.values { observation.task?.cancel() }
    }

    public func prepopulateUnknownStates() {
        let keys = Set(accountManager.plexAccounts.flatMap { account in
            account.servers.map { "\(account.id):\($0.id)" }
        })
        for key in Array(observations.keys) where !keys.contains(key) {
            observations.removeValue(forKey: key)?.task?.cancel()
            serverStates.removeValue(forKey: key)
            serverFailureReasons.removeValue(forKey: key)
        }
        for account in accountManager.plexAccounts {
            for server in account.servers {
                let key = "\(account.id):\(server.id)"
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else { continue }
                if observations[key]?.client !== client {
                    observations[key]?.task?.cancel()
                    observations[key] = Observation(client: client)
                    observations[key]?.task = Task { [weak self] in
                        let stream = await client.connectionSnapshots()
                        for await snapshot in stream {
                            guard !Task.isCancelled, let self,
                                  self.observations[key]?.client === client,
                                  self.accountManager.makeAPIClient(accountId: account.id, serverId: server.id) === client else { break }
                            await self.apply(snapshot, key: key)
                        }
                    }
                }
                if serverStates[key] == nil { serverStates[key] = .unknown }
            }
        }
    }

    public func checkAllServers() async {
        _ = await checkAllServers(forceRefresh: false, eligibleServerKeys: nil)
    }

    func checkAllServers(forceRefresh: Bool, eligibleServerKeys: Set<String>?) async -> CheckSummary {
        prepopulateUnknownStates()
        var checked = 0
        var skipped = 0
        await withTaskGroup(of: Bool.self) { group in
            for account in accountManager.plexAccounts {
                for server in account.servers {
                    let key = "\(account.id):\(server.id)"
                    if let eligibleServerKeys, !eligibleServerKeys.contains(key) {
                        skipped += 1
                        continue
                    }
                    group.addTask {
                        await self.check(accountId: account.id, serverId: server.id, force: forceRefresh)
                    }
                }
            }
            for await didCheck in group {
                if didCheck { checked += 1 } else { skipped += 1 }
            }
        }
        return CheckSummary(checkedCount: checked, skippedCount: skipped)
    }

    public func checkServer(accountId: String, serverId: String) async -> ServerConnectionState {
        await checkServer(accountId: accountId, serverId: serverId, forceRefresh: false)
    }

    func checkServer(accountId: String, serverId: String, forceRefresh: Bool) async -> ServerConnectionState {
        _ = await check(accountId: accountId, serverId: serverId, force: forceRefresh)
        return getServerState(accountId: accountId, serverId: serverId)
    }

    private func check(accountId: String, serverId: String, force: Bool) async -> Bool {
        prepopulateUnknownStates()
        let key = "\(accountId):\(serverId)"
        guard let client = observations[key]?.client else { return false }
        if !force, let lastCheck = observations[key]?.checkedAt,
           nowProvider().timeIntervalSince(lastCheck) < cacheTTL(for: serverStates[key] ?? .unknown) { return false }
        observations[key]?.checkedAt = nowProvider()
        if force { _ = await accountManager.refreshServerResources(accountId: accountId, serverId: serverId, force: true) }
        do {
            _ = try await client.refreshConnection()
        } catch {
            if PlexErrorClassification.classify(error) != .cancelled,
               await accountManager.refreshServerResources(accountId: accountId, serverId: serverId) {
                _ = try? await client.refreshConnection()
            }
        }
        guard !Task.isCancelled, observations[key]?.client === client,
              accountManager.makeAPIClient(accountId: accountId, serverId: serverId) === client else { return true }
        let snapshot = await client.currentConnectionSnapshot()
        guard !Task.isCancelled, observations[key]?.client === client,
              accountManager.makeAPIClient(accountId: accountId, serverId: serverId) === client else { return true }
        await apply(snapshot, key: key)
        return true
    }

    public func invalidateConnectionHealth() async {
        for key in Array(observations.keys) { observations[key]?.checkedAt = nil }
    }

    public func markServerHealthy(accountId: String, serverId: String) async {
        let key = "\(accountId):\(serverId)"
        guard let client = observations[key]?.client else { return }
        let snapshot = await client.currentConnectionSnapshot()
        guard !Task.isCancelled, observations[key]?.client === client,
              accountManager.makeAPIClient(accountId: accountId, serverId: serverId) === client,
              snapshot.availability == .available else { return }
        observations[key]?.checkedAt = nowProvider()
        await apply(snapshot, key: key)
    }

    public func getServerState(accountId: String, serverId: String) -> ServerConnectionState {
        serverStates["\(accountId):\(serverId)"] ?? .unknown
    }

    public func getServerFailureReason(accountId: String, serverId: String) -> ServerConnectionFailureReason? {
        serverFailureReasons["\(accountId):\(serverId)"]
    }

    func cacheTTL(for state: ServerConnectionState) -> TimeInterval {
        state.isAvailable ? cacheTTL : unavailableCacheTTL
    }

    private func apply(_ snapshot: PlexConnectionSnapshot, key: String) async {
        guard let observation = observations[key] else { return }
        let previous = observation.snapshot
        if let previous, snapshot.sequence < previous.sequence { return }
        observations[key]?.snapshot = snapshot
        let state: ServerConnectionState
        switch snapshot.availability {
        case .unknown: state = .unknown
        case .checking: state = .connecting
        case .available: state = snapshot.endpoint.map { .connected(url: $0.url) } ?? .unknown
        case .unavailable, .retired: state = .offline
        }
        if serverStates[key] != state { serverStates[key] = state }
        let failure = state == .offline ? failureReason(snapshot, key: key) : nil
        if serverFailureReasons[key] != failure {
            serverFailureReasons[key] = failure
        }
        if previous?.revision != snapshot.revision || previous?.endpoint != snapshot.endpoint {
            await onConnectionsChanged?()
        }
    }

    private func failureReason(_ snapshot: PlexConnectionSnapshot, key: String) -> ServerConnectionFailureReason {
        if snapshot.failureCategory == .tls { return .tlsPolicyBlocked }
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let account = accountManager.plexAccounts.first(where: { $0.id == parts[0] }),
              let server = account.servers.first(where: { $0.id == parts[1] }) else { return .offline }
        let endpoints = server.orderedConnections
        if !endpoints.contains(where: { !$0.local && !($0.relay ?? false) }) {
            return endpoints.contains(where: { $0.relay ?? false }) ? .relayUnavailable : .localOnlyReachable
        }
        return .remoteAccessUnavailable
    }
}
