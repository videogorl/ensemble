import Combine
import EnsembleAPI
import Foundation

/// Coordinates health checks across all configured servers
@MainActor
public final class ServerHealthChecker: ObservableObject {
    struct CheckSummary: Equatable {
        let checkedCount: Int
        let skippedCount: Int
    }

    private struct CachedCheckEntry {
        let state: ServerConnectionState
        let checkedAt: Date
    }

    private struct ServerCheckResult {
        let state: ServerConnectionState
        let usedCachedResult: Bool
    }

    @Published public private(set) var serverStates: [String: ServerConnectionState] = [:]

    private let accountManager: AccountManager
    private let failoverManager: ConnectionFailoverManager
    private let cacheTTL: TimeInterval
    private let unavailableCacheTTL: TimeInterval
    private let resourceRefreshCooldown: TimeInterval
    private let nowProvider: () -> Date

    private var recentChecks: [String: CachedCheckEntry] = [:]
    private var ongoingServerChecks: [String: Task<ServerCheckResult, Never>] = [:]
    private var lastResourceRefreshAt: [String: Date] = [:]

    public init(accountManager: AccountManager) {
        self.accountManager = accountManager
        // Slightly longer probe timeout avoids false offline on slower remote/relay paths.
        self.failoverManager = ConnectionFailoverManager(timeout: 6.0)
        self.cacheTTL = 120
        self.unavailableCacheTTL = 10
        self.resourceRefreshCooldown = 60
        self.nowProvider = { Date() }
    }

    internal init(
        accountManager: AccountManager,
        failoverManager: ConnectionFailoverManager,
        cacheTTL: TimeInterval = 120,
        unavailableCacheTTL: TimeInterval = 10,
        resourceRefreshCooldown: TimeInterval = 60,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.accountManager = accountManager
        self.failoverManager = failoverManager
        self.cacheTTL = cacheTTL
        self.unavailableCacheTTL = unavailableCacheTTL
        self.resourceRefreshCooldown = resourceRefreshCooldown
        self.nowProvider = nowProvider
    }

    // MARK: - Public Methods

    /// Check all configured servers and update their connection states
    public func checkAllServers() async {
        _ = await checkAllServers(forceRefresh: false, eligibleServerKeys: nil)
    }

    func checkAllServers(
        forceRefresh: Bool,
        eligibleServerKeys: Set<String>?
    ) async -> CheckSummary {
        #if DEBUG
        EnsembleLogger.debug(
            "🏥 ServerHealthChecker: Checking servers force=\(forceRefresh), filtered=\(eligibleServerKeys != nil)"
        )
        #endif

        var skippedCount = 0
        var checkedCount = 0

        await withTaskGroup(of: (checked: Int, skipped: Int).self) { group in
            for account in accountManager.plexAccounts {
                for server in account.servers {
                    let serverKey = makeServerKey(accountId: account.id, serverId: server.id)

                    if let eligibleServerKeys, !eligibleServerKeys.contains(serverKey) {
                        skippedCount += 1
                        #if DEBUG
                        EnsembleLogger.debug("🏥 ServerHealthChecker: Skipping \(serverKey) (no enabled libraries)")
                        #endif
                        continue
                    }

                    group.addTask {
                        let result = await self.checkServerResult(
                            accountId: account.id,
                            serverId: server.id,
                            forceRefresh: forceRefresh
                        )
                        return result.usedCachedResult ? (0, 1) : (1, 0)
                    }
                }
            }

            for await result in group {
                checkedCount += result.checked
                skippedCount += result.skipped
            }
        }

        #if DEBUG
        EnsembleLogger.debug(
            "🏥 ServerHealthChecker: Completed run checked=\(checkedCount), skipped=\(skippedCount)"
        )
        #endif

        return CheckSummary(checkedCount: checkedCount, skippedCount: skippedCount)
    }

    /// Check a specific server and return its connection state
    /// If a check is already in progress for this server, wait for it to complete
    public func checkServer(accountId: String, serverId: String) async -> ServerConnectionState {
        await checkServer(accountId: accountId, serverId: serverId, forceRefresh: false)
    }

    func checkServer(
        accountId: String,
        serverId: String,
        forceRefresh: Bool
    ) async -> ServerConnectionState {
        await checkServerResult(accountId: accountId, serverId: serverId, forceRefresh: forceRefresh).state
    }

    private func checkServerResult(
        accountId: String,
        serverId: String,
        forceRefresh: Bool
    ) async -> ServerCheckResult {
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
            return ServerCheckResult(state: .offline, usedCachedResult: false)
        }

        if !forceRefresh,
           let cached = recentChecks[serverKey] {
            let age = nowProvider().timeIntervalSince(cached.checkedAt)
            let ttl = cacheTTL(for: cached.state)

            if age < ttl {
                #if DEBUG
                EnsembleLogger.debug(
                    "🏥 ServerHealthChecker: Using cached state for \(serverKey) (\(String(format: "%.1f", age))s old, ttl=\(String(format: "%.1f", ttl))s)"
                )
                #endif
                serverStates[serverKey] = cached.state
                return ServerCheckResult(state: cached.state, usedCachedResult: true)
            }

            #if DEBUG
            EnsembleLogger.debug(
                "🏥 ServerHealthChecker: Cached state expired for \(serverKey) (\(String(format: "%.1f", age))s old, ttl=\(String(format: "%.1f", ttl))s)"
            )
            #endif
        }

        // Create a task for this check
        let checkTask = Task<ServerCheckResult, Never> { @MainActor in
            let state = await performServerCheck(accountId: accountId, serverId: serverId, server: server)
            serverStates[serverKey] = state
            recentChecks[serverKey] = CachedCheckEntry(state: state, checkedAt: nowProvider())
            ongoingServerChecks.removeValue(forKey: serverKey)
            return ServerCheckResult(state: state, usedCachedResult: false)
        }

        ongoingServerChecks[serverKey] = checkTask
        return await checkTask.value
    }

    /// Cancel all ongoing health checks
    public func cancelAllChecks() {
        for (_, task) in ongoingServerChecks {
            task.cancel()
        }
        ongoingServerChecks.removeAll()
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
            // Connection metadata can become stale (for example after WAN IP changes).
            // Refresh from plex.tv resources and retry once before marking offline.
            if let refreshedServer = await refreshServerConnectionsFromResources(
                accountId: accountId,
                serverId: serverId,
                serverKey: serverKey
            ) {
                let refreshedURLs = refreshedServer.orderedConnections.map(\.uri)
                #if DEBUG
                EnsembleLogger.debug(
                    "🔄 ServerHealthChecker: Retrying with refreshed resources (\(refreshedURLs.count) URLs)"
                )
                #endif

                if let refreshedWorkingURL = await failoverManager.findFastestConnection(
                    urls: refreshedURLs,
                    token: refreshedServer.token
                ) {
                    #if DEBUG
                    EnsembleLogger.debug(
                        "✅ ServerHealthChecker: Server \(server.name) recovered after resources refresh at \(refreshedWorkingURL)"
                    )
                    #endif
                    return .connected(url: refreshedWorkingURL)
                }
            }

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

    func cacheTTL(for state: ServerConnectionState) -> TimeInterval {
        state.isAvailable ? cacheTTL : unavailableCacheTTL
    }

    private func refreshServerConnectionsFromResources(
        accountId: String,
        serverId: String,
        serverKey: String
    ) async -> PlexServerConfig? {
        if let lastRefreshAt = lastResourceRefreshAt[serverKey],
           nowProvider().timeIntervalSince(lastRefreshAt) < resourceRefreshCooldown {
            #if DEBUG
            EnsembleLogger.debug(
                "🔄 ServerHealthChecker: Skipping resources refresh for \(serverKey) (cooldown)"
            )
            #endif
            return nil
        }
        lastResourceRefreshAt[serverKey] = nowProvider()

        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let existingServer = account.servers.first(where: { $0.id == serverId }),
              let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) else {
            return nil
        }

        do {
            let devices = try await apiClient.getResources(token: account.authToken)
            guard let matchedDevice = devices.first(where: { $0.clientIdentifier == serverId }) else {
                #if DEBUG
                EnsembleLogger.debug(
                    "🔄 ServerHealthChecker: No matching device found in refreshed resources for \(serverKey)"
                )
                #endif
                return nil
            }

            let refreshedConnections = matchedDevice.connections.map { conn in
                PlexConnectionConfig(
                    uri: conn.uri,
                    local: conn.local,
                    relay: conn.relay,
                    address: conn.address,
                    port: conn.port,
                    protocol: conn.protocol
                )
            }

            guard !refreshedConnections.isEmpty else { return nil }

            let refreshedURL = matchedDevice.bestConnection?.uri ?? refreshedConnections.first?.uri ?? existingServer.url
            let refreshedServer = PlexServerConfig(
                id: existingServer.id,
                name: existingServer.name,
                url: refreshedURL,
                connections: refreshedConnections,
                token: existingServer.token,
                platform: existingServer.platform,
                libraries: existingServer.libraries
            )

            let updatedServers = account.servers.map { server in
                server.id == serverId ? refreshedServer : server
            }
            let updatedAccount = PlexAccountConfig(
                id: account.id,
                username: account.username,
                authToken: account.authToken,
                servers: updatedServers
            )
            accountManager.updatePlexAccount(updatedAccount)

            #if DEBUG
            let relayCount = refreshedConnections.filter { $0.relay ?? false }.count
            EnsembleLogger.debug(
                "🔄 ServerHealthChecker: Refreshed resources for \(serverKey): urls=\(refreshedConnections.count), relay=\(relayCount)"
            )
            #endif

            return refreshedServer
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "⚠️ ServerHealthChecker: Failed to refresh resources for \(serverKey): \(error.localizedDescription)"
            )
            #endif
            return nil
        }
    }
}
