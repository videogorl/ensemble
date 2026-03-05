import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Strategy for performing a sync operation
public enum SyncStrategy {
    /// Sync only items added/updated since last sync (fast)
    case incremental
    /// Sync all items from server (slow, comprehensive)
    case full
    /// Sync only hub data (Recently Added, etc.) - very fast
    case hubsOnly
}

public struct PlaylistMutationResult: Sendable {
    public let addedCount: Int
    public let skippedCount: Int

    public init(addedCount: Int, skippedCount: Int) {
        self.addedCount = addedCount
        self.skippedCount = skippedCount
    }
}

public enum PlaylistMutationError: LocalizedError, Equatable {
    case invalidSource
    case playlistNotFound
    case smartPlaylistReadOnly
    case emptySelection
    case duplicateName

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Could not determine a valid Plex server for this action."
        case .playlistNotFound:
            return "Playlist not found."
        case .smartPlaylistReadOnly:
            return "Smart playlists are read-only."
        case .emptySelection:
            return "No compatible tracks were selected."
        case .duplicateName:
            return "A playlist with that name already exists on this server."
        }
    }
}

/// Coordinates syncing across all configured music sources
@MainActor
public final class SyncCoordinator: ObservableObject {
    /// Posted after server playlists are refreshed (e.g. after a mutation).
    /// The notification's `userInfo` contains `["serverSourceKey": String]`.
    public static let playlistsDidRefresh = Notification.Name("SyncCoordinatorPlaylistsDidRefresh")

    private enum NetworkTransition {
        case reconnect
        case interfaceSwitch(from: NetworkType, to: NetworkType)
        case disconnect
        case none
    }

    private enum HealthRefreshReason: Equatable {
        case networkReconnect
        case interfaceSwitch(from: NetworkType, to: NetworkType)
        case appForeground
        case accountInventoryRefresh

        var description: String {
            switch self {
            case .networkReconnect:
                return "network_reconnect"
            case .interfaceSwitch(let from, let to):
                return "interface_switch(\(from.description)->\(to.description))"
            case .appForeground:
                return "app_foreground"
            case .accountInventoryRefresh:
                return "account_inventory_refresh"
            }
        }
    }

    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false
    @Published public private(set) var isOffline = false
    @Published public private(set) var lastPlaylistTarget: LastPlaylistTarget?
    /// Published when health checks complete so dependent services can react.
    @Published public private(set) var lastHealthCheckCompletion: Date?

    public let accountManager: AccountManager
    public let networkMonitor: NetworkMonitor
    public let serverHealthChecker: ServerHealthChecker
    public let connectionRegistry: ServerConnectionRegistry?
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private var syncProviders: [String: MusicSourceSyncProvider] = [:]  // keyed by compositeKey
    private var cancellables = Set<AnyCancellable>()
    private var isCheckingHealth = false
    private var lastObservedNetworkState: NetworkState?
    private var lastHealthRefreshAt: Date?
    private var activeHealthRefreshTask: Task<Void, Never>?
    private let healthRefreshCooldown: TimeInterval = 30
    private let foregroundHealthStalenessThreshold: TimeInterval = 60
    private var registrySubscriptionTask: Task<Void, Never>?
    
    // Periodic sync timers
    private var incrementalSyncTimer: Timer?
    private var lastIncrementalSyncTime: Date?
    private let incrementalSyncInterval: TimeInterval = 60 * 60  // 1 hour
    private static let lastPlaylistIdKey = "NowPlaying.LastPlaylist.ID"
    private static let lastPlaylistTitleKey = "NowPlaying.LastPlaylist.Title"
    private static let lastPlaylistSourceKey = "NowPlaying.LastPlaylist.SourceKey"
    private static let lastPlaylistTargetsByServerKey = "NowPlaying.LastPlaylist.ByServer"
    private var lastPlaylistTargetsByServer: [String: LastPlaylistTarget]
    internal var playlistDeleteHandlerForTesting: ((PlexAPIClient, String) async throws -> Void)?
    internal var refreshServerPlaylistsHandlerForTesting: ((String) async -> Void)?
    internal var nowProviderForTesting: () -> Date = { Date() }
    // Debounced playlist sync after rating changes (for smart playlist freshness)
    private var postRatingPlaylistSyncTasks: [String: Task<Void, Never>] = [:]

    /// Closure called when API client connections are refreshed (e.g., after network change).
    /// Used by ArtworkLoader to invalidate stale URL cache entries.
    public var onConnectionsRefreshed: (() async -> Void)?
    /// Signal fired when a server-level playlist refresh completes.
    public var onPlaylistRefreshCompleted: ((String) -> Void)?
    internal var healthCheckRunnerForTesting: ((Bool, Set<String>) async -> ServerHealthChecker.CheckSummary)?
    internal var refreshAPIClientConnectionsRunnerForTesting: (() async -> Void)?

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        networkMonitor: NetworkMonitor,
        serverHealthChecker: ServerHealthChecker,
        connectionRegistry: ServerConnectionRegistry? = nil
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.networkMonitor = networkMonitor
        self.serverHealthChecker = serverHealthChecker
        self.connectionRegistry = connectionRegistry
        self.lastPlaylistTargetsByServer = Self.loadLastPlaylistTargetsByServer()
        self.lastPlaylistTarget = Self.loadLastPlaylistTarget()

        // Observe network state changes
        setupNetworkMonitoring()

        // Subscribe to centralized endpoint changes from the registry
        if let registry = connectionRegistry {
            subscribeToRegistryChanges(registry: registry)
        }
    }

    /// Rebuild sync providers from current account configuration
    public func refreshProviders() {
        syncProviders.removeAll()

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                for library in server.libraries where library.isEnabled {
                    let sourceId = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    )

                    let provider = PlexMusicSourceSyncProvider(
                        sourceIdentifier: sourceId,
                        apiClient: apiClient,
                        sectionKey: library.key
                    )

                    syncProviders[sourceId.compositeKey] = provider

                    // Initialize status with last sync timestamp if available
                    if sourceStatuses[sourceId] == nil {
                        Task {
                            let syncStatus: MusicSourceStatus.SyncStatus
                            if let lastSyncDate = await loadLastSyncDate(for: sourceId) {
                                syncStatus = .lastSynced(lastSyncDate)
                            } else {
                                syncStatus = .idle
                            }
                            sourceStatuses[sourceId] = MusicSourceStatus(
                                syncStatus: syncStatus,
                                connectionState: .unknown
                            )
                        }
                    }
                }
            }
        }
    }

    /// Load the last sync date from CoreData
    private func loadLastSyncDate(for sourceId: MusicSourceIdentifier) async -> Date? {
        // Fetch from CoreData
        do {
            let sources = try await libraryRepository.fetchMusicSources()
            return sources.first(where: { $0.compositeKey == sourceId.compositeKey })?.lastSyncedAt
        } catch {
            return nil
        }
    }

    /// Sync all enabled sources
    public func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Clean up any duplicate playlists from previous syncs
        try? await playlistRepository.removeDuplicatePlaylists()
        
        // Track which servers have had their playlists synced
        var syncedServerKeys = Set<String>()

        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier
            let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
            
            sourceStatuses[sourceId] = MusicSourceStatus(
                syncStatus: .syncing(progress: 0),
                connectionState: currentConnectionState
            )

            do {
                // Sync library content (artists, albums, tracks, genres)
                try await provider.syncLibrary(
                    to: libraryRepository,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            guard let self = self else { return }
                            let connState = self.sourceStatuses[sourceId]?.connectionState ?? .unknown
                            // Library sync takes up 70% of the progress
                            self.sourceStatuses[sourceId] = MusicSourceStatus(
                                syncStatus: .syncing(progress: progress * 0.7),
                                connectionState: connState
                            )
                        }
                    }
                )
                
                // Pre-cache artwork for albums
                await cacheArtworkForSource(sourceId: sourceId, provider: provider)
                
                // Sync playlists once per server
                let serverKey = "\(sourceId.accountId):\(sourceId.serverId)"
                if !syncedServerKeys.contains(serverKey) {
                    syncedServerKeys.insert(serverKey)
                    try await provider.syncPlaylists(
                        to: playlistRepository,
                        progressHandler: { [weak self] progress in
                            Task { @MainActor in
                                guard let self = self else { return }
                                let connState = self.sourceStatuses[sourceId]?.connectionState ?? .unknown
                                // Playlist sync takes up the remaining 20%
                                self.sourceStatuses[sourceId] = MusicSourceStatus(
                                    syncStatus: .syncing(progress: 0.8 + (progress * 0.2)),
                                    connectionState: connState
                                )
                            }
                        }
                    )
                }
                
                let resolvedConnectionState = await connectionStateAfterSuccessfulSync(
                    for: sourceId,
                    fallback: currentConnectionState
                )
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .lastSynced(Date()),
                    connectionState: resolvedConnectionState
                )
                SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed")
            } catch {
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .error(syncErrorMessage(for: error)),
                    connectionState: currentConnectionState
                )
            }
        }
    }

    /// Sync a single source.
    public func sync(source: MusicSourceIdentifier) async {
        await syncSingleSource(source, publishGlobalSyncState: true)
    }

    /// Sync a scoped set of sources while publishing one global sync lifecycle.
    public func sync(sources: [MusicSourceIdentifier]) async {
        var uniqueSources: [MusicSourceIdentifier] = []
        var seenCompositeKeys = Set<String>()
        for source in sources where seenCompositeKeys.insert(source.compositeKey).inserted {
            uniqueSources.append(source)
        }
        guard !uniqueSources.isEmpty else { return }

        let shouldPublishGlobalSyncState = !isSyncing
        if shouldPublishGlobalSyncState {
            isSyncing = true
        }
        defer {
            if shouldPublishGlobalSyncState {
                isSyncing = false
            }
        }

        for source in uniqueSources {
            await syncSingleSource(source, publishGlobalSyncState: false)
        }
    }

    private func syncSingleSource(
        _ source: MusicSourceIdentifier,
        publishGlobalSyncState: Bool
    ) async {
        guard let provider = syncProviders[source.compositeKey] else { return }

        let shouldPublishGlobalSyncState = publishGlobalSyncState && !isSyncing
        if shouldPublishGlobalSyncState {
            isSyncing = true
        }
        defer {
            if shouldPublishGlobalSyncState {
                isSyncing = false
            }
        }

        let currentConnectionState = sourceStatuses[source]?.connectionState ?? .unknown
        sourceStatuses[source] = MusicSourceStatus(
            syncStatus: .syncing(progress: 0),
            connectionState: currentConnectionState
        )

        do {
            // Sync library content
            try await provider.syncLibrary(
                to: libraryRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let connState = self.sourceStatuses[source]?.connectionState ?? .unknown
                        // Library sync takes up 80% of the progress
                        self.sourceStatuses[source] = MusicSourceStatus(
                            syncStatus: .syncing(progress: progress * 0.8),
                            connectionState: connState
                        )
                    }
                }
            )

            // Sync playlists for this server
            try await provider.syncPlaylists(
                to: playlistRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let connState = self.sourceStatuses[source]?.connectionState ?? .unknown
                        // Playlist sync takes up the remaining 20%
                        self.sourceStatuses[source] = MusicSourceStatus(
                            syncStatus: .syncing(progress: 0.8 + (progress * 0.2)),
                            connectionState: connState
                        )
                    }
                }
            )

            let resolvedConnectionState = await connectionStateAfterSuccessfulSync(
                for: source,
                fallback: currentConnectionState
            )
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .lastSynced(Date()),
                connectionState: resolvedConnectionState
            )
            SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed")
        } catch {
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .error(syncErrorMessage(for: error)),
                connectionState: currentConnectionState
            )
        }
    }

    private func connectionStateAfterSuccessfulSync(
        for source: MusicSourceIdentifier,
        fallback: ServerConnectionState
    ) async -> ServerConnectionState {
        var resolvedURL: String?

        if let apiClient = accountManager.makeAPIClient(accountId: source.accountId, serverId: source.serverId) {
            let currentURL = await apiClient.getCurrentServerURL().trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentURL.isEmpty {
                resolvedURL = currentURL
            }
        }

        if resolvedURL == nil,
           let account = accountManager.plexAccounts.first(where: { $0.id == source.accountId }),
           let server = account.servers.first(where: { $0.id == source.serverId }) {
            let fallbackURL = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackURL.isEmpty {
                resolvedURL = fallbackURL
            }
        }

        guard let resolvedURL else {
            return fallback
        }

        if case .degraded = fallback {
            return .degraded(url: resolvedURL)
        }

        return .connected(url: resolvedURL)
    }

    private func syncErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.caseInsensitiveCompare("unknown") != .orderedSame else {
            return "Sync failed. Please try again."
        }
        return message
    }
    
    /// Sync all enabled sources incrementally (only fetch changes since last sync)
    public func syncAllIncremental() async {
        guard !isSyncing else {
            #if DEBUG
            EnsembleLogger.debug("⏳ syncAllIncremental: Already syncing, skipping")
            #endif
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        #if DEBUG
        EnsembleLogger.debug("🔄 syncAllIncremental: Starting...")
        #endif
        
        // Track which servers have had their playlists synced
        var syncedServerKeys = Set<String>()
        
        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier
            let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
            
            // Get last sync timestamp
            guard let lastSyncDate = await loadLastSyncDate(for: sourceId) else {
                // No previous sync - fall back to full sync
                #if DEBUG
                EnsembleLogger.debug("⚠️ No previous sync found for \(sourceId.compositeKey), performing full sync")
                #endif
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .syncing(progress: 0),
                    connectionState: currentConnectionState
                )
                
                do {
                    try await provider.syncLibrary(
                        to: libraryRepository,
                        progressHandler: { [weak self] progress in
                            Task { @MainActor in
                                guard let self = self else { return }
                                let connState = self.sourceStatuses[sourceId]?.connectionState ?? .unknown
                                self.sourceStatuses[sourceId] = MusicSourceStatus(
                                    syncStatus: .syncing(progress: progress * 0.9),
                                    connectionState: connState
                                )
                            }
                        }
                    )
                    
                    let resolvedConnectionState = await connectionStateAfterSuccessfulSync(
                        for: sourceId,
                        fallback: currentConnectionState
                    )
                    sourceStatuses[sourceId] = MusicSourceStatus(
                        syncStatus: .lastSynced(Date()),
                        connectionState: resolvedConnectionState
                    )
                    SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed")
                } catch {
                    sourceStatuses[sourceId] = MusicSourceStatus(
                        syncStatus: .error(syncErrorMessage(for: error)),
                        connectionState: currentConnectionState
                    )
                }
                continue
            }
            
            sourceStatuses[sourceId] = MusicSourceStatus(
                syncStatus: .syncing(progress: 0),
                connectionState: currentConnectionState
            )
            
            do {
                // Incremental sync library content
                let timestamp = lastSyncDate.timeIntervalSince1970
                try await provider.syncLibraryIncremental(
                    since: timestamp,
                    to: libraryRepository,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            guard let self = self else { return }
                            let connState = self.sourceStatuses[sourceId]?.connectionState ?? .unknown
                            self.sourceStatuses[sourceId] = MusicSourceStatus(
                                syncStatus: .syncing(progress: progress * 0.9),
                                connectionState: connState
                            )
                        }
                    }
                )
                
                // Sync playlists once per server (playlists are typically fast)
                let serverKey = "\(sourceId.accountId):\(sourceId.serverId)"
                if !syncedServerKeys.contains(serverKey) {
                    syncedServerKeys.insert(serverKey)
                    try await provider.syncPlaylists(
                        to: playlistRepository,
                        progressHandler: { [weak self] progress in
                            Task { @MainActor in
                                guard let self = self else { return }
                                let connState = self.sourceStatuses[sourceId]?.connectionState ?? .unknown
                                self.sourceStatuses[sourceId] = MusicSourceStatus(
                                    syncStatus: .syncing(progress: 0.9 + (progress * 0.1)),
                                    connectionState: connState
                                )
                            }
                        }
                    )
                }
                
                let resolvedConnectionState = await connectionStateAfterSuccessfulSync(
                    for: sourceId,
                    fallback: currentConnectionState
                )
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .lastSynced(Date()),
                    connectionState: resolvedConnectionState
                )
                SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed")
            } catch {
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .error(syncErrorMessage(for: error)),
                    connectionState: currentConnectionState
                )
            }
        }
    }
    
    /// Sync a single source incrementally (only fetch changes since last sync)
    public func syncIncremental(source: MusicSourceIdentifier) async {
        guard let provider = syncProviders[source.compositeKey] else { return }
        
        let currentConnectionState = sourceStatuses[source]?.connectionState ?? .unknown
        
        // Get last sync timestamp
        guard let lastSyncDate = await loadLastSyncDate(for: source) else {
            // No previous sync - fall back to full sync
            #if DEBUG
            EnsembleLogger.debug("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
            #endif
            await sync(source: source)
            return
        }
        
        sourceStatuses[source] = MusicSourceStatus(
            syncStatus: .syncing(progress: 0),
            connectionState: currentConnectionState
        )
        
        do {
            // Incremental sync library content
            let timestamp = lastSyncDate.timeIntervalSince1970
            try await provider.syncLibraryIncremental(
                since: timestamp,
                to: libraryRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let connState = self.sourceStatuses[source]?.connectionState ?? .unknown
                        self.sourceStatuses[source] = MusicSourceStatus(
                            syncStatus: .syncing(progress: progress * 0.9),
                            connectionState: connState
                        )
                    }
                }
            )
            
            // Sync playlists for this server
            try await provider.syncPlaylists(
                to: playlistRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let connState = self.sourceStatuses[source]?.connectionState ?? .unknown
                        self.sourceStatuses[source] = MusicSourceStatus(
                            syncStatus: .syncing(progress: 0.9 + (progress * 0.1)),
                            connectionState: connState
                        )
                    }
                }
            )
            
            let resolvedConnectionState = await connectionStateAfterSuccessfulSync(
                for: source,
                fallback: currentConnectionState
            )
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .lastSynced(Date()),
                connectionState: resolvedConnectionState
            )
            SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed")
        } catch {
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .error(syncErrorMessage(for: error)),
                connectionState: currentConnectionState
            )
        }
    }

    /// Sync only playlists incrementally (fast, no library sync)
    public func syncPlaylistsOnly() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Track which servers have been synced (playlists are server-level, not library-level)
        var syncedServerKeys = Set<String>()

        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier
            let serverKey = "\(sourceId.accountId):\(sourceId.serverId)"

            // Only sync once per server
            guard !syncedServerKeys.contains(serverKey) else { continue }
            syncedServerKeys.insert(serverKey)

            do {
                // Use incremental sync (falls back to full if never synced)
                try await provider.syncPlaylistsIncremental(
                    to: playlistRepository,
                    progressHandler: { _ in }
                )
                onPlaylistRefreshCompleted?("plex:\(sourceId.accountId):\(sourceId.serverId)")
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to sync playlists for server \(serverKey): \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Playlist Mutations

    /// Fetch playlists from local cache, optionally scoped to a specific server-level source key.
    public func fetchPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        let playlists = try await playlistRepository.fetchPlaylists(sourceCompositeKey: sourceKey)
        return playlists.map { Playlist(from: $0) }
    }

    /// Create a new playlist and immediately refresh local cache for that server.
    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        guard let server = parseServerSourceKey(serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlaylists = try await fetchPlaylists(forServerSourceKey: serverSourceKey)
        if existingPlaylists.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistMutationError.duplicateName
        }

        let filteredTrackIds = await filteredTrackIDsForServer(tracks: tracks, serverSourceKey: serverSourceKey)
        guard tracks.isEmpty || !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        guard let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        do {
            try await apiClient.createPlaylist(
                title: trimmed,
                trackRatingKeys: filteredTrackIds,
                serverIdentifier: server.serverId
            )
        } catch let error as PlexAPIError {
            guard tracks.isEmpty,
                  case .httpError(statusCode: 400) = error,
                  let seedTrackID = await seedTrackIDForServer(
                    serverSourceKey: serverSourceKey,
                    parsedServer: server,
                    apiClient: apiClient
                  ) else {
                throw error
            }

            #if DEBUG
            EnsembleLogger.debug("ℹ️ Empty playlist create returned 400; retrying with seed track fallback")
            #endif
            try await apiClient.createPlaylist(
                title: trimmed,
                trackRatingKeys: [seedTrackID],
                serverIdentifier: server.serverId
            )

            if let createdPlaylist = try? await apiClient.getPlaylists()
                .first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                try? await apiClient.clearPlaylistItems(playlistId: createdPlaylist.ratingKey)
            }
        }

        if let createdRemotePlaylist = try? await apiClient.getPlaylists()
            .first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            let isEmptyCreate = tracks.isEmpty
            _ = try? await playlistRepository.upsertPlaylist(
                ratingKey: createdRemotePlaylist.ratingKey,
                key: createdRemotePlaylist.key,
                title: createdRemotePlaylist.title,
                summary: createdRemotePlaylist.summary,
                compositePath: createdRemotePlaylist.composite,
                isSmart: createdRemotePlaylist.smart ?? false,
                duration: isEmptyCreate ? 0 : createdRemotePlaylist.duration,
                trackCount: isEmptyCreate ? 0 : createdRemotePlaylist.leafCount,
                dateAdded: createdRemotePlaylist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: createdRemotePlaylist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: createdRemotePlaylist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: serverSourceKey
            )
            if isEmptyCreate {
                try? await playlistRepository.setPlaylistTracks([], forPlaylist: createdRemotePlaylist.ratingKey, sourceCompositeKey: serverSourceKey)
            }

            persistLastPlaylistTarget(
                from: Playlist(
                    id: createdRemotePlaylist.ratingKey,
                    key: createdRemotePlaylist.key,
                    title: createdRemotePlaylist.title,
                    summary: createdRemotePlaylist.summary,
                    isSmart: createdRemotePlaylist.smart ?? false,
                    trackCount: isEmptyCreate ? 0 : (createdRemotePlaylist.leafCount ?? 0),
                    duration: TimeInterval(isEmptyCreate ? 0 : (createdRemotePlaylist.duration ?? 0)),
                    compositePath: createdRemotePlaylist.composite,
                    dateAdded: createdRemotePlaylist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    dateModified: createdRemotePlaylist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    lastPlayed: createdRemotePlaylist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    sourceCompositeKey: serverSourceKey
                )
            )
        } else if let createdPlaylist = try? await fetchPlaylists(forServerSourceKey: serverSourceKey)
            .first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            persistLastPlaylistTarget(from: createdPlaylist)
        }

        // Kick off cache refresh asynchronously so UI can return immediately.
        Task { [weak self] in
            await self?.refreshServerPlaylists(serverSourceKey: serverSourceKey)
        }

        let skippedCount = max(0, tracks.count - filteredTrackIds.count)
        return PlaylistMutationResult(addedCount: filteredTrackIds.count, skippedCount: skippedCount)
    }

    /// Add tracks to an existing playlist and refresh local cache for the playlist's server.
    public func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let serverSourceKey = playlist.sourceCompositeKey,
              let server = parseServerSourceKey(serverSourceKey),
              let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        let filteredTrackIds = await filteredTrackIDsForServer(tracks: tracks, serverSourceKey: serverSourceKey)
        guard !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        try await apiClient.addItemsToPlaylist(
            playlistId: playlist.id,
            trackRatingKeys: filteredTrackIds,
            serverIdentifier: server.serverId
        )

        // Keep the mutation path responsive; refresh cache in background.
        Task { [weak self] in
            await self?.refreshServerPlaylists(serverSourceKey: serverSourceKey)
        }

        persistLastPlaylistTarget(from: playlist)
        let skippedCount = max(0, tracks.count - filteredTrackIds.count)
        return PlaylistMutationResult(addedCount: filteredTrackIds.count, skippedCount: skippedCount)
    }

    /// Rename a playlist and refresh server playlists.
    public func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let serverSourceKey = playlist.sourceCompositeKey,
              let server = parseServerSourceKey(serverSourceKey),
              let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        let existingPlaylists = try await fetchPlaylists(forServerSourceKey: serverSourceKey)
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingPlaylists.contains(where: { $0.id != playlist.id && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistMutationError.duplicateName
        }

        try await apiClient.renamePlaylist(playlistId: playlist.id, newTitle: trimmed)
        await refreshServerPlaylists(serverSourceKey: serverSourceKey)
    }

    /// Delete a playlist and refresh server playlists.
    public func deletePlaylist(_ playlist: Playlist) async throws {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let serverSourceKey = playlist.sourceCompositeKey,
              let server = parseServerSourceKey(serverSourceKey),
              let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        if let playlistDeleteHandlerForTesting {
            try await playlistDeleteHandlerForTesting(apiClient, playlist.id)
        } else {
            try await apiClient.deletePlaylist(playlistId: playlist.id)
        }

        clearLastPlaylistTargetIfNeeded(deletedPlaylist: playlist)

        if let refreshServerPlaylistsHandlerForTesting {
            await refreshServerPlaylistsHandlerForTesting(serverSourceKey)
        } else {
            await refreshServerPlaylists(serverSourceKey: serverSourceKey)
        }
    }

    /// Replace playlist contents in the provided order and refresh local cache.
    public func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        guard !playlist.isSmart else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let serverSourceKey = playlist.sourceCompositeKey,
              let server = parseServerSourceKey(serverSourceKey),
              let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        let filteredTrackIds = await filteredTrackIDsForServer(tracks: orderedTracks, serverSourceKey: serverSourceKey)
        try await apiClient.clearPlaylistItems(playlistId: playlist.id)
        if !filteredTrackIds.isEmpty {
            try await apiClient.addItemsToPlaylist(
                playlistId: playlist.id,
                trackRatingKeys: filteredTrackIds,
                serverIdentifier: server.serverId
            )
        }

        await refreshServerPlaylists(serverSourceKey: serverSourceKey)
    }

    /// Save queue snapshot tracks to a playlist.
    public func saveQueueSnapshot(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        try await addTracksToPlaylist(tracks, playlist: playlist)
    }

    /// Perform appropriate sync on app startup based on staleness
    /// - If last full sync > 24 hours: full sync
    /// - If last sync > 1 hour: incremental sync
    /// - Otherwise: skip (data is fresh enough)
    public func performStartupSync() async {
        #if DEBUG
        EnsembleLogger.debug("🚀 Performing startup sync...")
        #endif
        
        // Don't sync if offline
        guard !isOffline else {
            #if DEBUG
            EnsembleLogger.debug("📴 Offline - skipping startup sync")
            #endif
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            #if DEBUG
            EnsembleLogger.debug("⏳ Sync already in progress - skipping startup sync")
            #endif
            return
        }
        
        // Check if we have any sources configured
        guard !syncProviders.isEmpty else {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ No sync providers configured - skipping startup sync")
            #endif
            return
        }
        
        // Determine sync strategy: full if >24h or never synced, incremental otherwise.
        // Always run at least an incremental sync on cold start so the user sees
        // changes made on other devices or via Plex Web since the last session.
        var needsFullSync = false

        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier

            if let lastSyncDate = await loadLastSyncDate(for: sourceId) {
                let hoursSinceSync = Date().timeIntervalSince(lastSyncDate) / 3600

                if hoursSinceSync > 24 {
                    #if DEBUG
                    EnsembleLogger.debug("⏰ Source \(sourceId.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs full sync")
                    #endif
                    needsFullSync = true
                    break
                }
            } else {
                #if DEBUG
                EnsembleLogger.debug("⏰ Source \(sourceId.compositeKey) has never been synced - needs full sync")
                #endif
                needsFullSync = true
                break
            }
        }

        if needsFullSync {
            #if DEBUG
            EnsembleLogger.debug("🔄 Starting full sync on startup...")
            #endif
            await syncAll()
        } else {
            #if DEBUG
            EnsembleLogger.debug("🔄 Starting incremental sync on startup...")
            #endif
            await syncAllIncremental()
        }
    }

    /// Ensure the server connection is ready for a given track
    /// This ensures we have a working connection URL before attempting playback
    public func ensureServerConnection(for track: Track) async throws {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }
        
        // Parse the composite key: format is "plex:accountId:serverId:libraryId"
        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            throw PlexAPIError.noServerSelected
        }
        
        let accountId = String(components[1])
        let serverId = String(components[2])
        
        // Check if we already have a connected state
        let currentState = serverHealthChecker.getServerState(accountId: accountId, serverId: serverId)

        #if DEBUG
        EnsembleLogger.debug("🎵 ensureServerConnection[v2]: current state for \(accountId):\(serverId) = \(currentState.description)")
        #endif
        
        // If already connected or degraded, we're good
        if case .connected = currentState {
            return
        }
        if case .degraded = currentState {
            return
        }
        
        // Need to check server health
        #if DEBUG
        EnsembleLogger.debug("🔍 Checking server connection before playback")
        #endif
        let newState = await serverHealthChecker.checkServer(
            accountId: accountId,
            serverId: serverId,
            forceRefresh: false
        )
        
        // Update the API client with the working URL
        switch newState {
        case .connected(let url), .degraded(let url):
            if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
                await apiClient.updateCurrentServerURL(url)
                #if DEBUG
                EnsembleLogger.debug("✅ Server connection ready for playback: \(url)")
                #endif
            }
        case .offline:
            #if DEBUG
            EnsembleLogger.debug("⚠️ Server health check reported offline for playback; attempting optimistic failover refresh")
            #endif
            if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
                let refreshResult = try? await apiClient.refreshConnection()
                #if DEBUG
                let refreshedURL = await apiClient.getCurrentServerURL()
                EnsembleLogger.debug(
                    "⚠️ ensureServerConnection[v2]: proceeding after refresh with URL host=\(hostForDebugURL(refreshedURL))"
                )
                if let refreshResult {
                    EnsembleLogger.debug(
                        "⚠️ ensureServerConnection[v2]: refresh outcome=\(refreshResult.outcome.rawValue) probes=\(refreshResult.probeCount)"
                    )
                }
                #endif
            }
            // Do not fail fast on health-check offline. Stream URL retrieval/playback
            // performs its own network path and can still succeed on slower paths.
            return
        case .connecting, .unknown:
            #if DEBUG
            EnsembleLogger.debug("⚠️ Server state uncertain, attempting playback anyway")
            #endif
        }
    }

    private func hostForDebugURL(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? "invalid"
    }

    public func serverFailureMessage(for track: Track) async -> String? {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            return nil
        }

        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            return nil
        }

        let accountId = String(components[1])
        let serverId = String(components[2])
        return serverHealthChecker.getServerFailureReason(accountId: accountId, serverId: serverId)?.userMessage
    }

    /// Proactively refreshes Plex server connections across configured accounts.
    /// Playback retry paths use this to recover from transient connection failures.
    public func refreshConnection() async throws {
        var refreshedAnyConnection = false
        var lastError: Error?

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }
                do {
                    let result = try await apiClient.refreshConnection()
                    refreshedAnyConnection = true
                    #if DEBUG
                    EnsembleLogger.debug(
                        "🔄 SyncCoordinator: Refreshed \(server.name) outcome=\(result.outcome.rawValue), probes=\(result.probeCount)"
                    )
                    #endif
                } catch {
                    lastError = error
                    #if DEBUG
                    EnsembleLogger.debug("⚠️ SyncCoordinator: Failed to refresh \(server.name): \(error.localizedDescription)")
                    #endif
                }
            }
        }

        guard refreshedAnyConnection else {
            throw lastError ?? PlexAPIError.noServerSelected
        }
    }
    
    /// Get the stream URL for a track, routing to the correct provider
    /// - Parameters:
    ///   - track: The track to stream
    ///   - quality: Streaming quality preference (default: original)
    public func getStreamURL(for track: Track, quality: StreamingQuality = .original) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🔍 Getting stream URL for track: \(track.title) [quality: \(quality.rawValue)]")
        EnsembleLogger.debug("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        EnsembleLogger.debug("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        EnsembleLogger.debug("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")
        #endif

        if let sourceKey = await resolvedTrackSourceCompositeKey(for: track),
           let provider = syncProviders[sourceKey] {
            // Parse the composite key to extract serverId
            let components = sourceKey.split(separator: ":")
            if components.count >= 4 {
                let accountId = String(components[1])
                let serverId = String(components[2])
                let libraryId = String(components[3])
                
                // Find the server name
                if let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
                   let server = account.servers.first(where: { $0.id == serverId }) {
                    #if DEBUG
                    EnsembleLogger.debug("🔍 Using provider for server: \(server.name) (ID: \(serverId), Library: \(libraryId))")
                    #endif
                } else {
                    #if DEBUG
                    EnsembleLogger.debug("🔍 Using provider for sourceKey: \(sourceKey)")
                    #endif
                }
            }
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey, quality: quality)
        }

        // Fallback: try any available provider
        if let provider = syncProviders.values.first {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Using fallback provider")
            #endif
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey, quality: quality)
        }

        #if DEBUG
        EnsembleLogger.debug("❌ No providers available")
        #endif
        throw PlexAPIError.noServerSelected
    }

    /// Get a quality-aware universal stream URL for offline downloading.
    /// Playback should continue using direct stream URLs for AVPlayer compatibility.
    public func getOfflineDownloadURL(for track: Track, quality: StreamingQuality) async throws -> URL {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }

        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            throw PlexAPIError.noServerSelected
        }

        let accountId = String(components[1])
        let serverId = String(components[2])
        guard let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) else {
            throw PlexAPIError.noServerSelected
        }

        guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else {
            throw PlexAPIError.invalidResponse
        }

        return try await apiClient.getUniversalStreamURL(for: plexTrack, quality: quality)
    }

    /// Attempt a server-primed offline transcode through the download queue API.
    /// Returns media payload and optional suggested filename when successful.
    public func getOfflineDownloadQueueMedia(
        for track: Track,
        quality: StreamingQuality
    ) async throws -> (data: Data, suggestedFilename: String?, mimeType: String?) {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }

        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            throw PlexAPIError.noServerSelected
        }

        let accountId = String(components[1])
        let serverId = String(components[2])
        guard let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) else {
            throw PlexAPIError.noServerSelected
        }

        return try await apiClient.downloadTranscodedMediaViaQueue(
            trackRatingKey: track.id,
            quality: quality
        )
    }

    /// Get a quality-aware fallback URL for offline downloading using Plex's audio transcode endpoint.
    /// This is used when universal offline URLs are rejected by certain server configurations.
    public func getOfflineDownloadFallbackURL(
        for track: Track,
        quality: StreamingQuality,
        preferStreamKeyPath: Bool = false,
        useAbsolutePathParameter: Bool = false,
        useAudioEndpoint: Bool = false,
        useStartWithoutExtension: Bool = false
    ) async throws -> URL {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }

        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            throw PlexAPIError.noServerSelected
        }

        let accountId = String(components[1])
        let serverId = String(components[2])
        guard let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) else {
            throw PlexAPIError.noServerSelected
        }

        let transcodeTrackKey: String
        if preferStreamKeyPath,
           let streamKey = track.streamKey,
           !streamKey.isEmpty {
            // Some servers are stricter about path shape for transcode start and
            // only accept part paths instead of metadata paths.
            transcodeTrackKey = streamKey
        } else {
            transcodeTrackKey = "/library/metadata/\(track.id)"
        }

        return try await apiClient.getTranscodeStreamURL(
            trackKey: transcodeTrackKey,
            quality: quality,
            useAbsolutePathParameter: useAbsolutePathParameter,
            useAudioEndpoint: useAudioEndpoint,
            useStartWithoutExtension: useStartWithoutExtension
        )
    }

    /// Get artwork URL, routing to the correct provider
    public func getArtworkURL(path: String?, sourceKey: String?, size: Int = 300) async throws -> URL? {
        guard let path = path else { return nil }

        if let sourceKey = sourceKey,
           let provider = syncProviders[sourceKey] {
            return try await provider.getArtworkURL(path: path, size: size)
        }

        // Fallback: try any available provider
        if let provider = syncProviders.values.first {
            return try await provider.getArtworkURL(path: path, size: size)
        }

        return nil
    }
    
    /// Rate a track, routing to the correct provider.
    /// After a successful rating change, triggers a debounced playlist sync so smart playlists
    /// reflect the updated rating state.
    public func rateTrack(track: Track, rating: Int?) async throws {
        guard let sourceKey = track.sourceCompositeKey,
              let provider = syncProviders[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }

        try await provider.rateTrack(ratingKey: track.id, rating: rating)

        // Trigger debounced playlist sync so smart playlists reflect the new rating
        triggerPostRatingPlaylistSync(serverSourceKey: sourceKey)
    }

    /// Debounced playlist sync after a rating change so smart playlists update.
    /// Uses a 5s debounce to coalesce rapid rating changes (e.g. bulk favoriting).
    private func triggerPostRatingPlaylistSync(serverSourceKey: String) {
        postRatingPlaylistSyncTasks[serverSourceKey]?.cancel()
        postRatingPlaylistSyncTasks[serverSourceKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s debounce
            guard !Task.isCancelled, let self else { return }
            #if DEBUG
            EnsembleLogger.debug("🔄 SyncCoordinator: Post-rating playlist sync for \(serverSourceKey)")
            #endif
            await self.refreshServerPlaylists(serverSourceKey: serverSourceKey)
            self.postRatingPlaylistSyncTasks.removeValue(forKey: serverSourceKey)
        }
    }

    /// Report playback timeline to Plex server
    /// This updates the server with current playback state and position
    /// - Parameters:
    ///   - track: The currently playing track
    ///   - state: Playback state ("playing", "paused", or "stopped")
    ///   - time: Current playback time in seconds
    public func reportTimeline(track: Track, state: String, time: TimeInterval) async {
        guard let sourceKey = track.sourceCompositeKey,
              let provider = syncProviders[sourceKey] else {
            return
        }

        do {
            try await provider.reportTimeline(
                ratingKey: track.id,
                key: "/library/metadata/\(track.id)",
                state: state,
                time: Int(time * 1000),  // Convert to milliseconds
                duration: Int(track.duration * 1000)  // Convert to milliseconds
            )
        } catch {
            // Timeline reporting is non-critical, just log the error
            #if DEBUG
            EnsembleLogger.debug("⚠️ Failed to report timeline: \(error.localizedDescription)")
            #endif
        }
    }

    /// Scrobble a track (mark as played)
    /// This should be called when a track reaches ~90% completion
    /// - Parameter track: The track to scrobble
    public func scrobbleTrack(_ track: Track) async {
        guard let sourceKey = track.sourceCompositeKey,
              let provider = syncProviders[sourceKey] else {
            return
        }

        do {
            try await provider.scrobble(ratingKey: track.id)
        } catch {
            // Scrobbling is non-critical, just log the error
            #if DEBUG
            EnsembleLogger.debug("⚠️ Failed to scrobble track: \(error.localizedDescription)")
            #endif
        }
    }

    /// Scrobble a track, throwing on failure so MutationCoordinator can queue retries.
    public func scrobbleTrackThrowing(_ track: Track) async throws {
        guard let sourceKey = track.sourceCompositeKey,
              let provider = syncProviders[sourceKey] else {
            return
        }
        try await provider.scrobble(ratingKey: track.id)
    }

    /// Get tracks for an album from the music source
    public func getAlbumTracks(albumId: String, sourceKey: String) async throws -> [Track] {
        guard let provider = syncProviders[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }
        
        return try await provider.getAlbumTracks(albumKey: albumId)
    }

    /// Get albums for an artist from the music source
    public func getArtistAlbums(artistId: String, sourceKey: String) async throws -> [Album] {
        guard let provider = syncProviders[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }
        
        return try await provider.getArtistAlbums(artistKey: artistId)
    }

    /// Get all tracks for an artist from the music source
    public func getArtistTracks(artistId: String, sourceKey: String) async throws -> [Track] {
        guard let provider = syncProviders[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }
        
        return try await provider.getArtistTracks(artistKey: artistId)
    }
    
    /// Delete all CoreData for a removed music source
    public func cleanupRemovedSource(_ sourceId: MusicSourceIdentifier) async {
        do {
            #if DEBUG
            EnsembleLogger.debug("🗑️ Cleaning up data for removed source: \(sourceId.compositeKey)")
            #endif
            try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceId.compositeKey)
            
            // Remove from status tracking
            sourceStatuses.removeValue(forKey: sourceId)
            
            // Clear API client cache for this source
            accountManager.clearAPIClientCache(accountId: sourceId.accountId, serverId: sourceId.serverId)
            
            #if DEBUG
            EnsembleLogger.debug("✅ Successfully cleaned up source: \(sourceId.compositeKey)")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to cleanup source \(sourceId.compositeKey): \(error)")
            #endif
        }
    }

    /// Delete server-scoped playlists when no enabled libraries remain on that server.
    public func cleanupServerPlaylists(accountId: String, serverId: String) async {
        let serverSourceKey = "plex:\(accountId):\(serverId)"
        do {
            try await playlistRepository.deletePlaylists(sourceCompositeKey: serverSourceKey)
            clearLastPlaylistTargets(forServerSourceKey: serverSourceKey)
            let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
            UserDefaults.standard.removeObject(forKey: timestampKey)
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to cleanup server playlists \(serverSourceKey): \(error)")
            #endif
        }
    }
    
    // MARK: - Artwork Pre-Caching

    /// Cache artwork for all albums, artists, and playlists in a source
    private func cacheArtworkForSource(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            // --- Albums (progress 70–80%) ---
            let allAlbums = try await libraryRepository.fetchAlbums()
            let sourceAlbums = allAlbums.filter { $0.sourceCompositeKey == sourceId.compositeKey }

            #if DEBUG
            EnsembleLogger.debug("📸 Pre-caching artwork for \(sourceAlbums.count) albums from source \(sourceId.compositeKey)")
            #endif

            var albumsCached = 0
            for (index, album) in sourceAlbums.enumerated() {
                let artworkProgress = 0.7 + (0.1 * Double(index) / Double(max(sourceAlbums.count, 1)))
                let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .syncing(progress: artworkProgress),
                    connectionState: currentConnectionState
                )

                if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: album),
                   FileManager.default.fileExists(atPath: localPath) {
                    continue
                }

                guard let thumbPath = album.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(path: thumbPath, size: 500) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL, ratingKey: album.ratingKey, type: .album
                    )
                    albumsCached += 1
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("Failed to cache artwork for album \(album.title): \(error)")
                    #endif
                }
            }

            // --- Artists (progress 80–88%) ---
            let allArtists = try await libraryRepository.fetchArtists()
            let sourceArtists = allArtists.filter { $0.sourceCompositeKey == sourceId.compositeKey }

            #if DEBUG
            EnsembleLogger.debug("📸 Pre-caching artwork for \(sourceArtists.count) artists")
            #endif

            var artistsCached = 0
            for (index, artist) in sourceArtists.enumerated() {
                let artworkProgress = 0.8 + (0.08 * Double(index) / Double(max(sourceArtists.count, 1)))
                let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .syncing(progress: artworkProgress),
                    connectionState: currentConnectionState
                )

                if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: artist),
                   FileManager.default.fileExists(atPath: localPath) {
                    continue
                }

                guard let thumbPath = artist.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(path: thumbPath, size: 500) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL, ratingKey: artist.ratingKey, type: .artist
                    )
                    artistsCached += 1
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("Failed to cache artwork for artist \(artist.name): \(error)")
                    #endif
                }
            }

            // --- Playlists (progress 88–96%) ---
            let sourcePlaylists = try await playlistRepository.fetchPlaylists(sourceCompositeKey: sourceId.compositeKey)

            #if DEBUG
            EnsembleLogger.debug("📸 Pre-caching artwork for \(sourcePlaylists.count) playlists")
            #endif

            var playlistsCached = 0
            for (index, playlist) in sourcePlaylists.enumerated() {
                let artworkProgress = 0.88 + (0.08 * Double(index) / Double(max(sourcePlaylists.count, 1)))
                let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .syncing(progress: artworkProgress),
                    connectionState: currentConnectionState
                )

                if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: playlist),
                   FileManager.default.fileExists(atPath: localPath) {
                    continue
                }

                // Plex playlists use compositePath for their composite cover artwork
                guard let thumbPath = playlist.compositePath,
                      let artworkURL = try? await provider.getArtworkURL(path: thumbPath, size: 500) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL, ratingKey: playlist.ratingKey, type: .playlist
                    )
                    playlistsCached += 1
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("Failed to cache artwork for playlist \(playlist.title): \(error)")
                    #endif
                }
            }

            #if DEBUG
            EnsembleLogger.debug("✅ Cached artworks: \(albumsCached) albums, \(artistsCached) artists, \(playlistsCached) playlists")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to cache artwork: \(error)")
            #endif
        }
    }

    private struct ParsedServerSource {
        let accountId: String
        let serverId: String
    }

    /// Convert a library-level source key (`plex:account:server:library`) into server-level key (`plex:account:server`).
    private func serverSourceKey(from sourceCompositeKey: String?) -> String? {
        guard let sourceCompositeKey else { return nil }
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return "\(components[0]):\(components[1]):\(components[2])"
    }

    private func parseServerSourceKey(_ key: String) -> ParsedServerSource? {
        let components = key.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return ParsedServerSource(accountId: String(components[1]), serverId: String(components[2]))
    }

    /// Keep only tracks that belong to target server, then dedupe by track id preserving order.
    /// Uses local lookup when the in-memory track source key is temporarily missing.
    private func filteredTrackIDsForServer(tracks: [Track], serverSourceKey targetServerSourceKey: String) async -> [String] {
        var seen = Set<String>()
        var ids: [String] = []

        for track in tracks {
            if let trackServerSource = await resolvedServerSourceKey(for: track) {
                guard trackServerSource == targetServerSourceKey else { continue }
            } else {
                // If source is unknown and app only has one server, allow it through.
                guard hasSingleServerMatching(targetServerSourceKey) else { continue }
            }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            ids.append(track.id)
        }

        return ids
    }

    private func resolvedServerSourceKey(for track: Track) async -> String? {
        if let parsed = serverSourceKey(from: track.sourceCompositeKey) {
            return parsed
        }

        if let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id),
           let parsed = serverSourceKey(from: cachedTrack.sourceCompositeKey) {
            return parsed
        }

        return nil
    }

    private func resolvedTrackSourceCompositeKey(for track: Track) async -> String? {
        if let source = track.sourceCompositeKey {
            return source
        }

        if let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id),
           let source = cachedTrack.sourceCompositeKey {
            #if DEBUG
            EnsembleLogger.debug("🎵 Resolved missing track source from cache: \(track.id) -> \(source)")
            #endif
            return source
        }

        // Last resort: single-provider assumption when app is connected to one library source.
        if syncProviders.count == 1, let onlyKey = syncProviders.keys.first {
            #if DEBUG
            EnsembleLogger.debug("🎵 Resolved missing track source via single-provider fallback: \(track.id) -> \(onlyKey)")
            #endif
            return onlyKey
        }

        #if DEBUG
        EnsembleLogger.debug("⚠️ Could not resolve source key for track: \(track.id)")
        #endif
        return nil
    }

    private func hasSingleServerMatching(_ serverSourceKey: String) -> Bool {
        let uniqueServerSources = Set(
            syncProviders.keys.compactMap { key in
                self.serverSourceKey(from: key)
            }
        )
        return uniqueServerSources.count == 1 && uniqueServerSources.first == serverSourceKey
    }

    private func seedTrackIDForServer(
        serverSourceKey: String,
        parsedServer: ParsedServerSource,
        apiClient: PlexAPIClient
    ) async -> String? {
        // Fast path: try local cache first.
        if let allTracks = try? await libraryRepository.fetchTracks(),
           let cachedTrackID = allTracks.first(where: { track in
            guard let trackSourceCompositeKey = track.sourceCompositeKey,
                  let trackServerSourceKey = self.serverSourceKey(from: trackSourceCompositeKey) else {
                return false
            }
            return trackServerSourceKey == serverSourceKey
           })?.ratingKey {
            return cachedTrackID
        }

        // Fallback: query Plex for a lightweight inventory and use any one track ID.
        guard let account = accountManager.plexAccounts.first(where: { $0.id == parsedServer.accountId }),
              let server = account.servers.first(where: { $0.id == parsedServer.serverId }) else {
            return nil
        }

        for library in server.libraries where library.isEnabled {
            if let seedFromInventory = try? await apiClient.getTrackInventory(sectionKey: library.key).first?.ratingKey {
                return seedFromInventory
            }
        }

        return nil
    }

    /// Refresh playlists for a specific server after a mutation so CoreData stays in sync.
    private func refreshServerPlaylists(serverSourceKey: String) async {
        guard let parsed = parseServerSourceKey(serverSourceKey) else { return }
        for (_, provider) in syncProviders where
            provider.sourceIdentifier.accountId == parsed.accountId &&
            provider.sourceIdentifier.serverId == parsed.serverId {
            var didRefresh = false
            do {
                try await provider.syncPlaylistsIncremental(to: playlistRepository, progressHandler: { _ in })
                didRefresh = true
            } catch {
                // Fall back to full sync if incremental fails for any reason.
                do {
                    try await provider.syncPlaylists(to: playlistRepository, progressHandler: { _ in })
                    didRefresh = true
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("⚠️ Failed to refresh playlists for \(serverSourceKey): \(error.localizedDescription)")
                    #endif
                }
            }
            if didRefresh {
                onPlaylistRefreshCompleted?(serverSourceKey)
                NotificationCenter.default.post(
                    name: Self.playlistsDidRefresh,
                    object: nil,
                    userInfo: ["serverSourceKey": serverSourceKey]
                )
            }
            return
        }
    }

    private func persistLastPlaylistTarget(from playlist: Playlist) {
        let target = LastPlaylistTarget(
            id: playlist.id,
            title: playlist.title,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        if let serverSourceKey = playlist.sourceCompositeKey {
            lastPlaylistTargetsByServer[serverSourceKey] = target
            Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)
        }
        Self.saveLastPlaylistTarget(target)
        lastPlaylistTarget = target
    }

    private func clearLastPlaylistTargetIfNeeded(deletedPlaylist: Playlist) {
        guard let deletedSourceKey = deletedPlaylist.sourceCompositeKey else { return }

        lastPlaylistTargetsByServer = lastPlaylistTargetsByServer.filter { sourceKey, target in
            !(sourceKey == deletedSourceKey && target.id == deletedPlaylist.id)
        }
        Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)

        if let lastPlaylistTarget,
           lastPlaylistTarget.id == deletedPlaylist.id,
           lastPlaylistTarget.sourceCompositeKey == deletedSourceKey {
            self.lastPlaylistTarget = nil
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    private func clearLastPlaylistTargets(forServerSourceKey serverSourceKey: String) {
        lastPlaylistTargetsByServer.removeValue(forKey: serverSourceKey)
        Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)

        if let lastPlaylistTarget,
           lastPlaylistTarget.sourceCompositeKey == serverSourceKey {
            self.lastPlaylistTarget = nil
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    public func lastPlaylistTarget(forServerSourceKey serverSourceKey: String?) -> LastPlaylistTarget? {
        guard let serverSourceKey else { return lastPlaylistTarget }
        if let target = lastPlaylistTargetsByServer[serverSourceKey] {
            return target
        }
        if let lastPlaylistTarget, lastPlaylistTarget.sourceCompositeKey == serverSourceKey {
            return lastPlaylistTarget
        }
        return nil
    }

    internal func setLastPlaylistTargetForTesting(_ target: LastPlaylistTarget?, serverSourceKey: String?) {
        if let serverSourceKey {
            if let target {
                lastPlaylistTargetsByServer[serverSourceKey] = target
            } else {
                lastPlaylistTargetsByServer.removeValue(forKey: serverSourceKey)
            }
            Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)
        }

        lastPlaylistTarget = target
        let defaults = UserDefaults.standard
        if let target {
            defaults.set(target.id, forKey: Self.lastPlaylistIdKey)
            defaults.set(target.title, forKey: Self.lastPlaylistTitleKey)
            defaults.set(target.sourceCompositeKey, forKey: Self.lastPlaylistSourceKey)
        } else {
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    private static func saveLastPlaylistTarget(_ target: LastPlaylistTarget) {
        let defaults = UserDefaults.standard
        defaults.set(target.id, forKey: lastPlaylistIdKey)
        defaults.set(target.title, forKey: lastPlaylistTitleKey)
        defaults.set(target.sourceCompositeKey, forKey: lastPlaylistSourceKey)
    }

    private static func loadLastPlaylistTarget() -> LastPlaylistTarget? {
        let defaults = UserDefaults.standard
        guard
            let id = defaults.string(forKey: lastPlaylistIdKey),
            let title = defaults.string(forKey: lastPlaylistTitleKey)
        else {
            return nil
        }
        return LastPlaylistTarget(
            id: id,
            title: title,
            sourceCompositeKey: defaults.string(forKey: lastPlaylistSourceKey)
        )
    }

    private static func saveLastPlaylistTargetsByServer(_ targets: [String: LastPlaylistTarget]) {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(targets) else { return }
        defaults.set(data, forKey: lastPlaylistTargetsByServerKey)
    }

    private static func loadLastPlaylistTargetsByServer() -> [String: LastPlaylistTarget] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: lastPlaylistTargetsByServerKey),
              let decoded = try? JSONDecoder().decode([String: LastPlaylistTarget].self, from: data) else {
            return [:]
        }
        return decoded
    }
    
    // MARK: - Network Monitoring
    
    /// Set up observation of network state changes
    private func setupNetworkMonitoring() {
        lastObservedNetworkState = networkMonitor.networkState

        networkMonitor.$networkState
            .dropFirst()
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.handleObservedNetworkState(state)
                }
            }
            .store(in: &cancellables)
    }

    /// Foreground hook used by app lifecycle to coalesce network health updates.
    /// Triggers a fresh server health check and updates published sourceStatuses.
    /// Called from account detail views after inventory refresh to reflect real connectivity.
    public func refreshServerHealthStates() {
        scheduleHealthRefresh(reason: .accountInventoryRefresh, forceServerRefresh: true)
    }

    public func handleAppWillEnterForeground() async {
        if accountManager.enforceAuthTokenPolicy() {
            refreshProviders()
        }

        let currentState = networkMonitor.networkState

        #if DEBUG
        EnsembleLogger.debug("🌐 SyncCoordinator: App entering foreground with state \(currentState.description)")
        #endif

        switch currentState {
        case .online:
            isOffline = false
            scheduleHealthRefresh(reason: .appForeground, forceServerRefresh: false)
        case .offline, .limited:
            isOffline = true
            updateSourceConnectionStates()
        case .unknown:
            break
        }
    }

    private func handleObservedNetworkState(_ state: NetworkState) async {
        let previous = lastObservedNetworkState
        lastObservedNetworkState = state

        let transition = classifyNetworkTransition(from: previous, to: state)

        #if DEBUG
        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Network transition \(previous?.description ?? "nil") -> \(state.description)"
        )
        if case .interfaceSwitch(let from, let to) = transition {
            EnsembleLogger.debug("🌐 SyncCoordinator: Detected interface switch \(from.description) -> \(to.description)")
        }
        #endif

        switch state {
        case .online:
            isOffline = false
        case .offline, .limited:
            isOffline = true
            updateSourceConnectionStates()
        case .unknown:
            break
        }

        switch transition {
        case .reconnect:
            // Invalidate connection health caches on reconnect.
            // Stale endpoints from before the network went down may no longer work
            // (e.g. if IP addresses changed or TLS state is corrupted).
            await serverHealthChecker.invalidateConnectionHealth()

            // Immediately invalidate artwork URL cache on reconnect.
            // This prevents stale artwork requests that use old endpoint URLs while
            // health checks are still running.
            #if DEBUG
            EnsembleLogger.debug("🖼️ SyncCoordinator: Early artwork cache invalidation for reconnect")
            #endif
            await onConnectionsRefreshed?()
            scheduleHealthRefresh(reason: .networkReconnect, forceServerRefresh: true)
        case .interfaceSwitch(let from, let to):
            // Invalidate connection health caches on interface switch.
            // Without this, stale "preferred" endpoints from the previous network context
            // (e.g. remote endpoints cached while on cellular) may be reused even when
            // better local endpoints are now available (after switching to WiFi).
            // This forces a full re-probe of all endpoints.
            await serverHealthChecker.invalidateConnectionHealth()

            // Immediately invalidate artwork URL cache on interface switch.
            // This prevents stale artwork requests that use old endpoint URLs while
            // health checks are still running. The cache will be invalidated again
            // after health checks complete, but this early invalidation is critical
            // for any artwork requests that happen before health checks finish.
            #if DEBUG
            EnsembleLogger.debug("🖼️ SyncCoordinator: Early artwork cache invalidation for interface switch")
            #endif
            await onConnectionsRefreshed?()
            scheduleHealthRefresh(reason: .interfaceSwitch(from: from, to: to), forceServerRefresh: true)
        case .disconnect, .none:
            break
        }
    }

    private func classifyNetworkTransition(from previous: NetworkState?, to current: NetworkState) -> NetworkTransition {
        let previousType = networkType(from: previous)
        let currentType = networkType(from: current)
        let previousConnected = previous?.isConnected ?? false
        let currentConnected = current.isConnected

        if !previousConnected && currentConnected {
            return .reconnect
        }

        if previousConnected && !currentConnected {
            return .disconnect
        }

        if let previousType, let currentType, previousType != currentType {
            return .interfaceSwitch(from: previousType, to: currentType)
        }

        return .none
    }

    private func networkType(from state: NetworkState?) -> NetworkType? {
        guard let state, case .online(let type) = state else {
            return nil
        }
        return type
    }

    private func scheduleHealthRefresh(reason: HealthRefreshReason, forceServerRefresh: Bool) {
        if activeHealthRefreshTask != nil {
            #if DEBUG
            EnsembleLogger.debug("🌐 SyncCoordinator: Coalescing health refresh request (\(reason.description))")
            #endif
            return
        }

        let now = nowProviderForTesting()

        if reason == .appForeground,
           let lastRefresh = lastHealthRefreshAt,
           now.timeIntervalSince(lastRefresh) < foregroundHealthStalenessThreshold {
            #if DEBUG
            EnsembleLogger.debug(
                "🌐 SyncCoordinator: Skipping foreground health refresh (last run \(String(format: "%.1f", now.timeIntervalSince(lastRefresh)))s ago)"
            )
            #endif
            return
        }

        // Interface switches and user-initiated account refreshes bypass cooldown
        // to ensure connections are refreshed immediately.
        let bypassCooldown: Bool
        switch reason {
        case .interfaceSwitch, .accountInventoryRefresh:
            bypassCooldown = true
        default:
            bypassCooldown = false
        }

        if !bypassCooldown,
           let lastRefresh = lastHealthRefreshAt,
           now.timeIntervalSince(lastRefresh) < healthRefreshCooldown {
            #if DEBUG
            EnsembleLogger.debug(
                "🌐 SyncCoordinator: Skipping health refresh due to cooldown (\(String(format: "%.1f", now.timeIntervalSince(lastRefresh)))s ago)"
            )
            #endif
            return
        }

        let eligibleServerKeys = enabledServerKeysForHealthChecks()
        guard !eligibleServerKeys.isEmpty else {
            #if DEBUG
            EnsembleLogger.debug("🌐 SyncCoordinator: No enabled-library servers eligible for health checks")
            #endif
            return
        }

        isCheckingHealth = true
        let startedAt = nowProviderForTesting()

        activeHealthRefreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            defer {
                self.isCheckingHealth = false
                let completionTime = self.nowProviderForTesting()
                self.lastHealthRefreshAt = completionTime
                self.lastHealthCheckCompletion = completionTime
                self.activeHealthRefreshTask = nil
            }

            let summary = await self.runHealthChecks(forceServerRefresh: forceServerRefresh, eligibleServerKeys: eligibleServerKeys)
            self.updateSourceConnectionStates()
            await self.runAPIClientConnectionRefresh()

            #if DEBUG
            let duration = self.nowProviderForTesting().timeIntervalSince(startedAt)
            EnsembleLogger.debug(
                "🌐 SyncCoordinator: Health refresh complete reason=\(reason.description), checked=\(summary.checkedCount), skipped=\(summary.skippedCount), duration=\(String(format: "%.2f", duration))s"
            )
            #endif
        }
    }

    private func enabledServerKeysForHealthChecks() -> Set<String> {
        var keys = Set<String>()

        for account in accountManager.plexAccounts {
            for server in account.servers where server.libraries.contains(where: \.isEnabled) {
                keys.insert("\(account.id):\(server.id)")
            }
        }

        return keys
    }

    private func runHealthChecks(
        forceServerRefresh: Bool,
        eligibleServerKeys: Set<String>
    ) async -> ServerHealthChecker.CheckSummary {
        if let healthCheckRunnerForTesting {
            return await healthCheckRunnerForTesting(forceServerRefresh, eligibleServerKeys)
        }

        return await serverHealthChecker.checkAllServers(
            forceRefresh: forceServerRefresh,
            eligibleServerKeys: eligibleServerKeys
        )
    }

    private func runAPIClientConnectionRefresh() async {
        if let refreshAPIClientConnectionsRunnerForTesting {
            await refreshAPIClientConnectionsRunnerForTesting()
            return
        }

        await refreshAPIClientConnections()
    }

    internal func handleObservedNetworkStateForTesting(_ state: NetworkState) async {
        await handleObservedNetworkState(state)
    }

    internal func awaitHealthRefreshForTesting() async {
        await activeHealthRefreshTask?.value
    }

    internal func setLastHealthRefreshForTesting(_ date: Date?) {
        lastHealthRefreshAt = date
    }

    /// Subscribe to centralized endpoint changes from the registry.
    /// When health checks or API client failovers discover a new endpoint, this
    /// automatically syncs the API client and notifies artwork loaders.
    private func subscribeToRegistryChanges(registry: ServerConnectionRegistry) {
        registrySubscriptionTask = Task { [weak self] in
            let stream = await registry.endpointChanges()
            for await state in stream {
                guard let self, !Task.isCancelled else { break }

                // Parse serverKey back to accountId:serverId
                let parts = state.serverKey.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let accountId = String(parts[0])
                let serverId = String(parts[1])

                // Update the API client's active URL to match the registry
                if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
                    let currentURL = await apiClient.getCurrentServerURL()
                    if currentURL != state.endpoint.url {
                        await apiClient.updateCurrentServerURL(state.endpoint.url)
                        #if DEBUG
                        EnsembleLogger.debug(
                            "📍 SyncCoordinator: Registry synced API client for \(state.serverKey) to \(state.endpoint.url) (source=\(state.source.rawValue))"
                        )
                        #endif
                    }
                }

                // Notify listeners (e.g., ArtworkLoader) to invalidate stale cached URLs
                await onConnectionsRefreshed?()
            }
        }
    }

    /// Update all API clients with the latest working connection URLs from health checks.
    /// When a `ServerConnectionRegistry` is active, most updates flow reactively through
    /// `subscribeToRegistryChanges`. This method remains as a fallback for tests and
    /// the non-registry path.
    public func refreshAPIClientConnections() async {
        #if DEBUG
        EnsembleLogger.debug("🔄 SyncCoordinator: Updating API client connections...")
        #endif

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let serverKey = "\(account.id):\(server.id)"

                // Prefer registry endpoint when available
                if let registry = connectionRegistry,
                   let registryURL = await registry.currentURL(for: serverKey),
                   let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(registryURL)
                    #if DEBUG
                    EnsembleLogger.debug("✅ Updated API client for server \(server.name) from registry: \(registryURL)")
                    #endif
                    continue
                }

                // Fallback: read from health checker state
                let connectionState = serverHealthChecker.getServerState(
                    accountId: account.id,
                    serverId: server.id
                )

                if case .connected(let workingURL) = connectionState,
                   let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(workingURL)
                    #if DEBUG
                    EnsembleLogger.debug("✅ Updated API client for server \(server.name) to use: \(workingURL)")
                    #endif
                } else if case .degraded(let workingURL) = connectionState,
                          let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(workingURL)
                    #if DEBUG
                    EnsembleLogger.debug("⚠️ Updated API client for server \(server.name) to use degraded connection: \(workingURL)")
                    #endif
                }
            }
        }

        // Notify listeners (e.g., ArtworkLoader) to invalidate stale cached URLs
        await onConnectionsRefreshed?()
    }

    /// Update source statuses with current connection states from health checker
    private func updateSourceConnectionStates() {
        for account in accountManager.plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    let sourceId = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    )
                    
                    // Get connection state from health checker
                    let connectionState = serverHealthChecker.getServerState(
                        accountId: account.id,
                        serverId: server.id
                    )
                    
                    // Update status preserving sync state
                    if let currentStatus = sourceStatuses[sourceId] {
                        sourceStatuses[sourceId] = MusicSourceStatus(
                            syncStatus: currentStatus.syncStatus,
                            connectionState: connectionState
                        )
                    } else {
                        sourceStatuses[sourceId] = MusicSourceStatus(
                            syncStatus: .idle,
                            connectionState: connectionState
                        )
                    }
                }
            }
        }
    }

    // MARK: - Radio Provider Factory

    /// Create a radio provider for a specific music source
    /// Returns nil if the source doesn't support radio or isn't configured
    /// - Parameter sourceKey: The music source composite key
    public func makeRadioProvider(for sourceKey: String) -> RadioProviderProtocol? {
        #if DEBUG
        EnsembleLogger.debug("🔄 SyncCoordinator.makeRadioProvider() called")
        EnsembleLogger.debug("  - Source key: \(sourceKey)")
        #endif
        
        // Parse source key to extract identifiers
        // Format: sourceType:accountId:serverId:libraryId (e.g., "plex:account123:server456:library789")
        let components = sourceKey.split(separator: ":")
        #if DEBUG
        EnsembleLogger.debug("  - Key components: \(components)")
        EnsembleLogger.debug("  - Component count: \(components.count)")
        #endif
        
        guard components.count >= 4,
              let sourceType = MusicSourceType(rawValue: String(components[0])) else {
            #if DEBUG
            EnsembleLogger.debug("❌ Invalid source key format: \(sourceKey)")
            #endif
            return nil
        }
        #if DEBUG
        EnsembleLogger.debug("  - Source type: \(sourceType)")
        #endif

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])
        #if DEBUG
        EnsembleLogger.debug("  - Account ID: \(accountId)")
        EnsembleLogger.debug("  - Server ID: \(serverId)")
        EnsembleLogger.debug("  - Library ID: \(libraryId)")
        #endif

        // Currently only Plex is supported
        guard sourceType == .plex else {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Radio not available for source type: \(sourceType)")
            #endif
            return nil
        }

        // Get API client for this source
        #if DEBUG
        EnsembleLogger.debug("🔄 Creating API client...")
        #endif
        guard let apiClient = accountManager.makeAPIClient(
            accountId: accountId,
            serverId: serverId
        ) else {
            #if DEBUG
            EnsembleLogger.debug("❌ Could not create API client for source: \(sourceKey)")
            #endif
            return nil
        }
        #if DEBUG
        EnsembleLogger.debug("✅ API client created")
        #endif

        // Create Plex radio provider
        #if DEBUG
        EnsembleLogger.debug("🔄 Creating PlexRadioProvider...")
        #endif
        let radioProvider = PlexRadioProvider(
            sourceKey: sourceKey,
            apiClient: apiClient,
            libraryRepository: libraryRepository,
            sectionKey: libraryId
        )

        #if DEBUG
        EnsembleLogger.debug("✅ Created PlexRadioProvider for source: \(sourceKey)")
        #endif
        return radioProvider
    }
    
    // MARK: - Periodic Sync During Active Use
    
    /// Start periodic incremental sync while app is active (every 1 hour)
    public func startPeriodicSync() {
        stopPeriodicSync()  // Stop any existing timer
        
        #if DEBUG
        EnsembleLogger.debug("⏰ Starting periodic sync timer (every 1 hour)")
        #endif
        incrementalSyncTimer = Timer.scheduledTimer(withTimeInterval: incrementalSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performPeriodicSync()
            }
        }
    }
    
    /// Stop periodic sync
    public func stopPeriodicSync() {
        incrementalSyncTimer?.invalidate()
        incrementalSyncTimer = nil
        #if DEBUG
        EnsembleLogger.debug("🛑 Stopped periodic sync timer")
        #endif
    }
    
    /// Perform periodic incremental sync (called by timer)
    private func performPeriodicSync() async {
        #if DEBUG
        EnsembleLogger.debug("⏰ Periodic sync triggered")
        #endif
        
        // Don't sync if offline
        guard !isOffline else {
            #if DEBUG
            EnsembleLogger.debug("📴 Offline - skipping periodic sync")
            #endif
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            #if DEBUG
            EnsembleLogger.debug("⏳ Sync already in progress - skipping periodic sync")
            #endif
            return
        }
        
        // Check network connectivity - only sync when connected
        #if os(iOS)
        if !networkMonitor.isConnected {
            #if DEBUG
            EnsembleLogger.debug("📡 Not connected - skipping periodic sync")
            #endif
            return
        }
        #endif
        
        #if DEBUG
        EnsembleLogger.debug("🔄 Performing periodic incremental sync...")
        #endif
        await syncAllIncremental()
        lastIncrementalSyncTime = Date()
        #if DEBUG
        EnsembleLogger.debug("✅ Periodic sync complete")
        #endif
    }

    // MARK: - WebSocket-Triggered Sync

    /// Trigger an incremental sync for a specific library section.
    /// Called by `PlexWebSocketCoordinator` when a library update notification arrives.
    public func syncSectionIncremental(sectionKey: String) async {
        // Find the provider that owns this section key
        let matchingSource = syncProviders.first { (_, provider) in
            (provider as? PlexMusicSourceSyncProvider)?.sectionKey == sectionKey
        }

        guard let (compositeKey, _) = matchingSource else {
            EnsembleLogger.error("🔌 SyncCoordinator: No provider found for section \(sectionKey)")
            return
        }

        guard let sourceId = sourceStatuses.keys.first(where: { $0.compositeKey == compositeKey }) else {
            EnsembleLogger.error("🔌 SyncCoordinator: No sourceStatus found for compositeKey=\(compositeKey)")
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered incremental sync for section \(sectionKey)")
        #endif

        await syncIncremental(source: sourceId)
    }

    /// Trigger a playlist-only sync for a specific server.
    /// Called by `PlexWebSocketCoordinator` when a playlist update notification arrives.
    /// Does not depend on `isSyncing` so it can run alongside library sync.
    public func syncServerPlaylistsIncremental(serverKey: String) async {
        // Find a provider for this server
        let matchingProvider = syncProviders.first { (_, provider) in
            let id = provider.sourceIdentifier
            return "\(id.accountId):\(id.serverId)" == serverKey
        }

        guard let (_, provider) = matchingProvider else {
            EnsembleLogger.error("🔌 SyncCoordinator: No provider found for server \(serverKey) playlist sync")
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered playlist sync for server \(serverKey)")
        #endif

        let sourceId = provider.sourceIdentifier
        do {
            try await provider.syncPlaylistsIncremental(
                to: playlistRepository,
                progressHandler: { _ in }
            )
            let serverSourceKey = "plex:\(sourceId.accountId):\(sourceId.serverId)"
            onPlaylistRefreshCompleted?(serverSourceKey)
            NotificationCenter.default.post(
                name: Self.playlistsDidRefresh,
                object: nil,
                userInfo: ["serverSourceKey": serverSourceKey]
            )
        } catch {
            EnsembleLogger.error("🔌 SyncCoordinator: Playlist sync failed for server \(serverKey): \(error.localizedDescription)")
        }
    }

    /// Adjust periodic sync intervals based on WebSocket availability.
    /// When WebSocket is active for servers, polling can be relaxed since updates arrive in real-time.
    public func adjustTimersForWebSocket(hasActiveWebSocket: Bool) {
        stopPeriodicSync()

        let interval: TimeInterval
        if hasActiveWebSocket {
            // With WebSocket: relax polling to every 4 hours (WebSocket pushes updates)
            interval = 4 * 60 * 60
            #if DEBUG
            EnsembleLogger.debug("⏰ SyncCoordinator: WebSocket active — relaxed periodic sync to 4h")
            #endif
        } else {
            // Without WebSocket: use default 1 hour interval
            interval = incrementalSyncInterval
            #if DEBUG
            EnsembleLogger.debug("⏰ SyncCoordinator: No WebSocket — using default 1h periodic sync")
            #endif
        }

        incrementalSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performPeriodicSync()
            }
        }
    }
}
