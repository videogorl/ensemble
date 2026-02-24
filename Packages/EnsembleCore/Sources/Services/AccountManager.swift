import Combine
import EnsembleAPI
import Foundation

/// Manages connected music source accounts (Plex, future Apple Music, etc.)
@MainActor
public final class AccountManager: ObservableObject {
    @Published public private(set) var plexAccounts: [PlexAccountConfig] = []

    private let keychain: KeychainServiceProtocol
    private var apiClientCache: [String: PlexAPIClient] = [:]  // Cache by "accountId:serverId"
    private static let authMigrationVersionKey = "plex_auth_migration_version"
    private static let authMigrationVersion = 2

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
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
            // Clear cached API clients for this account's servers
            account.servers.forEach { server in
                clearAPIClientCache(accountId: account.id, serverId: server.id)
            }
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
            isEnabled: false
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
            servers: updatedServers
        )
        
        saveAccounts()
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

    /// Whether any sources are configured
    public var hasAnySources: Bool {
        !plexAccounts.isEmpty
    }

    /// Create or retrieve cached PlexAPIClient for a specific server
    public func makeAPIClient(accountId: String, serverId: String) -> PlexAPIClient? {
        #if DEBUG
        EnsembleLogger.debug("🔄 AccountManager.makeAPIClient() called")
        EnsembleLogger.debug("  - Account ID: \(accountId)")
        EnsembleLogger.debug("  - Server ID: \(serverId)")
        #endif
        
        let cacheKey = "\(accountId):\(serverId)"

        // Return cached client if available
        if let cachedClient = apiClientCache[cacheKey] {
            #if DEBUG
            EnsembleLogger.debug("✅ Returning cached API client")
            #endif
            return cachedClient
        }
        
        #if DEBUG
        EnsembleLogger.debug("🔄 Creating new API client...")
        EnsembleLogger.debug("  - Looking for account with ID: \(accountId)")
        #endif
        guard let account = plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            #if DEBUG
            EnsembleLogger.debug("❌ Could not find account or server")
            EnsembleLogger.debug("  - Accounts available: \(plexAccounts.count)")
            #endif
            if let account = plexAccounts.first(where: { $0.id == accountId }) {
                #if DEBUG
                EnsembleLogger.debug("  - Account found, but server not found. Servers available: \(account.servers.count)")
                #endif
            }
            return nil
        }

        #if DEBUG
        EnsembleLogger.debug("✅ Found account and server")
        EnsembleLogger.debug("  - Server name: \(server.name)")
        EnsembleLogger.debug("  - Server URL: \(server.url)")
        #endif

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
        #if DEBUG
        EnsembleLogger.debug("  - Connection policy: \(insecurePolicy.rawValue)")
        EnsembleLogger.debug("  - Alternative URLs available: \(alternativeURLs.count)")
        #endif

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

        let client = PlexAPIClient(connection: connection, keychain: keychain)
        apiClientCache[cacheKey] = client
        #if DEBUG
        EnsembleLogger.debug("✅ API client created and cached")
        #endif
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

        #if DEBUG
        EnsembleLogger.debug(
            "🔐 AccountManager: Removed \(plexAccounts.count - validAccounts.count) account(s) with expired auth tokens"
        )
        #endif
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

        #if DEBUG
        EnsembleLogger.debug(
            "🔐 AccountManager: Applying auth migration v\(Self.authMigrationVersion) (previous: \(previousVersion)); forcing re-login"
        )
        #endif
        try? keychain.delete(KeychainKey.plexAccounts)
        plexAccounts = []
        clearAPIClientCache()
        defaults.set(Self.authMigrationVersion, forKey: Self.authMigrationVersionKey)
        return true
    }
}
