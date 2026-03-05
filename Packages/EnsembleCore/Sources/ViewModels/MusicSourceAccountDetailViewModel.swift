import Combine
import Foundation

/// Drives account-level source management, including library selection and sync status display.
@MainActor
public final class MusicSourceAccountDetailViewModel: ObservableObject {
    public struct ServerSection: Identifiable, Equatable {
        public let id: String
        public let serverName: String
        public let serverPlatform: String?
        public let libraries: [LibraryRow]

        public init(id: String, serverName: String, serverPlatform: String?, libraries: [LibraryRow]) {
            self.id = id
            self.serverName = serverName
            self.serverPlatform = serverPlatform
            self.libraries = libraries
        }
    }

    public struct LibraryRow: Identifiable, Equatable {
        public var id: String { sourceIdentifier.compositeKey }

        public let sourceIdentifier: MusicSourceIdentifier
        public let title: String
        public let isEnabled: Bool
        public let status: MusicSourceStatus?

        public init(
            sourceIdentifier: MusicSourceIdentifier,
            title: String,
            isEnabled: Bool,
            status: MusicSourceStatus?
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.title = title
            self.isEnabled = isEnabled
            self.status = status
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
    private let mutationCoordinator: MutationCoordinator
    private let webSocketCoordinator: PlexWebSocketCoordinator
    private var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
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
        webSocketCoordinator: PlexWebSocketCoordinator
    ) {
        self.accountId = accountId
        self.accountManager = accountManager
        self.accountDiscoveryService = accountDiscoveryService
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.webSocketCoordinator = webSocketCoordinator

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
            }
            .store(in: &cancellables)

        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.sourceStatuses = statuses
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        rebuildSections()
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

    /// Triggers sync for all currently enabled libraries in this account.
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

        let enabledSources = account.servers.flatMap { server in
            server.libraries.compactMap { library -> MusicSourceIdentifier? in
                guard library.isEnabled else { return nil }
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

        for source in enabledSources {
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
                        isEnabled: existingLibrary?.isEnabled ?? false
                    )
                }

                if let existingServer {
                    for removedLibrary in existingServer.libraries where !discoveredKeys.contains(removedLibrary.key) {
                        guard removedLibrary.isEnabled else { continue }
                        removedSources.insert(
                            MusicSourceIdentifier(
                                type: .plex,
                                accountId: account.id,
                                serverId: existingServer.id,
                                libraryId: removedLibrary.key
                            )
                        )
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
                    platform: discoveredServer.platform,
                    libraries: resolvedLibraries
                )
            )
        }

        // Servers no longer present in discovery are considered removed.
        for existingServer in account.servers where !discoveredServerIDs.contains(existingServer.id) {
            for library in existingServer.libraries where library.isEnabled {
                removedSources.insert(
                    MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: existingServer.id,
                        libraryId: library.key
                    )
                )
            }
            serversNeedingPlaylistCleanup.insert(ServerKey(accountId: account.id, serverId: existingServer.id))
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
                    status: status
                )
            }

            return ServerSection(
                id: server.id,
                serverName: server.name,
                serverPlatform: server.platform,
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
}
