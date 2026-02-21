import Combine
import EnsembleAPI
import Foundation

/// Coordinates health checks across all configured servers
@MainActor
public final class ServerHealthChecker: ObservableObject {
    @Published public private(set) var serverStates: [String: ServerConnectionState] = [:]

    private let accountManager: AccountManager
    private let failoverManager: ConnectionFailoverManager
    private var checkTasks: [String: Task<Void, Never>] = [:]
    private var ongoingServerChecks: [String: Task<ServerConnectionState, Never>] = [:]

    public init(accountManager: AccountManager) {
        self.accountManager = accountManager
        // Use 3 second timeout for faster checks
        self.failoverManager = ConnectionFailoverManager(timeout: 3.0)
    }

    // MARK: - Public Methods

    /// Check all configured servers and update their connection states
    public func checkAllServers() async {
        #if DEBUG
        EnsembleLogger.debug("🏥 ServerHealthChecker: Checking all servers...")
        #endif

        // Check each server concurrently using the checkServer method
        // This ensures we reuse any ongoing checks
        await withTaskGroup(of: Void.self) { group in
            for account in accountManager.plexAccounts {
                #if DEBUG
                EnsembleLogger.debug("🏥   Account: \(account.username) (ID: \(account.id))")
                #endif
                for server in account.servers {
                    #if DEBUG
                    EnsembleLogger.debug("🏥     Server: \(server.name) (ID: \(server.id), Connections: \(server.connections.count))")
                    #endif

                    group.addTask {
                        _ = await self.checkServer(accountId: account.id, serverId: server.id)
                    }
                }
            }
            
            await group.waitForAll()
        }

        #if DEBUG
        EnsembleLogger.debug("🏥 ServerHealthChecker: Completed checking \(serverStates.count) servers")
        #endif
    }

    /// Check a specific server and return its connection state
    /// If a check is already in progress for this server, wait for it to complete
    public func checkServer(accountId: String, serverId: String) async -> ServerConnectionState {
        let serverKey = makeServerKey(accountId: accountId, serverId: serverId)
        
        // If there's an ongoing check for this server, wait for it
        if let ongoingTask = ongoingServerChecks[serverKey] {
            #if DEBUG
            EnsembleLogger.debug("⏳ ServerHealthChecker: Waiting for ongoing check of server \(serverKey)")
            #endif
            return await ongoingTask.value
        }
        
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            return .offline
        }

        // Create a task for this check
        let checkTask = Task<ServerConnectionState, Never> {
            let state = await performServerCheck(accountId: accountId, serverId: serverId, server: server)
            await MainActor.run {
                serverStates[serverKey] = state
                ongoingServerChecks.removeValue(forKey: serverKey)
            }
            return state
        }
        
        ongoingServerChecks[serverKey] = checkTask
        return await checkTask.value
    }

    /// Cancel all ongoing health checks
    public func cancelAllChecks() {
        for (_, task) in checkTasks {
            task.cancel()
        }
        checkTasks.removeAll()
    }

    /// Get the current state for a server
    public func getServerState(accountId: String, serverId: String) -> ServerConnectionState {
        let serverKey = makeServerKey(accountId: accountId, serverId: serverId)
        return serverStates[serverKey] ?? .unknown
    }

    // MARK: - Private Methods

    /// Perform health check for a single server
    private func performServerCheck(
        accountId: String,
        serverId: String,
        server: PlexServerConfig
    ) async -> ServerConnectionState {
        let serverKey = makeServerKey(accountId: accountId, serverId: serverId)

        // Update state to connecting
        await MainActor.run {
            serverStates[serverKey] = .connecting
        }

        // Get all connection URLs in priority order
        let connectionURLs = server.orderedConnections.map { $0.uri }

        guard !connectionURLs.isEmpty else {
            #if DEBUG
            EnsembleLogger.debug("⚠️ ServerHealthChecker: No connection URLs for server \(server.name)")
            #endif
            return .offline
        }

        #if DEBUG
        EnsembleLogger.debug("🔍 ServerHealthChecker: Testing \(connectionURLs.count) URLs for server \(server.name):")
        #endif
        for (index, url) in connectionURLs.enumerated() {
            #if DEBUG
            EnsembleLogger.debug("  [\(index + 1)] \(url)")
            #endif
        }

        // Try to find the fastest working connection (tests in parallel for speed)
        if let workingURL = await failoverManager.findFastestConnection(
            urls: connectionURLs,
            token: server.token
        ) {
            #if DEBUG
            EnsembleLogger.debug("✅ ServerHealthChecker: Server \(server.name) is online at \(workingURL)")
            #endif
            return .connected(url: workingURL)
        } else {
            #if DEBUG
            EnsembleLogger.debug("❌ ServerHealthChecker: Server \(server.name) is offline - all \(connectionURLs.count) URLs failed")
            #endif
            return .offline
        }
    }

    /// Create a unique key for server identification
    private func makeServerKey(accountId: String, serverId: String) -> String {
        "\(accountId):\(serverId)"
    }
}
