import Combine
import EnsemblePersistence
import Foundation

/// Drives account-level source management, including library selection and sync status display.
@MainActor
public final class MusicSourceAccountDetailViewModel: ObservableObject {
    public struct ServerSection: Identifiable, Equatable {
        public let id: String
        public let serverName: String
        public let serverPlatform: String?
        public let capabilities: PlexServerCapabilities?
        public let hasPlexPass: Bool
        public let plexPassSupport: PlexFeatureSupport
        public let lyricsSupport: PlexFeatureSupport
        public let radioSupport: PlexFeatureSupport
        public let libraries: [LibraryRow]

        public init(
            id: String,
            serverName: String,
            serverPlatform: String?,
            capabilities: PlexServerCapabilities? = nil,
            hasPlexPass: Bool = false,
            plexPassSupport: PlexFeatureSupport? = nil,
            lyricsSupport: PlexFeatureSupport? = nil,
            radioSupport: PlexFeatureSupport? = nil,
            libraries: [LibraryRow]
        ) {
            self.id = id
            self.serverName = serverName
            self.serverPlatform = serverPlatform
            self.capabilities = capabilities
            self.plexPassSupport = plexPassSupport ?? (hasPlexPass ? .supported : capabilities?.plexPassSupport ?? .unknown)
            self.lyricsSupport = lyricsSupport ?? capabilities?.lyricsSupport ?? .unknown
            self.radioSupport = radioSupport ?? capabilities?.radioSupport ?? .unknown
            self.hasPlexPass = self.plexPassSupport.isSupported
            self.libraries = libraries
        }
    }

    public struct LibraryRow: Identifiable, Equatable {
        public var id: String { sourceIdentifier.compositeKey }

        public let sourceIdentifier: MusicSourceIdentifier
        public let title: String
        public let isEnabled: Bool
        public let status: MusicSourceStatus?
        public let allowSync: Bool?
        public let expectedTrackCount: Int?
        public let syncedTrackCount: Int?

        public init(
            sourceIdentifier: MusicSourceIdentifier,
            title: String,
            isEnabled: Bool,
            status: MusicSourceStatus?,
            allowSync: Bool? = nil,
            expectedTrackCount: Int? = nil,
            syncedTrackCount: Int? = nil
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.title = title
            self.isEnabled = isEnabled
            self.status = status
            self.allowSync = allowSync
            self.expectedTrackCount = expectedTrackCount
            self.syncedTrackCount = syncedTrackCount
        }
    }

    @Published public private(set) var accountIdentifier: String = ""
    @Published public private(set) var sections: [ServerSection] = []
    @Published public private(set) var isSyncingEnabledLibraries = false
    @Published public private(set) var isRefreshingInventory = false
    @Published public private(set) var isRemovingAccount = false
    @Published public private(set) var isAccountMissing = false
    @Published public private(set) var isReauthenticationRequired = false
    @Published public private(set) var serverLibraryErrors: [String: String] = [:]
    @Published public private(set) var error: String?
    /// Number of pending offline mutations waiting to be replayed when connectivity resumes.
    @Published public private(set) var pendingMutationCount: Int = 0
    /// Active library scan progress for servers in this account (0-100), nil if no scan active.
    @Published public private(set) var scanProgressByServer: [String: Int] = [:]

    private let accountId: String
    private let accountManager: AccountManager
    private let accountDiscoveryService: any PlexAccountDiscoveryServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: any LibraryRepositoryProtocol
    private var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    private var syncedTrackCounts: [MusicSourceIdentifier: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var hasPerformedInitialRefresh = false
    private var activeLibraryOperations = Set<String>()
    internal var syncSourcesHandlerForTesting: (([MusicSourceIdentifier]) async -> Void)?

    public var hasEnabledLibraries: Bool {
        sections.contains { section in
            section.libraries.contains(where: \.isEnabled)
        }
    }

    public init(
        accountId: String,
        accountManager: AccountManager,
        accountDiscoveryService: any PlexAccountDiscoveryServiceProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        webSocketCoordinator: PlexWebSocketCoordinator,
        libraryRepository: any LibraryRepositoryProtocol
    ) {
        self.accountId = accountId
        self.accountManager = accountManager
        self.accountDiscoveryService = accountDiscoveryService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository

        // Subscribe to library scan progress from WebSocket events
        webSocketCoordinator.$serverScanProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progressMap in
                guard let self else { return }
                // Filter to servers belonging to this account, keyed by serverId only
                let accountPrefix = "\(accountId):"
                var relevant: [String: Int] = [:]
                for (key, value) in progressMap where key.hasPrefix(accountPrefix) {
                    let serverId = String(key.dropFirst(accountPrefix.count))
                    relevant[serverId] = value
                }
                self.scanProgressByServer = relevant
            }
            .store(in: &cancellables)

        // Mirror the global pending mutation count so the view can show sync status
        mutationCoordinator.$pendingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.pendingMutationCount = count
            }
            .store(in: &cancellables)

        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
                self?.refreshSyncedTrackCounts()
            }
            .store(in: &cancellables)

        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                guard let self else { return }
                let previousStatuses = self.sourceStatuses
                self.sourceStatuses = statuses
                self.rebuildSections()
                if Self.shouldRefreshSyncedTrackCounts(previous: previousStatuses, next: statuses) {
                    self.refreshSyncedTrackCounts()
                }
            }
            .store(in: &cancellables)

        rebuildSections()
        refreshSyncedTrackCounts()
    }

    public func performInitialRefreshIfNeeded() async {
        guard !hasPerformedInitialRefresh else { return }
        hasPerformedInitialRefresh = true
        await refreshAccountInventory()
    }

    /// Manually refreshes discovered servers/libraries for this account.
    public func refreshAvailableLibraries() async {
        await refreshAccountInventory()
    }

    /// Toggles whether a single library is enabled for syncing under this account.
    public func toggleLibrary(_ row: LibraryRow) async {
        error = nil

        guard !isReauthenticationRequired else {
            error = "Session expired. Re-authenticate this account."
            return
        }

        guard !activeLibraryOperations.contains(row.id) else { return }
        activeLibraryOperations.insert(row.id)
        defer { activeLibraryOperations.remove(row.id) }

        let nextEnabledState = !row.isEnabled
        let didUpdate = accountManager.setLibraryEnabled(
            accountId: row.sourceIdentifier.accountId,
            serverId: row.sourceIdentifier.serverId,
            libraryKey: row.sourceIdentifier.libraryId,
            isEnabled: nextEnabledState
        )

        guard didUpdate else {
            error = "Could not update library selection."
            return
        }

        if nextEnabledState {
            syncCoordinator.refreshProviders()
            await syncSources([row.sourceIdentifier])
            return
        }

        if !nextEnabledState {
            // Disabling a library purges only that library's cached data.
            EnsembleLogger.info(
                "[SourceReconciliation] Cleanup requested source=\(row.sourceIdentifier.compositeKey) reason=local-library-disabled"
            )
            await syncCoordinator.cleanupRemovedSource(row.sourceIdentifier)

            // If this was the final enabled library for the server, purge server-level playlists.
            if !hasEnabledLibraries(accountId: row.sourceIdentifier.accountId, serverId: row.sourceIdentifier.serverId) {
                await syncCoordinator.cleanupServerPlaylists(
                    accountId: row.sourceIdentifier.accountId,
                    serverId: row.sourceIdentifier.serverId
                )
            }
        }

        syncCoordinator.refreshProviders()
    }

    /// Forces a full sync for all currently enabled libraries in this account.
    public func syncEnabledLibraries() async {
        guard !isSyncingEnabledLibraries else { return }

        guard !isReauthenticationRequired else {
            error = "Session expired. Re-authenticate this account."
            return
        }

        let enabledSources = sections
            .flatMap(\.libraries)
            .filter(\.isEnabled)
            .map(\.sourceIdentifier)

        guard !enabledSources.isEmpty else {
            error = "Enable at least one library to sync."
            return
        }

        error = nil
        isSyncingEnabledLibraries = true
        defer { isSyncingEnabledLibraries = false }

        await syncSources(enabledSources)
    }

    /// Removes this account and purges all server/library data tied to it.
    @discardableResult
    public func removeSourceAccount() async -> Bool {
        guard !isRemovingAccount else { return false }
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
            isAccountMissing = true
            return false
        }

        isRemovingAccount = true
        error = nil
        defer { isRemovingAccount = false }

        let accountSources = account.servers.flatMap { server in
            server.libraries.compactMap { library -> MusicSourceIdentifier? in
                return MusicSourceIdentifier(
                    type: .plex,
                    accountId: account.id,
                    serverId: server.id,
                    libraryId: library.key
                )
            }
        }
        let serverIDs = account.servers.map(\.id)

        accountManager.removePlexAccount(id: account.id)

        for source in accountSources {
            EnsembleLogger.info(
                "[SourceReconciliation] Cleanup requested source=\(source.compositeKey) reason=account-removed"
            )
            await syncCoordinator.cleanupRemovedSource(source)
        }

        for serverID in serverIDs {
            await syncCoordinator.cleanupServerPlaylists(accountId: account.id, serverId: serverID)
        }

        syncCoordinator.refreshProviders()
        isAccountMissing = true
        sections = []
        return true
    }

    private func refreshAccountInventory() async {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
            isAccountMissing = true
            return
        }

        let metadata = account.authTokenMetadata ?? PlexAuthService.tokenMetadata(from: account.authToken)
        if metadata.isExpired() {
            isReauthenticationRequired = true
            error = "Session expired. Re-authenticate this account."
            return
        }
        isReauthenticationRequired = false

        // Keep cached inventory visible and avoid destructive reconciliation when offline.
        guard !syncCoordinator.isOffline else {
            EnsembleLogger.info(
                "[SourceReconciliation] Preserving cached sources account=\(accountId) reason=device-offline"
            )
            return
        }

        isRefreshingInventory = true
        defer { isRefreshingInventory = false }

        do {
            let discovery = try await accountDiscoveryService.discoverAccount(authToken: account.authToken)
            guard !Task.isCancelled else { return }
            serverLibraryErrors = discovery.serverLibraryErrors
            guard let latestAccount = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
                isAccountMissing = true
                return
            }
            await reconcileAccountConfiguration(existing: latestAccount, discovery: discovery)
        } catch is CancellationError {
            // Ignore cancellation when user leaves the screen mid-refresh.
            return
        } catch {
            EnsembleLogger.info(
                "[SourceReconciliation] Preserving cached sources account=\(accountId) reason=account-discovery-failed error=\(error.localizedDescription)"
            )
            self.error = error.localizedDescription
        }

        // Trigger a fresh server health check so library connection statuses
        // reflect actual connectivity, not stale cached states.
        syncCoordinator.refreshServerHealthStates()
    }

    private func syncSources(_ sources: [MusicSourceIdentifier]) async {
        if let syncSourcesHandlerForTesting {
            await syncSourcesHandlerForTesting(sources)
        } else {
            await syncCoordinator.sync(sources: sources)
        }
    }

    private func reconcileAccountConfiguration(
        existing account: PlexAccountConfig,
        discovery: PlexAccountDiscoveryResult
    ) async {
        struct ServerKey: Hashable {
            let accountId: String
            let serverId: String
        }

        let existingServersById = Dictionary(uniqueKeysWithValues: account.servers.map { ($0.id, $0) })
        let discoveredServerIDs = Set(discovery.servers.map(\.id))
        var updatedServers: [PlexServerConfig] = []
        var removedSources = Set<MusicSourceIdentifier>()
        var serversNeedingPlaylistCleanup = Set<ServerKey>()

        for discoveredServer in discovery.servers {
            let existingServer = existingServersById[discoveredServer.id]
            let hasLibraryError = discovery.serverLibraryErrors[discoveredServer.id] != nil
            let resolvedLibraries: [PlexLibraryConfig]

            if hasLibraryError, let existingServer {
                // Partial failure: keep existing libraries unchanged for this server.
                EnsembleLogger.info(
                    "[SourceReconciliation] Preserving cached libraries server=\(existingServer.id) count=\(existingServer.libraries.count) reason=library-fetch-failed"
                )
                resolvedLibraries = existingServer.libraries
            } else {
                let existingLibrariesByKey = Dictionary(uniqueKeysWithValues: (existingServer?.libraries ?? []).map { ($0.key, $0) })
                let discoveredKeys = Set(discoveredServer.libraries.map(\.key))

                resolvedLibraries = discoveredServer.libraries.map { discoveredLibrary in
                    let existingLibrary = existingLibrariesByKey[discoveredLibrary.key]
                    return PlexLibraryConfig(
                        id: discoveredLibrary.id,
                        key: discoveredLibrary.key,
                        title: discoveredLibrary.title,
                        isEnabled: existingLibrary?.isEnabled ?? false,
                        allowSync: discoveredLibrary.allowSync,
                        trackCount: discoveredLibrary.trackCount ?? existingLibrary?.trackCount
                    )
                }

                if let existingServer {
                    for removedLibrary in existingServer.libraries where !discoveredKeys.contains(removedLibrary.key) {
                        let removedSource = MusicSourceIdentifier(
                            type: .plex,
                            accountId: account.id,
                            serverId: existingServer.id,
                            libraryId: removedLibrary.key
                        )
                        EnsembleLogger.info(
                            "[SourceReconciliation] Cleanup requested source=\(removedSource.compositeKey) reason=absent-from-successful-plex-inventory"
                        )
                        removedSources.insert(removedSource)
                    }
                }
            }

            updatedServers.append(
                PlexServerConfig(
                    id: discoveredServer.id,
                    name: discoveredServer.name,
                    url: discoveredServer.url,
                    connections: discoveredServer.connections,
                    token: discoveredServer.token,
                    owned: discoveredServer.owned,
                    platform: discoveredServer.platform,
                    capabilities: discoveredServer.capabilities ?? existingServer?.capabilities,
                    libraries: resolvedLibraries
                )
            )
        }

        // A Plex resources refresh can omit servers that are temporarily offline or
        // unreachable. Preserve cached server/library rows until the user explicitly
        // removes the account or disables a library.
        for existingServer in account.servers where !discoveredServerIDs.contains(existingServer.id) {
            EnsembleLogger.info(
                "[SourceReconciliation] Preserving cached server=\(existingServer.id) libraries=\(existingServer.libraries.count) reason=server-omitted-from-resources"
            )
            updatedServers.append(existingServer)
        }

        let updatedServersById = Dictionary(uniqueKeysWithValues: updatedServers.map { ($0.id, $0) })
        for removedSource in removedSources {
            let key = ServerKey(accountId: removedSource.accountId, serverId: removedSource.serverId)
            if let updatedServer = updatedServersById[removedSource.serverId] {
                if !updatedServer.libraries.contains(where: \.isEnabled) {
                    serversNeedingPlaylistCleanup.insert(key)
                }
            } else {
                serversNeedingPlaylistCleanup.insert(key)
            }
        }

        let updatedAccount = PlexAccountConfig(
            id: account.id,
            email: nonEmpty(discovery.identity.email) ?? account.email,
            plexUsername: nonEmpty(discovery.identity.plexUsername) ?? account.plexUsername,
            displayTitle: nonEmpty(discovery.identity.displayTitle) ?? account.displayTitle,
            authToken: account.authToken,
            authTokenMetadata: account.authTokenMetadata,
            subscription: discovery.subscription ?? account.subscription,
            servers: updatedServers
        )

        accountManager.updatePlexAccount(updatedAccount)
        syncCoordinator.refreshProviders()

        for source in removedSources {
            await syncCoordinator.cleanupRemovedSource(source)
        }

        for server in serversNeedingPlaylistCleanup {
            await syncCoordinator.cleanupServerPlaylists(accountId: server.accountId, serverId: server.serverId)
        }
    }

    private func rebuildSections() {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
            isAccountMissing = true
            isReauthenticationRequired = false
            accountIdentifier = "Plex"
            sections = []
            return
        }

        isAccountMissing = false
        let metadata = account.authTokenMetadata ?? PlexAuthService.tokenMetadata(from: account.authToken)
        isReauthenticationRequired = metadata.isExpired()
        accountIdentifier = account.accountIdentifier

        // Account-level Plex Pass from subscription
        let accountHasPlexPass = account.subscription?.active == true

        sections = account.servers.map { server in
            let libraries = server.libraries.map { library in
                let sourceIdentifier = MusicSourceIdentifier(
                    type: .plex,
                    accountId: account.id,
                    serverId: server.id,
                    libraryId: library.key
                )

                let status = library.isEnabled ? (sourceStatuses[sourceIdentifier] ?? MusicSourceStatus()) : nil

                return LibraryRow(
                    sourceIdentifier: sourceIdentifier,
                    title: library.title,
                    isEnabled: library.isEnabled,
                    status: status,
                    allowSync: library.allowSync,
                    expectedTrackCount: library.trackCount,
                    syncedTrackCount: syncedTrackCounts[sourceIdentifier]
                )
            }

            let serverPlexPassSupport: PlexFeatureSupport = accountHasPlexPass
                ? .supported
                : (server.capabilities?.plexPassSupport ?? .unknown)

            return ServerSection(
                id: server.id,
                serverName: server.name,
                serverPlatform: server.platform,
                capabilities: server.capabilities,
                plexPassSupport: serverPlexPassSupport,
                lyricsSupport: server.capabilities?.lyricsSupport ?? .unknown,
                radioSupport: server.capabilities?.radioSupport ?? .unknown,
                libraries: libraries
            )
        }
    }

    private func hasEnabledLibraries(accountId: String, serverId: String) -> Bool {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            return false
        }
        return server.libraries.contains(where: \.isEnabled)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func refreshSyncedTrackCounts() {
        let sources = currentLibrarySourceIdentifiers()
        guard !sources.isEmpty else {
            if !syncedTrackCounts.isEmpty {
                syncedTrackCounts = [:]
                rebuildSections()
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            var nextCounts: [MusicSourceIdentifier: Int] = [:]
            for source in sources {
                if let count = try? await libraryRepository.countTracks(forSource: source.compositeKey) {
                    nextCounts[source] = count
                }
            }
            guard !Task.isCancelled else { return }
            if nextCounts != self.syncedTrackCounts {
                self.syncedTrackCounts = nextCounts
                self.rebuildSections()
            }
        }
    }

    private func currentLibrarySourceIdentifiers() -> [MusicSourceIdentifier] {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
            return []
        }
        return account.servers.flatMap { server in
            server.libraries.map { library in
                MusicSourceIdentifier(
                    type: .plex,
                    accountId: account.id,
                    serverId: server.id,
                    libraryId: library.key
                )
            }
        }
    }

    private static func shouldRefreshSyncedTrackCounts(
        previous: [MusicSourceIdentifier: MusicSourceStatus],
        next: [MusicSourceIdentifier: MusicSourceStatus]
    ) -> Bool {
        for (source, status) in next {
            guard case .lastSynced(let date) = status.syncStatus else { continue }
            guard case .lastSynced(let previousDate)? = previous[source]?.syncStatus,
                  previousDate == date else {
                return true
            }
        }
        return false
    }
}
