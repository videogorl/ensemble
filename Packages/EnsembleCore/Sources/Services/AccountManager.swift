import Combine
import EnsembleAPI
import Foundation

/// Manages connected music source accounts (Plex, future Apple Music, etc.)
@MainActor
public final class AccountManager: ObservableObject {
    @Published public private(set) var plexAccounts: [PlexAccountConfig] = []

    private let keychain: KeychainServiceProtocol
    private let connectionRegistry: ServerConnectionRegistry?
    private var apiClientCache: [String: PlexAPIClient] = [:]  // Cache by "accountId:serverId"
    private static let authMigrationVersionKey = "plex_auth_migration_version"
    private static let authMigrationVersion = 2

    public init(keychain: KeychainServiceProtocol, connectionRegistry: ServerConnectionRegistry? = nil) {
        self.keychain = keychain
        self.connectionRegistry = connectionRegistry
    }

    // MARK: - Load / Save

    public func loadAccounts() {
        if applyAuthMigrationIfNeeded() {
            return
        }

        guard let json = try? keychain.get(KeychainKey.plexAccounts),
              let data = json.data(using: .utf8) else {
            plexAccounts = []
            return
        }

        plexAccounts = (try? JSONDecoder().decode([PlexAccountConfig].self, from: data)) ?? []
        _ = enforceAuthTokenPolicy()
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(plexAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.save(json, forKey: KeychainKey.plexAccounts)
        SiriMediaIndexNotifications.postRebuildRequest(reason: "account_configuration_changed")

        // Push stripped credentials to iCloud Keychain for cross-device sync
        pushSyncCredentials()
    }

    // MARK: - iCloud Keychain Sync

    /// Callback invoked when synced credentials arrive with new account IDs
    /// not present locally. DependencyContainer wires this to account discovery.
    public var onNewAccountsFromSync: (([SyncableAccountCredential]) -> Void)?

    /// Push current account credentials (stripped of connections) to iCloud Keychain.
    /// Guarded — silently skips if encoding or keychain write fails.
    private func pushSyncCredentials() {
        let syncable = plexAccounts.map { SyncableAccountCredential(from: $0) }
        guard let data = try? JSONEncoder().encode(syncable),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try keychain.saveSynchronizable(json, forKey: KeychainKey.plexAccountsSync)
        } catch {
            EnsembleLogger.error("Failed to push sync credentials to iCloud Keychain: \(error)")
        }
    }

    /// Pull credentials from iCloud Keychain and reconcile with local accounts.
    /// Returns new accounts that need discovery, if any.
    public func pullSyncCredentials() -> [SyncableAccountCredential] {
        guard let json = try? keychain.getSynchronizable(KeychainKey.plexAccountsSync),
              let data = json.data(using: .utf8),
              let synced = try? JSONDecoder().decode([SyncableAccountCredential].self, from: data) else {
            return []
        }

        let localIds = Set(plexAccounts.map(\.id))
        return synced.filter { !localIds.contains($0.accountId) }
    }

    // MARK: - Library Flags Sync

    /// Export library enabled flags as a JSON-serializable dictionary.
    /// Key format: "accountId:serverId:libraryKey" → Bool
    public func exportLibraryFlags() -> Data? {
        var flags: [String: Bool] = [:]
        for account in plexAccounts {
            for server in account.servers {
                for library in server.libraries {
                    let key = "\(account.id):\(server.id):\(library.key)"
                    flags[key] = library.isEnabled
                }
            }
        }
        return try? JSONEncoder().encode(flags)
    }

    /// Apply synced library flags from iCloud KVS.
    /// Only updates flags for libraries that already exist locally.
    public func applyLibraryFlags(_ data: Data) {
        guard let flags = try? JSONDecoder().decode([String: Bool].self, from: data) else { return }
        var didChange = false

        for i in plexAccounts.indices {
            for j in plexAccounts[i].servers.indices {
                let server = plexAccounts[i].servers[j]
                var updatedLibraries = server.libraries
                var serverChanged = false

                for k in updatedLibraries.indices {
                    let key = "\(plexAccounts[i].id):\(server.id):\(updatedLibraries[k].key)"
                    if let remoteEnabled = flags[key],
                       updatedLibraries[k].isEnabled != remoteEnabled {
                        updatedLibraries[k] = PlexLibraryConfig(
                            id: updatedLibraries[k].id,
                            key: updatedLibraries[k].key,
                            title: updatedLibraries[k].title,
                            isEnabled: remoteEnabled,
                            allowSync: updatedLibraries[k].allowSync
                        )
                        serverChanged = true
                    }
                }

                if serverChanged {
                    var updatedServers = plexAccounts[i].servers
                    updatedServers[j] = PlexServerConfig(
                        id: server.id,
                        name: server.name,
                        url: server.url,
                        connections: server.connections,
                        token: server.token,
                        platform: server.platform,
                        capabilities: server.capabilities,
                        libraries: updatedLibraries
                    )
                    plexAccounts[i] = PlexAccountConfig(
                        id: plexAccounts[i].id,
                        email: plexAccounts[i].email,
                        plexUsername: plexAccounts[i].plexUsername,
                        displayTitle: plexAccounts[i].displayTitle,
                        authToken: plexAccounts[i].authToken,
                        authTokenMetadata: plexAccounts[i].authTokenMetadata,
                        subscription: plexAccounts[i].subscription,
                        servers: updatedServers
                    )
                    didChange = true
                }
            }
        }

        if didChange {
            saveAccounts()
        }
    }

    // MARK: - Account Management

    public func addPlexAccount(_ account: PlexAccountConfig) {
        // Replace if same account ID already exists
        plexAccounts.removeAll { $0.id == account.id }
        plexAccounts.append(account)
        saveAccounts()
    }

    public func removePlexAccount(id: String) {
        // Clear cached API clients for this account
        plexAccounts.first(where: { $0.id == id })?.servers.forEach { server in
            clearAPIClientCache(accountId: id, serverId: server.id)
        }
        plexAccounts.removeAll { $0.id == id }
        saveAccounts()
    }

    public func updatePlexAccount(_ account: PlexAccountConfig) {
        if let index = plexAccounts.firstIndex(where: { $0.id == account.id }) {
            // NOTE: We intentionally do NOT clear the API client cache here.
            // Clearing the cache invalidates existing references held by providers,
            // causing them to use stale URLs when building stream requests.
            // The cached API client's currentServerURL is updated separately by
            // SyncCoordinator.refreshAPIClientConnections() after health checks.
            plexAccounts[index] = account
            saveAccounts()
        }
    }

    public func removeMusicSource(_ sourceId: MusicSourceIdentifier) {
        guard let accountIndex = plexAccounts.firstIndex(where: { $0.id == sourceId.accountId }),
              let serverIndex = plexAccounts[accountIndex].servers.firstIndex(where: { $0.id == sourceId.serverId }),
              let libraryIndex = plexAccounts[accountIndex].servers[serverIndex].libraries.firstIndex(where: { $0.key == sourceId.libraryId }) else {
            return
        }
        
        let account = plexAccounts[accountIndex]
        let server = account.servers[serverIndex]
        
        // Create new library with isEnabled = false
        var updatedLibraries = server.libraries
        updatedLibraries[libraryIndex] = PlexLibraryConfig(
            id: updatedLibraries[libraryIndex].id,
            key: updatedLibraries[libraryIndex].key,
            title: updatedLibraries[libraryIndex].title,
            isEnabled: false,
            allowSync: updatedLibraries[libraryIndex].allowSync
        )

        // Create new server with updated libraries
        var updatedServers = account.servers
        updatedServers[serverIndex] = PlexServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: server.connections,
            token: server.token,
            platform: server.platform,
            capabilities: server.capabilities,
            libraries: updatedLibraries
        )

        // Create new account with updated servers
        plexAccounts[accountIndex] = PlexAccountConfig(
            id: account.id,
            email: account.email,
            plexUsername: account.plexUsername,
            displayTitle: account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: account.subscription,
            servers: updatedServers
        )

        saveAccounts()
    }

    /// Updates enabled state for a single server library in an account.
    @discardableResult
    public func setLibraryEnabled(
        accountId: String,
        serverId: String,
        libraryKey: String,
        isEnabled: Bool
    ) -> Bool {
        guard let accountIndex = plexAccounts.firstIndex(where: { $0.id == accountId }),
              let serverIndex = plexAccounts[accountIndex].servers.firstIndex(where: { $0.id == serverId }),
              let libraryIndex = plexAccounts[accountIndex].servers[serverIndex].libraries.firstIndex(where: { $0.key == libraryKey }) else {
            return false
        }

        let account = plexAccounts[accountIndex]
        let server = account.servers[serverIndex]
        let library = server.libraries[libraryIndex]

        guard library.isEnabled != isEnabled else {
            return true
        }

        var updatedLibraries = server.libraries
        updatedLibraries[libraryIndex] = PlexLibraryConfig(
            id: library.id,
            key: library.key,
            title: library.title,
            isEnabled: isEnabled,
            allowSync: library.allowSync
        )

        var updatedServers = account.servers
        updatedServers[serverIndex] = PlexServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: server.connections,
            token: server.token,
            platform: server.platform,
            capabilities: server.capabilities,
            libraries: updatedLibraries
        )

        plexAccounts[accountIndex] = PlexAccountConfig(
            id: account.id,
            email: account.email,
            plexUsername: account.plexUsername,
            displayTitle: account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: account.subscription,
            servers: updatedServers
        )

        saveAccounts()
        return true
    }

    // MARK: - Source Enumeration

    /// Returns all enabled MusicSourceIdentifiers across all accounts
    public func enabledSources() -> [MusicSourceIdentifier] {
        var sources: [MusicSourceIdentifier] = []
        for account in plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    sources.append(MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    ))
                }
            }
        }
        return sources
    }

    /// Returns all enabled sources as MusicSource domain objects (without live status)
    public func enabledMusicSources() -> [MusicSource] {
        var sources: [MusicSource] = []
        for account in plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    let identifier = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    )
                    sources.append(MusicSource(
                        id: identifier,
                        displayName: "\(server.name) - \(library.title)",
                        accountName: account.accountIdentifier,
                        sourceType: .plex
                    ))
                }
            }
        }
        return sources
    }

    /// Resolves a server name from a sourceCompositeKey (format: "plex:accountId:serverId:libraryId").
    /// Returns the server's friendly name, or nil if not found.
    public func serverName(for sourceCompositeKey: String) -> String? {
        let parts = sourceCompositeKey.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        let accountId = String(parts[1])
        let serverId = String(parts[2])

        guard let account = plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            return nil
        }
        return server.name
    }

    /// Whether any sources are configured
    public var hasAnySources: Bool {
        !plexAccounts.isEmpty
    }

    /// Create or retrieve cached PlexAPIClient for a specific server
    public func makeAPIClient(accountId: String, serverId: String) -> PlexAPIClient? {
        let cacheKey = "\(accountId):\(serverId)"

        // Return cached client if available (no log — called frequently)
        if let cachedClient = apiClientCache[cacheKey] {
            return cachedClient
        }

        guard let account = plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            EnsembleLogger.debug("❌ makeAPIClient: account/server not found — accountId:\(accountId) serverId:\(serverId)")
            return nil
        }

        EnsembleLogger.debug("🔄 makeAPIClient: Creating new client for \(server.name) (\(server.url))")

        let insecurePolicy = currentAllowInsecureConnectionsPolicy()
        let orderedConnections = policyFilteredConnections(
            from: server.orderedConnections,
            allowInsecure: insecurePolicy
        )

        let endpointDescriptors = orderedConnections.map { connection in
            PlexEndpointDescriptor(
                url: connection.uri,
                local: connection.local,
                relay: connection.relay ?? false,
                secure: connection.protocol == "https"
            )
        }

        let primaryURL = endpointDescriptors.first?.url ?? server.url
        let alternativeURLs = endpointDescriptors
            .map(\.url)
            .filter { $0 != primaryURL }
        let connection = PlexServerConnection(
            url: primaryURL,
            alternativeURLs: alternativeURLs,
            endpoints: endpointDescriptors,
            selectionPolicy: .plexSpecBalanced,
            allowInsecurePolicy: insecurePolicy,
            token: server.token,
            identifier: server.id,
            name: server.name
        )

        let client = PlexAPIClient(
            connection: connection,
            keychain: keychain,
            connectionRegistry: connectionRegistry,
            serverKey: cacheKey
        )
        apiClientCache[cacheKey] = client
        return client
    }

    /// Clear the API client cache (useful when accounts/servers are removed or reconfigured)
    public func clearAPIClientCache() {
        apiClientCache.removeAll()
    }

    /// Clear cache for a specific server
    public func clearAPIClientCache(accountId: String, serverId: String) {
        let cacheKey = "\(accountId):\(serverId)"
        apiClientCache.removeValue(forKey: cacheKey)
    }

    /// Remove accounts with expired auth tokens.
    @discardableResult
    public func enforceAuthTokenPolicy() -> Bool {
        let now = Date()
        let validAccounts = plexAccounts.filter { account in
            let metadata = account.authTokenMetadata ?? PlexAuthService.tokenMetadata(from: account.authToken)
            return !metadata.isExpired(now: now)
        }

        if validAccounts.count == plexAccounts.count {
            return false
        }

        EnsembleLogger.debug(
            "🔐 AccountManager: Removed \(plexAccounts.count - validAccounts.count) account(s) with expired auth tokens"
        )
        plexAccounts = validAccounts
        clearAPIClientCache()
        saveAccounts()
        return true
    }

    private func currentAllowInsecureConnectionsPolicy() -> AllowInsecureConnectionsPolicy {
        let raw = UserDefaults.standard.string(forKey: "allowInsecureConnectionsPolicy")
        return AllowInsecureConnectionsPolicy(rawValue: raw ?? "") ?? .defaultForEnsemble
    }

    private func policyFilteredConnections(
        from connections: [PlexConnectionConfig],
        allowInsecure: AllowInsecureConnectionsPolicy
    ) -> [PlexConnectionConfig] {
        let filtered = connections.filter { connection in
            let isSecure = connection.protocol == "https" || connection.uri.lowercased().hasPrefix("https://")
            guard !isSecure else { return true }
            switch allowInsecure {
            case .always:
                return true
            case .never:
                return false
            case .sameNetwork:
                return connection.local
            }
        }

        // Guard against policy lockout when only insecure endpoints are returned.
        if filtered.isEmpty {
            return connections
        }
        return filtered
    }

    private func applyAuthMigrationIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let previousVersion = defaults.integer(forKey: Self.authMigrationVersionKey)
        guard previousVersion < Self.authMigrationVersion else {
            return false
        }

        EnsembleLogger.debug(
            "🔐 AccountManager: Applying auth migration v\(Self.authMigrationVersion) (previous: \(previousVersion)); forcing re-login"
        )
        try? keychain.delete(KeychainKey.plexAccounts)
        plexAccounts = []
        clearAPIClientCache()
        defaults.set(Self.authMigrationVersion, forKey: Self.authMigrationVersionKey)
        return true
    }
}
