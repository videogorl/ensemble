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

    public init(accountManager: AccountManager) {
        self.accountManager = accountManager
        self.failoverManager = ConnectionFailoverManager()
    }

    // MARK: - Public Methods

    /// Check all configured servers and update their connection states
    public func checkAllServers() async {
        print("🏥 ServerHealthChecker: Checking all servers...")

        // Cancel any ongoing checks
        cancelAllChecks()

        // Check each server concurrently
        await withTaskGroup(of: (String, ServerConnectionState).self) { group in
            for account in accountManager.plexAccounts {
                for server in account.servers {
                    let serverKey = makeServerKey(accountId: account.id, serverId: server.id)

                    group.addTask {
                        let state = await self.performServerCheck(
                            accountId: account.id,
                            serverId: server.id,
                            server: server
                        )
                        return (serverKey, state)
                    }
                }
            }

            // Collect results
            for await (serverKey, state) in group {
                serverStates[serverKey] = state
            }
        }

        print("🏥 ServerHealthChecker: Completed checking \(serverStates.count) servers")
    }

    /// Check a specific server and return its connection state
    public func checkServer(accountId: String, serverId: String) async -> ServerConnectionState {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            return .offline
        }

        let serverKey = makeServerKey(accountId: accountId, serverId: serverId)
        let state = await performServerCheck(accountId: accountId, serverId: serverId, server: server)
        serverStates[serverKey] = state
        return state
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
            print("⚠️ ServerHealthChecker: No connection URLs for server \(server.name)")
            return .offline
        }

        // Try to find a working connection
        if let workingURL = await failoverManager.findWorkingConnection(
            urls: connectionURLs,
            token: server.token
        ) {
            print("✅ ServerHealthChecker: Server \(server.name) is online at \(workingURL)")
            return .connected(url: workingURL)
        } else {
            print("❌ ServerHealthChecker: Server \(server.name) is offline")
            return .offline
        }
    }

    /// Create a unique key for server identification
    private func makeServerKey(accountId: String, serverId: String) -> String {
        "\(accountId):\(serverId)"
    }
}
