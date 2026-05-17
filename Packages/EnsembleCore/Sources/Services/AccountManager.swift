import Combine
import EnsembleAPI
import Foundation

/// Manages connected music source accounts (Plex, future Apple Music, etc.)
@MainActor
public final class AccountManager: ObservableObject {
    private struct LibraryFlagEntry: Codable, Equatable, Sendable {
        let key: String
        let isEnabled: Bool
        let updatedAt: TimeInterval?
        let originDeviceID: String?

        init(
            key: String,
            isEnabled: Bool,
            updatedAt: TimeInterval? = nil,
            originDeviceID: String? = nil
        ) {
            self.key = key
            self.isEnabled = isEnabled
            self.updatedAt = updatedAt
            self.originDeviceID = originDeviceID
        }
    }

    public struct ServerPlaylistCleanup: Hashable, Sendable {
        public let accountId: String
        public let serverId: String

        public init(accountId: String, serverId: String) {
            self.accountId = accountId
            self.serverId = serverId
        }
    }

    public struct LibraryFlagApplicationResult: Sendable {
        public let enabledSources: [MusicSourceIdentifier]
        public let disabledSources: [MusicSourceIdentifier]
        public let serversNeedingPlaylistCleanup: [ServerPlaylistCleanup]

        public init(
            enabledSources: [MusicSourceIdentifier] = [],
            disabledSources: [MusicSourceIdentifier] = [],
            serversNeedingPlaylistCleanup: [ServerPlaylistCleanup] = []
        ) {
            self.enabledSources = enabledSources
            self.disabledSources = disabledSources
            self.serversNeedingPlaylistCleanup = serversNeedingPlaylistCleanup
        }

        public var hasChanges: Bool {
            !enabledSources.isEmpty || !disabledSources.isEmpty || !serversNeedingPlaylistCleanup.isEmpty
        }
    }

    @Published public private(set) var plexAccounts: [PlexAccountConfig] = []
    @Published public private(set) var isAwaitingCloudSources = false

    private let keychain: KeychainServiceProtocol
    private let connectionRegistry: ServerConnectionRegistry?
    private var apiClientCache: [String: PlexAPIClient] = [:]  // Cache by "accountId:serverId"
    private var syncedLibraryFlagEntries: [String: LibraryFlagEntry] = [:]
    private var libraryFlagModifiedAt: [String: TimeInterval]
    private let libraryFlagOriginDeviceID: String
    private static let authMigrationVersionKey = "plex_auth_migration_version"
    private static let authMigrationVersion = 2
    private static let libraryFlagModifiedAtKey = "sync.libraryFlagModifiedAt"
    private static let libraryFlagOriginDeviceIDKey = "sync.libraryFlagOriginDeviceID"

    public init(keychain: KeychainServiceProtocol, connectionRegistry: ServerConnectionRegistry? = nil) {
        self.keychain = keychain
        self.connectionRegistry = connectionRegistry
        self.libraryFlagModifiedAt = Self.loadLibraryFlagModifiedAt()
        self.libraryFlagOriginDeviceID = Self.loadOrCreateLibraryFlagOriginDeviceID()
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

    /// Tracks whether first-connect source hydration is still waiting on iCloud.
    public func setAwaitingCloudSources(_ awaiting: Bool) {
        guard isAwaitingCloudSources != awaiting else { return }
        isAwaitingCloudSources = awaiting
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(plexAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.save(json, forKey: KeychainKey.plexAccounts)
        SiriMediaIndexNotifications.postRebuildRequest(reason: "account_configuration_changed")

        // Push stripped credentials to iCloud Keychain for cross-device sync
        pushSyncCredentials()
    }

    /// Persist accounts to keychain without pushing to iCloud sync.
    /// Used when applying remote changes to avoid echo loops and cascading reloads.
    private func saveAccountsFromSync() {
        guard let data = try? JSONEncoder().encode(plexAccounts),
              let json = String(data: data, encoding: .utf8) else { return }
        try? keychain.save(json, forKey: KeychainKey.plexAccounts)
    }

    // MARK: - iCloud Keychain Sync

    /// Callback invoked when synced credentials arrive with new account IDs
    /// not present locally. DependencyContainer wires this to account discovery.
    public var onNewAccountsFromSync: (([SyncableAccountCredential]) -> Void)?

    /// Push current account credentials (stripped of connections) to iCloud Keychain.
    /// Guarded — silently skips if encoding or keychain write fails.
    private func pushSyncCredentials() {
        let syncable = canonicalSyncCredentials()
        guard let data = try? JSONEncoder().encode(syncable),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try keychain.saveSynchronizable(json, forKey: KeychainKey.plexAccountsSync)
        } catch {
            EnsembleLogger.error("Failed to push sync credentials to iCloud Keychain: \(error)")
        }
    }

    /// Whether iCloud Keychain already contains a non-empty synced account payload.
    public func hasSyncedCloudCredentials() -> Bool {
        guard let synced = loadSyncedCredentials() else { return false }
        return !synced.isEmpty
    }

    /// Seed iCloud Keychain from local accounts when this device is the first sync participant.
    public func seedCloudSyncCredentialsFromLocal() {
        guard hasAnySources else { return }
        pushSyncCredentials()
    }

    /// Pull credentials from iCloud Keychain and compare them against local accounts.
    /// Returns remote credentials that need discovery or re-discovery on this device.
    public func pullSyncCredentials() -> [SyncableAccountCredential] {
        guard let synced = loadSyncedCredentials() else {
            return []
        }

        let localAccountsById = Dictionary(uniqueKeysWithValues: plexAccounts.map { ($0.id, $0) })
        return synced.filter { credential in
            guard let localAccount = localAccountsById[credential.accountId] else {
                return true
            }
            return requiresSyncReconciliation(localAccount: localAccount, remoteCredential: credential)
        }
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

        guard !shouldSuppressLibraryFlagsDuringFirstConnect(flags) else {
            EnsembleLogger.debug("Sync library flags: skipped local export while first-connect source discovery is unsettled")
            return nil
        }

        let entries = flags.keys.sorted().map { key in
            LibraryFlagEntry(
                key: key,
                isEnabled: flags[key] ?? false,
                updatedAt: ensureLibraryFlagModifiedAt(for: key),
                originDeviceID: libraryFlagOriginDeviceID
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entries)
    }

    /// Apply synced library flags from iCloud KVS.
    /// Stores the latest remote flag map even if the matching libraries do not exist yet.
    /// Returns a change-set so callers can trigger cleanup and refresh side effects.
    @discardableResult
    public func applyLibraryFlags(_ data: Data) -> LibraryFlagApplicationResult {
        guard let entriesByKey = decodeLibraryFlagEntries(from: data) else {
            return LibraryFlagApplicationResult()
        }
        let flags = entriesByKey.mapValues(\.isEnabled)

        guard !shouldSuppressLibraryFlagsDuringFirstConnect(flags) else {
            EnsembleLogger.debug("Sync library flags: ignored empty/all-disabled remote payload while first-connect source discovery is unsettled")
            return LibraryFlagApplicationResult()
        }

        guard !shouldSuppressAllDisabledRemoteLibraryFlags(entriesByKey) else {
            EnsembleLogger.info(
                "Sync library flags: ignored all-disabled remote payload while local libraries are enabled"
            )
            return LibraryFlagApplicationResult()
        }

        syncedLibraryFlagEntries = entriesByKey

        var didChange = false
        var enabledSources: [MusicSourceIdentifier] = []
        var disabledSources: [MusicSourceIdentifier] = []
        var serversNeedingPlaylistCleanup = Set<ServerPlaylistCleanup>()

        for i in plexAccounts.indices {
            for j in plexAccounts[i].servers.indices {
                let server = plexAccounts[i].servers[j]
                var updatedLibraries = server.libraries
                var serverChanged = false
                let hadEnabledLibrariesBefore = server.libraries.contains(where: \.isEnabled)

                for k in updatedLibraries.indices {
                    let key = libraryFlagKey(
                        accountId: plexAccounts[i].id,
                        serverId: server.id,
                        libraryKey: updatedLibraries[k].key
                    )
                    guard let remoteEntry = entriesByKey[key] else { continue }
                    guard shouldApplyRemoteLibraryFlag(remoteEntry) else {
                        EnsembleLogger.debug(
                            "Sync library flags: ignored stale remote flag for \(key)"
                        )
                        continue
                    }

                    recordRemoteLibraryFlagTimestamp(remoteEntry)

                    if updatedLibraries[k].isEnabled != remoteEntry.isEnabled {
                        let sourceId = MusicSourceIdentifier(
                            type: .plex,
                            accountId: plexAccounts[i].id,
                            serverId: server.id,
                            libraryId: updatedLibraries[k].key
                        )
                        if remoteEntry.isEnabled {
                            enabledSources.append(sourceId)
                        } else {
                            disabledSources.append(sourceId)
                        }
                        updatedLibraries[k] = PlexLibraryConfig(
                            id: updatedLibraries[k].id,
                            key: updatedLibraries[k].key,
                            title: updatedLibraries[k].title,
                            isEnabled: remoteEntry.isEnabled,
                            allowSync: updatedLibraries[k].allowSync
                        )
                        serverChanged = true
                    }
                }

                if serverChanged {
                    let hasEnabledLibrariesAfter = updatedLibraries.contains(where: \.isEnabled)
                    if hadEnabledLibrariesBefore && !hasEnabledLibrariesAfter {
                        serversNeedingPlaylistCleanup.insert(
                            ServerPlaylistCleanup(
                                accountId: plexAccounts[i].id,
                                serverId: server.id
                            )
                        )
                    }
                    var updatedServers = plexAccounts[i].servers
                    updatedServers[j] = PlexServerConfig(
                        id: server.id,
                        name: server.name,
                        url: server.url,
                        connections: server.connections,
                        token: server.token,
                        owned: server.owned,
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
            saveAccountsFromSync()
        }

        return LibraryFlagApplicationResult(
            enabledSources: enabledSources,
            disabledSources: disabledSources,
            serversNeedingPlaylistCleanup: Array(serversNeedingPlaylistCleanup)
        )
    }

    /// Apply the most recently received synced library flags to a discovered account
    /// before it is persisted locally. This preserves remote library selection across
    /// first-connect flows where account discovery finishes after the KVS payload arrives.
    public func applyingSyncedLibraryFlags(to account: PlexAccountConfig) -> PlexAccountConfig {
        guard !syncedLibraryFlagEntries.isEmpty else { return account }

        let existingLibrariesByKey = localLibrariesByFlagKey(for: account.id)

        let updatedServers = account.servers.map { server in
            let updatedLibraries = server.libraries.map { library in
                let key = libraryFlagKey(accountId: account.id, serverId: server.id, libraryKey: library.key)
                guard let remoteEntry = syncedLibraryFlagEntries[key] else { return library }
                guard shouldApplyCachedRemoteLibraryFlag(remoteEntry, existingLibrary: existingLibrariesByKey[key]) else {
                    return library
                }
                guard library.isEnabled != remoteEntry.isEnabled else { return library }
                return PlexLibraryConfig(
                    id: library.id,
                    key: library.key,
                    title: library.title,
                    isEnabled: remoteEntry.isEnabled,
                    allowSync: library.allowSync
                )
            }
            return PlexServerConfig(
                id: server.id,
                name: server.name,
                url: server.url,
                connections: server.connections,
                token: server.token,
                owned: server.owned,
                platform: server.platform,
                capabilities: server.capabilities,
                libraries: updatedLibraries
            )
        }

        return PlexAccountConfig(
            id: account.id,
            email: account.email,
            plexUsername: account.plexUsername,
            displayTitle: account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: account.subscription,
            servers: updatedServers
        )
    }

    /// Apply the library selection embedded in synced source credentials.
    /// This is a bootstrap fallback for new devices before the dedicated KVS
    /// library-flags payload has arrived.
    public func applyingCredentialLibrarySelection(
        to account: PlexAccountConfig,
        credential: SyncableAccountCredential
    ) -> PlexAccountConfig {
        var credentialFlags: [String: Bool] = [:]
        for server in credential.servers {
            for library in server.libraries {
                let key = libraryFlagKey(
                    accountId: credential.accountId,
                    serverId: server.serverId,
                    libraryKey: library.key
                )
                credentialFlags[key] = library.isEnabled
            }
        }

        guard !credentialFlags.isEmpty else { return account }

        let updatedServers = account.servers.map { server in
            let updatedLibraries = server.libraries.map { library in
                let key = libraryFlagKey(accountId: account.id, serverId: server.id, libraryKey: library.key)
                guard let credentialEnabled = credentialFlags[key] else { return library }
                guard library.isEnabled != credentialEnabled else { return library }
                return PlexLibraryConfig(
                    id: library.id,
                    key: library.key,
                    title: library.title,
                    isEnabled: credentialEnabled,
                    allowSync: library.allowSync
                )
            }
            return PlexServerConfig(
                id: server.id,
                name: server.name,
                url: server.url,
                connections: server.connections,
                token: server.token,
                owned: server.owned,
                platform: server.platform,
                capabilities: server.capabilities,
                libraries: updatedLibraries
            )
        }

        return PlexAccountConfig(
            id: account.id,
            email: account.email,
            plexUsername: account.plexUsername,
            displayTitle: account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: account.subscription,
            servers: updatedServers
        )
    }

    // MARK: - Account Management

    public func addPlexAccount(_ account: PlexAccountConfig) {
        let resolvedAccount = applyingSyncedLibraryFlags(to: preservingExistingLibrarySelection(in: account))
        // Replace if same account ID already exists
        plexAccounts.removeAll { $0.id == resolvedAccount.id }
        plexAccounts.append(resolvedAccount)
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
        let resolvedAccount = applyingSyncedLibraryFlags(to: account)
        if let index = plexAccounts.firstIndex(where: { $0.id == resolvedAccount.id }) {
            // NOTE: We intentionally do NOT clear the API client cache here.
            // Clearing the cache invalidates existing references held by providers,
            // causing them to use stale URLs when building stream requests.
            // The cached API client's currentServerURL is updated separately by
            // SyncCoordinator.refreshAPIClientConnections() after health checks.
            plexAccounts[index] = resolvedAccount
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
        recordLocalLibraryFlagMutation(
            accountId: account.id,
            serverId: server.id,
            libraryKey: updatedLibraries[libraryIndex].key
        )

        // Create new server with updated libraries
        var updatedServers = account.servers
        updatedServers[serverIndex] = PlexServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: server.connections,
            token: server.token,
            owned: server.owned,
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
        recordLocalLibraryFlagMutation(
            accountId: accountId,
            serverId: serverId,
            libraryKey: libraryKey
        )

        var updatedServers = account.servers
        updatedServers[serverIndex] = PlexServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: server.connections,
            token: server.token,
            owned: server.owned,
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

        let sourceId = MusicSourceIdentifier(
            type: .plex,
            accountId: accountId,
            serverId: serverId,
            libraryId: libraryKey
        )
        EnsembleLogger.info(
            "AccountManager: library selection changed source=\(sourceId.compositeKey) enabled=\(isEnabled)"
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

    /// Returns all disabled MusicSourceIdentifiers across all accounts.
    public func disabledSources() -> [MusicSourceIdentifier] {
        var sources: [MusicSourceIdentifier] = []
        for account in plexAccounts {
            for server in account.servers {
                for library in server.libraries where !library.isEnabled {
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
        let hasStoredMigrationVersion = defaults.object(forKey: Self.authMigrationVersionKey) != nil
        let previousVersion = defaults.integer(forKey: Self.authMigrationVersionKey)
        guard previousVersion < Self.authMigrationVersion else {
            return false
        }

        // A true fresh install has no stored account payload yet. In that case
        // there is nothing to migrate, so mark the migration as satisfied and
        // let iCloud-synced accounts hydrate normally.
        if !hasStoredMigrationVersion,
           (try? keychain.get(KeychainKey.plexAccounts)) == nil {
            defaults.set(Self.authMigrationVersion, forKey: Self.authMigrationVersionKey)
            EnsembleLogger.debug(
                "🔐 AccountManager: Marked auth migration v\(Self.authMigrationVersion) complete on fresh install"
            )
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

    private func libraryFlagKey(accountId: String, serverId: String, libraryKey: String) -> String {
        "\(accountId):\(serverId):\(libraryKey)"
    }

    private func shouldSuppressLibraryFlagsDuringFirstConnect(_ flags: [String: Bool]) -> Bool {
        guard isAwaitingCloudSources else { return false }
        return flags.isEmpty || flags.values.allSatisfy { !$0 }
    }

    private func shouldSuppressAllDisabledRemoteLibraryFlags(_ entriesByKey: [String: LibraryFlagEntry]) -> Bool {
        guard !entriesByKey.isEmpty, entriesByKey.values.allSatisfy({ !$0.isEnabled }) else { return false }

        let hasLocalEnabledLibrary = plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
        guard hasLocalEnabledLibrary else { return false }

        return entriesByKey.values.allSatisfy { entry in
            guard let remoteTimestamp = entry.updatedAt else { return true }
            return remoteTimestamp <= (libraryFlagModifiedAt[entry.key] ?? 0)
        }
    }

    private func shouldApplyRemoteLibraryFlag(_ entry: LibraryFlagEntry) -> Bool {
        guard let remoteTimestamp = entry.updatedAt else { return true }
        return remoteTimestamp >= (libraryFlagModifiedAt[entry.key] ?? 0)
    }

    private func shouldApplyCachedRemoteLibraryFlag(
        _ entry: LibraryFlagEntry,
        existingLibrary: PlexLibraryConfig?
    ) -> Bool {
        if let remoteTimestamp = entry.updatedAt {
            return remoteTimestamp >= (libraryFlagModifiedAt[entry.key] ?? 0)
        }

        // Untimestamped flags are legacy bootstrap hints. They are valid for a
        // newly discovered account, but an existing local library selection is
        // more trustworthy during later server/account refreshes.
        return existingLibrary == nil && libraryFlagModifiedAt[entry.key] == nil
    }

    private func recordRemoteLibraryFlagTimestamp(_ entry: LibraryFlagEntry) {
        guard let remoteTimestamp = entry.updatedAt else { return }
        guard remoteTimestamp >= (libraryFlagModifiedAt[entry.key] ?? 0) else { return }
        libraryFlagModifiedAt[entry.key] = remoteTimestamp
        saveLibraryFlagModifiedAt()
    }

    private func recordLocalLibraryFlagMutation(accountId: String, serverId: String, libraryKey: String) {
        let key = libraryFlagKey(accountId: accountId, serverId: serverId, libraryKey: libraryKey)
        libraryFlagModifiedAt[key] = Date().timeIntervalSince1970
        saveLibraryFlagModifiedAt()
    }

    private func ensureLibraryFlagModifiedAt(for key: String) -> TimeInterval {
        if let timestamp = libraryFlagModifiedAt[key] {
            return timestamp
        }
        let timestamp = Date().timeIntervalSince1970
        libraryFlagModifiedAt[key] = timestamp
        saveLibraryFlagModifiedAt()
        return timestamp
    }

    private func preservingExistingLibrarySelection(in account: PlexAccountConfig) -> PlexAccountConfig {
        let existingLibrariesByKey = localLibrariesByFlagKey(for: account.id)
        guard !existingLibrariesByKey.isEmpty else { return account }

        var didChange = false
        let updatedServers = account.servers.map { server in
            let updatedLibraries = server.libraries.map { library in
                let key = libraryFlagKey(accountId: account.id, serverId: server.id, libraryKey: library.key)
                guard let existingLibrary = existingLibrariesByKey[key],
                      existingLibrary.isEnabled != library.isEnabled else {
                    return library
                }

                didChange = true
                return PlexLibraryConfig(
                    id: library.id,
                    key: library.key,
                    title: library.title,
                    isEnabled: existingLibrary.isEnabled,
                    allowSync: library.allowSync
                )
            }

            guard updatedLibraries != server.libraries else { return server }
            return PlexServerConfig(
                id: server.id,
                name: server.name,
                url: server.url,
                connections: server.connections,
                token: server.token,
                owned: server.owned,
                platform: server.platform,
                capabilities: server.capabilities,
                libraries: updatedLibraries
            )
        }

        guard didChange else { return account }
        return PlexAccountConfig(
            id: account.id,
            email: account.email,
            plexUsername: account.plexUsername,
            displayTitle: account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: account.subscription,
            servers: updatedServers
        )
    }

    private func localLibrariesByFlagKey(for accountId: String) -> [String: PlexLibraryConfig] {
        guard let existingAccount = plexAccounts.first(where: { $0.id == accountId }) else {
            return [:]
        }

        var librariesByKey: [String: PlexLibraryConfig] = [:]
        for server in existingAccount.servers {
            for library in server.libraries {
                let key = libraryFlagKey(accountId: existingAccount.id, serverId: server.id, libraryKey: library.key)
                librariesByKey[key] = library
            }
        }
        return librariesByKey
    }

    private func saveLibraryFlagModifiedAt() {
        guard let data = try? JSONEncoder().encode(libraryFlagModifiedAt) else { return }
        UserDefaults.standard.set(data, forKey: Self.libraryFlagModifiedAtKey)
    }

    private static func loadLibraryFlagModifiedAt() -> [String: TimeInterval] {
        guard let data = UserDefaults.standard.data(forKey: libraryFlagModifiedAtKey),
              let timestamps = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return timestamps
    }

    private static func loadOrCreateLibraryFlagOriginDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: libraryFlagOriginDeviceIDKey) {
            return existing
        }
        let deviceID = UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: libraryFlagOriginDeviceIDKey)
        return deviceID
    }

    private func requiresSyncReconciliation(
        localAccount: PlexAccountConfig,
        remoteCredential: SyncableAccountCredential
    ) -> Bool {
        if localAccount.email != remoteCredential.email
            || localAccount.plexUsername != remoteCredential.plexUsername
            || localAccount.displayTitle != remoteCredential.displayTitle
            || localAccount.authToken != remoteCredential.authToken {
            return true
        }

        let localServersById = Dictionary(uniqueKeysWithValues: localAccount.servers.map { ($0.id, $0) })
        let remoteServerIDs = Set(remoteCredential.servers.map(\.serverId))
        if Set(localServersById.keys) != remoteServerIDs {
            return true
        }

        for remoteServer in remoteCredential.servers {
            guard let localServer = localServersById[remoteServer.serverId] else {
                return true
            }
            if localServer.name != remoteServer.serverName || localServer.token != remoteServer.serverToken {
                return true
            }

            let localLibrariesByKey = Dictionary(uniqueKeysWithValues: localServer.libraries.map { ($0.key, $0) })
            let remoteLibraryKeys = Set(remoteServer.libraries.map(\.key))
            if Set(localLibrariesByKey.keys) != remoteLibraryKeys {
                return true
            }

            for remoteLibrary in remoteServer.libraries {
                guard let localLibrary = localLibrariesByKey[remoteLibrary.key] else {
                    return true
                }
                if localLibrary.id != remoteLibrary.id || localLibrary.title != remoteLibrary.title {
                    return true
                }
            }
        }

        return false
    }

    private func loadSyncedCredentials() -> [SyncableAccountCredential]? {
        guard let json = try? keychain.getSynchronizable(KeychainKey.plexAccountsSync),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([SyncableAccountCredential].self, from: data)
    }

    private func canonicalSyncCredentials() -> [SyncableAccountCredential] {
        plexAccounts
            .sorted { $0.id < $1.id }
            .map { account in
                SyncableAccountCredential(
                    accountId: account.id,
                    email: account.email,
                    plexUsername: account.plexUsername,
                    displayTitle: account.displayTitle,
                    authToken: account.authToken,
                    servers: account.servers
                        .sorted { $0.id < $1.id }
                        .map { server in
                            SyncableServerCredential(
                                serverId: server.id,
                                serverName: server.name,
                                serverToken: server.token,
                                libraries: server.libraries
                                    .sorted { lhs, rhs in
                                        let lhsKey = "\(lhs.key):\(lhs.id)"
                                        let rhsKey = "\(rhs.key):\(rhs.id)"
                                        return lhsKey < rhsKey
                                    }
                                    .map { SyncableLibraryRef(from: $0) }
                            )
                        }
                )
            }
    }

    private func decodeLibraryFlagEntries(from data: Data) -> [String: LibraryFlagEntry]? {
        if let entries = try? JSONDecoder().decode([LibraryFlagEntry].self, from: data) {
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        }
        guard let flags = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return nil
        }
        return Dictionary(
            uniqueKeysWithValues: flags.map { key, isEnabled in
                (key, LibraryFlagEntry(key: key, isEnabled: isEnabled))
            }
        )
    }
}
