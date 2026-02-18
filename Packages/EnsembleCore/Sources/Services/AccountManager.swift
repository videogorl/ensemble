import Combine
import EnsembleAPI
import Foundation

/// Manages connected music source accounts (Plex, future Apple Music, etc.)
@MainActor
public final class AccountManager: ObservableObject {
    @Published public private(set) var plexAccounts: [PlexAccountConfig] = []

    private let keychain: KeychainServiceProtocol
    private var apiClientCache: [String: PlexAPIClient] = [:]  // Cache by "accountId:serverId"

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    // MARK: - Load / Save

    public func loadAccounts() {
        guard let json = try? keychain.get(KeychainKey.plexAccounts),
              let data = json.data(using: .utf8) else {
            plexAccounts = []
            return
        }

        plexAccounts = (try? JSONDecoder().decode([PlexAccountConfig].self, from: data)) ?? []
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
            username: account.username,
            authToken: account.authToken,
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
                        accountName: account.username,
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
        print("🔄 AccountManager.makeAPIClient() called")
        print("  - Account ID: \(accountId)")
        print("  - Server ID: \(serverId)")
        #endif
        
        let cacheKey = "\(accountId):\(serverId)"

        // Return cached client if available
        if let cachedClient = apiClientCache[cacheKey] {
            #if DEBUG
            print("✅ Returning cached API client")
            #endif
            return cachedClient
        }
        
        #if DEBUG
        print("🔄 Creating new API client...")
        print("  - Looking for account with ID: \(accountId)")
        #endif
        guard let account = plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            #if DEBUG
            print("❌ Could not find account or server")
            print("  - Accounts available: \(plexAccounts.count)")
            #endif
            if let account = plexAccounts.first(where: { $0.id == accountId }) {
                #if DEBUG
                print("  - Account found, but server not found. Servers available: \(account.servers.count)")
                #endif
            }
            return nil
        }

        #if DEBUG
        print("✅ Found account and server")
        print("  - Server name: \(server.name)")
        print("  - Server URL: \(server.url)")
        #endif

        // Get all connection URLs from server config, excluding the primary URL
        let alternativeURLs = server.orderedConnections
            .map { $0.uri }
            .filter { $0 != server.url }
        #if DEBUG
        print("  - Alternative URLs available: \(alternativeURLs.count)")
        #endif

        let connection = PlexServerConnection(
            url: server.url,
            alternativeURLs: alternativeURLs,
            token: server.token,
            identifier: server.id,
            name: server.name
        )

        let client = PlexAPIClient(connection: connection, keychain: keychain)
        apiClientCache[cacheKey] = client
        #if DEBUG
        print("✅ API client created and cached")
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
}
