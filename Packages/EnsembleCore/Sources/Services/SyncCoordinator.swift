import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

public struct PlaylistMutationResult: Sendable {
    public let addedCount: Int
    public let skippedCount: Int

    public init(addedCount: Int, skippedCount: Int) {
        self.addedCount = addedCount
        self.skippedCount = skippedCount
    }
}

public struct SyncContentChange: Sendable, Equatable {
    public let source: MusicSourceIdentifier
    public let libraryResult: LibrarySyncResult?
    public let playlistResult: PlaylistSyncResult?
    public let syncedAt: Date

    public init(
        source: MusicSourceIdentifier,
        libraryResult: LibrarySyncResult? = nil,
        playlistResult: PlaylistSyncResult? = nil,
        syncedAt: Date
    ) {
        self.source = source
        self.libraryResult = libraryResult
        self.playlistResult = playlistResult
        self.syncedAt = syncedAt
    }

    public var affectsLibraryBrowse: Bool {
        libraryResult?.hasMaterialChanges == true
    }

    public var affectsPlaylists: Bool {
        playlistResult?.hasMaterialChanges == true
    }

    public var hasMaterialChanges: Bool {
        affectsLibraryBrowse || affectsPlaylists
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

    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false
    @Published public private(set) var isOffline = false
    @Published public private(set) var lastPlaylistTarget: LastPlaylistTarget?
    /// Published when health checks complete so dependent services can react.
    @Published public private(set) var lastHealthCheckCompletion: Date?
    /// Narrow sync output for consumers that care about actual data changes, not transport churn.
    @Published public private(set) var lastContentChange: SyncContentChange?
    /// Published after the launch-triggered sync finishes so browse surfaces can do a one-shot refresh.
    @Published public private(set) var lastStartupSyncCompletion: Date?

    public let accountManager: AccountManager
    public let networkMonitor: NetworkMonitor
    public let serverHealthChecker: ServerHealthChecker
    public let connectionRegistry: ServerConnectionRegistry?
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let refreshOrchestrator: RefreshOrchestrator
    private let serverConnectionController: ServerConnectionController
    private let periodicSyncController: PeriodicSyncController
    private let playlistRefreshController: PlaylistRefreshController
    private let webSocketSyncController: WebSocketSyncController
    private let playbackReportingController: SyncPlaybackReportingController
    private let networkLifecycleController: NetworkLifecycleController
    private var syncProviders: [String: MusicSourceSyncProvider] = [:]  // keyed by compositeKey
    private var providerResolver: SyncProviderResolver {
        SyncProviderResolver(providers: syncProviders)
    }
    private var cancellables = Set<AnyCancellable>()
    private var isCheckingHealth = false
    /// Timestamp of last sourceStatuses progress update per source — used to throttle
    /// @Published updates during sync so SwiftUI doesn't re-render on every item.
    private var lastProgressUpdateTime: [MusicSourceIdentifier: CFAbsoluteTime] = [:]
    private let progressThrottleInterval: CFAbsoluteTime = 0.2  // 200ms
    private static let lastPlaylistIdKey = "NowPlaying.LastPlaylist.ID"
    private static let lastPlaylistTitleKey = "NowPlaying.LastPlaylist.Title"
    private static let lastPlaylistSourceKey = "NowPlaying.LastPlaylist.SourceKey"
    private static let lastPlaylistTargetsByServerKey = "NowPlaying.LastPlaylist.ByServer"
    private var lastPlaylistTargetsByServer: [String: LastPlaylistTarget]
    internal var playlistDeleteHandlerForTesting: ((PlexAPIClient, String) async throws -> Void)?
    internal var playlistReplaceContentsHandlerForTesting: ((PlexAPIClient, String, [String], String) async throws -> Void)?
    internal var refreshServerPlaylistsHandlerForTesting: ((String) async -> Void)?
    internal var nowProviderForTesting: () -> Date = { Date() }
    /// Backoff for repeated playlist artwork failures to avoid retrying the same bad payload every sync.
    private var playlistArtworkRetryAfter: [String: Date] = [:]
    private let playlistArtworkFailureBackoff: TimeInterval = 5 * 60
    internal static let fullSizeArtworkCacheDimension = ArtworkSize.detail.rawValue

    /// Closure called when API client connections are refreshed (e.g., after network change).
    /// Used by ArtworkLoader to invalidate stale URL cache entries.
    public var onConnectionsRefreshed: (() async -> Void)? {
        didSet {
            serverConnectionController.onConnectionsRefreshed = onConnectionsRefreshed
        }
    }
    /// Signal fired when a server-level playlist refresh completes.
    public var onPlaylistRefreshCompleted: ((String) -> Void)?
    /// Signal fired after a rating change so the favorites download target can reconcile.
    public var onFavoritesRatingChanged: (() async -> Void)?
    /// Optional load-aware gate for foreground health refreshes. DependencyContainer
    /// wires this to the download/playback stack so nonessential probes can defer
    /// while the app is actively protecting playback.
    public var shouldDeferForegroundHealthRefresh: (() -> Bool)?

    /// Called after sync when tracks have been reparented (album changed).
    /// Used by ArtworkLoader to invalidate stale artwork for affected albums.
    public var onTrackAlbumChanged: (([TrackReparentInfo]) async -> Void)?
    /// Called after sync when album or artist artwork metadata changed.
    public var onArtworkMetadataChanged: (([ArtworkInvalidationInfo]) async -> Void)?

    /// Worker that owns source-specific cache and file cleanup outside the coordinator's UI-facing actor.
    public var sourceCacheCleanupService: SourceCacheCleaning?
    internal var healthCheckRunnerForTesting: ((Bool, Set<String>) async -> ServerHealthChecker.CheckSummary)?
    internal var refreshAPIClientConnectionsRunnerForTesting: (() async -> Void)?

    internal func setSyncProvidersForTesting(_ providers: [String: MusicSourceSyncProvider]) {
        syncProviders = providers
    }

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
        self.refreshOrchestrator = RefreshOrchestrator()
        self.periodicSyncController = PeriodicSyncController()
        self.playlistRefreshController = PlaylistRefreshController()
        self.webSocketSyncController = WebSocketSyncController()
        self.playbackReportingController = SyncPlaybackReportingController()
        self.networkLifecycleController = NetworkLifecycleController(initialNetworkState: networkMonitor.networkState)
        self.serverConnectionController = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: serverHealthChecker,
            connectionRegistry: connectionRegistry
        )
        self.lastPlaylistTargetsByServer = Self.loadLastPlaylistTargetsByServer()
        self.lastPlaylistTarget = Self.loadLastPlaylistTarget()

        // Observe network state changes
        setupNetworkMonitoring()

        serverConnectionController.start()
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
        await syncExecutionController().syncAll(providers: syncProviders)
    }

    /// Sync a single source.
    public func sync(source: MusicSourceIdentifier) async {
        await syncExecutionController().sync(source: source, providers: syncProviders)
    }

    /// Sync a scoped set of sources while publishing one global sync lifecycle.
    public func sync(sources: [MusicSourceIdentifier]) async {
        await syncExecutionController().sync(sources: sources, providers: syncProviders)
    }

    private func syncErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.caseInsensitiveCompare("unknown") != .orderedSame else {
            return "Sync failed. Please try again."
        }
        return message
    }

    private func effectiveConnectionState(for fallback: ServerConnectionState) -> ServerConnectionState {
        isOffline ? .offline : fallback
    }

    private func restoreStatusAfterCancellation(
        for source: MusicSourceIdentifier,
        previousStatus: MusicSourceStatus?,
        fallbackConnectionState: ServerConnectionState
    ) {
        let restoredStatus = previousStatus?.syncStatus ?? .idle
        sourceStatuses[source] = MusicSourceStatus(
            syncStatus: restoredStatus,
            connectionState: effectiveConnectionState(for: fallbackConnectionState)
        )
        EnsembleLogger.debug("⏹️ SyncCoordinator: Cancelled sync for \(source.compositeKey) without surfacing an error")
    }

    private func publishContentChangeIfNeeded(
        for source: MusicSourceIdentifier,
        libraryResult: LibrarySyncResult? = nil,
        playlistResult: PlaylistSyncResult? = nil,
        syncedAt: Date
    ) {
        let contentChange = SyncContentChange(
            source: source,
            libraryResult: libraryResult,
            playlistResult: playlistResult,
            syncedAt: syncedAt
        )
        guard contentChange.hasMaterialChanges else { return }
        lastContentChange = contentChange
    }

    /// Throttles sourceStatuses progress updates to avoid flooding SwiftUI with per-item
    /// @Published changes during sync. Always publishes near-completion updates (≥99%).
    private func throttledProgressUpdate(for sourceId: MusicSourceIdentifier, mappedProgress: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastUpdate = lastProgressUpdateTime[sourceId] ?? 0

        // Always publish near-completion; otherwise respect throttle interval
        guard mappedProgress >= 0.99 || (now - lastUpdate) >= progressThrottleInterval else { return }
        lastProgressUpdateTime[sourceId] = now

        let connState = sourceStatuses[sourceId]?.connectionState ?? .unknown
        sourceStatuses[sourceId] = MusicSourceStatus(
            syncStatus: .syncing(progress: mappedProgress),
            connectionState: connState
        )
    }
    
    /// Sync all enabled sources incrementally (only fetch changes since last sync)
    public func syncAllIncremental() async {
        await syncExecutionController().syncAllIncremental(providers: syncProviders)
    }
    
    /// Sync a single source incrementally (only fetch changes since last sync)
    public func syncIncremental(source: MusicSourceIdentifier) async {
        await syncExecutionController().syncIncremental(source: source, providers: syncProviders)
    }

    /// Sync only playlists incrementally (fast, no library sync)
    public func syncPlaylistsOnly() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let results = await playlistRefreshController.refreshAllServers(
            providers: syncProviders,
            playlistRepository: playlistRepository,
            trigger: .playlistOnly,
            allowFullFallback: false
        )

        for result in results {
            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        }
    }

    // MARK: - Playlist Mutations

    /// Fetch playlists from local cache, optionally scoped to a specific server-level source key.
    public func fetchPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        let playlists = try await playlistRepository.fetchPlaylists(sourceCompositeKey: sourceKey)
        return playlists.map { Playlist(from: $0) }
    }

    private func playlistMutationController() -> PlaylistMutationController {
        PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { serverSourceKey in
                    MediaSourceIdentity.parse(serverSourceKey) != nil
                },
                fetchPlaylists: { [weak self] sourceKey in
                    guard let self else { return [] }
                    return try await self.fetchPlaylists(forServerSourceKey: sourceKey)
                },
                filteredTrackIDsForServer: { [weak self] tracks, serverSourceKey in
                    guard let self else { return [] }
                    return await self.filteredTrackIDsForServer(
                        tracks: tracks,
                        serverSourceKey: serverSourceKey
                    )
                },
                createRemotePlaylist: { [weak self] title, trackIDs, serverSourceKey in
                    guard let self else { throw PlaylistMutationError.invalidSource }
                    try await self.createRemotePlaylist(
                        title: title,
                        trackIDs: trackIDs,
                        serverSourceKey: serverSourceKey
                    )
                },
                reconcileCreatedPlaylist: { [weak self] title, trackIDs, serverSourceKey, isEmptyCreate in
                    guard let self else { return nil }
                    return await self.reconcileCreatedPlaylist(
                        title: title,
                        filteredTrackIds: trackIDs,
                        serverSourceKey: serverSourceKey,
                        isEmptyCreate: isEmptyCreate
                    )
                },
                addTracksToRemotePlaylist: { [weak self] playlistID, trackIDs, serverSourceKey in
                    guard let self else { throw PlaylistMutationError.invalidSource }
                    try await self.addTracksToRemotePlaylist(
                        playlistId: playlistID,
                        trackIDs: trackIDs,
                        serverSourceKey: serverSourceKey
                    )
                },
                renameRemotePlaylist: { [weak self] playlistID, newTitle, serverSourceKey in
                    guard let self else { throw PlaylistMutationError.invalidSource }
                    try await self.renameRemotePlaylist(
                        playlistId: playlistID,
                        newTitle: newTitle,
                        serverSourceKey: serverSourceKey
                    )
                },
                deleteRemotePlaylist: { [weak self] playlistID, serverSourceKey in
                    guard let self else { throw PlaylistMutationError.invalidSource }
                    try await self.deleteRemotePlaylist(
                        playlistId: playlistID,
                        serverSourceKey: serverSourceKey
                    )
                },
                replaceRemotePlaylistContents: { [weak self] playlistID, trackIDs, serverSourceKey in
                    guard let self else { throw PlaylistMutationError.invalidSource }
                    try await self.replaceRemotePlaylistContents(
                        playlistId: playlistID,
                        trackIDs: trackIDs,
                        serverSourceKey: serverSourceKey
                    )
                },
                persistLastPlaylistTarget: { [weak self] playlist in
                    self?.persistLastPlaylistTarget(from: playlist)
                },
                clearLastPlaylistTargetIfNeeded: { [weak self] playlist in
                    self?.clearLastPlaylistTargetIfNeeded(deletedPlaylist: playlist)
                },
                refreshServerPlaylists: { [weak self] serverSourceKey in
                    guard let self else { return }
                    if let refreshServerPlaylistsHandlerForTesting {
                        await refreshServerPlaylistsHandlerForTesting(serverSourceKey)
                    } else {
                        await self.refreshServerPlaylists(serverSourceKey: serverSourceKey)
                    }
                }
            )
        )
    }

    /// Create a new playlist and immediately refresh local cache for that server.
    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        try await playlistMutationController().createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )
    }

    /// Add tracks to an existing playlist and refresh local cache for the playlist's server.
    public func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async throws -> PlaylistMutationResult {
        try await playlistMutationController().addTracksToPlaylist(tracks, playlist: playlist)
    }

    /// Rename a playlist and refresh server playlists.
    public func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws {
        try await playlistMutationController().renamePlaylist(playlist, to: newTitle)
    }

    /// Delete a playlist and refresh server playlists.
    public func deletePlaylist(_ playlist: Playlist) async throws {
        try await playlistMutationController().deletePlaylist(playlist)
    }

    /// Replace playlist contents in the provided order and refresh local cache.
    public func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        try await playlistMutationController().replacePlaylistContents(playlist, with: orderedTracks)
    }

    /// Save queue snapshot tracks to a playlist.
    public func saveQueueSnapshot(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        try await addTracksToPlaylist(tracks, playlist: playlist)
    }

    /// Execute the remote create flow, including the empty-playlist seed fallback.
    private func createRemotePlaylist(
        title: String,
        trackIDs: [String],
        serverSourceKey: String
    ) async throws {
        guard let (server, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        do {
            try await apiClient.createPlaylist(
                title: title,
                trackRatingKeys: trackIDs,
                serverIdentifier: server.serverId
            )
        } catch let error as PlexAPIError {
            guard trackIDs.isEmpty,
                  case .httpError(statusCode: 400) = error,
                  let seedTrackID = await seedTrackIDForServer(
                    serverSourceKey: serverSourceKey,
                    parsedServer: server,
                    apiClient: apiClient
                  ) else {
                throw error
            }

            EnsembleLogger.debug("ℹ️ Empty playlist create returned 400; retrying with seed track fallback")
            try await apiClient.createPlaylist(
                title: title,
                trackRatingKeys: [seedTrackID],
                serverIdentifier: server.serverId
            )

            if let createdPlaylist = try? await apiClient.getPlaylists()
                .first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                try? await apiClient.clearPlaylistItems(playlistId: createdPlaylist.ratingKey)
            }
        }
    }

    /// Reconcile a newly created remote playlist into the local cache and return the target.
    private func reconcileCreatedPlaylist(
        title: String,
        filteredTrackIds: [String],
        serverSourceKey: String,
        isEmptyCreate: Bool
    ) async -> Playlist? {
        guard let (_, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            return nil
        }

        if let createdRemotePlaylist = try? await apiClient.getPlaylists()
            .first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
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

            try? await playlistRepository.setPlaylistTracks(
                isEmptyCreate ? [] : filteredTrackIds,
                forPlaylist: createdRemotePlaylist.ratingKey,
                sourceCompositeKey: serverSourceKey
            )

            return Playlist(
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
        }

        return try? await fetchPlaylists(forServerSourceKey: serverSourceKey)
            .first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
    }

    private func addTracksToRemotePlaylist(
        playlistId: String,
        trackIDs: [String],
        serverSourceKey: String
    ) async throws {
        guard let (server, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        try await apiClient.addItemsToPlaylist(
            playlistId: playlistId,
            trackRatingKeys: trackIDs,
            serverIdentifier: server.serverId
        )
    }

    private func renameRemotePlaylist(
        playlistId: String,
        newTitle: String,
        serverSourceKey: String
    ) async throws {
        guard let (_, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        try await apiClient.renamePlaylist(playlistId: playlistId, newTitle: newTitle)
    }

    private func deleteRemotePlaylist(
        playlistId: String,
        serverSourceKey: String
    ) async throws {
        guard let (_, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        if let playlistDeleteHandlerForTesting {
            try await playlistDeleteHandlerForTesting(apiClient, playlistId)
        } else {
            try await apiClient.deletePlaylist(playlistId: playlistId)
        }
    }

    private func replaceRemotePlaylistContents(
        playlistId: String,
        trackIDs: [String],
        serverSourceKey: String
    ) async throws {
        guard let (server, apiClient) = apiClient(forServerSourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }

        if let playlistReplaceContentsHandlerForTesting {
            try await playlistReplaceContentsHandlerForTesting(apiClient, playlistId, trackIDs, server.serverId)
        } else {
            try await apiClient.clearPlaylistItems(playlistId: playlistId)
            if !trackIDs.isEmpty {
                try await apiClient.addItemsToPlaylist(
                    playlistId: playlistId,
                    trackRatingKeys: trackIDs,
                    serverIdentifier: server.serverId
                )
            }
        }
    }

    /// Perform appropriate sync on app startup based on staleness
    /// - If last full sync > 24 hours: full sync
    /// - If last sync > 1 hour: incremental sync
    /// - Otherwise: skip (data is fresh enough)
    public func performStartupSync() async {
        await syncExecutionController().performStartupSync(providers: syncProviders)
    }

    /// Detect restored stores that have the genre catalog but not the per-item genre fields.
    /// Incremental sync cannot backfill those unchanged albums/tracks, so we force one full repair sync.
    private func sourceNeedsGenreMetadataRepair(_ sourceId: MusicSourceIdentifier) async -> Bool {
        do {
            guard let stats = try await libraryRepository.fetchGenreCoverageStats(forSource: sourceId.compositeKey) else {
                return false
            }

            guard Self.shouldRepairSparseGenreMetadata(stats) else {
                return false
            }

            EnsembleLogger.debug(
                "🧩 Genre coverage repair check for \(sourceId.compositeKey): " +
                "albums=\(stats.albumsWithGenreNames)/\(stats.albumCount), " +
                "tracks=\(stats.tracksWithGenreNames)/\(stats.trackCount), " +
                "genreCatalog=\(stats.genreCatalogCount)"
            )
            return true
        } catch {
            EnsembleLogger.error("Failed to inspect genre coverage for \(sourceId.compositeKey): \(error.localizedDescription)")
            return false
        }
    }

    internal static func shouldRepairSparseGenreMetadata(_ stats: GenreCoverageStats) -> Bool {
        guard stats.genreCatalogCount >= 3 else { return false }
        guard stats.albumCount >= 10 || stats.trackCount >= 50 else { return false }

        let albumCoverage = stats.albumCount > 0
            ? Double(stats.albumsWithGenreNames) / Double(stats.albumCount)
            : 1.0
        let trackCoverage = stats.trackCount > 0
            ? Double(stats.tracksWithGenreNames) / Double(stats.trackCount)
            : 1.0

        return albumCoverage < 0.10 || trackCoverage < 0.10
    }

    private func processReparentedTracks() async {
        let reparentedTracks = libraryRepository.drainTrackReparentInfo()
        if !reparentedTracks.isEmpty {
            EnsembleLogger.debug("[Sync] \(reparentedTracks.count) track(s) reparented — invalidating artwork")
            await onTrackAlbumChanged?(reparentedTracks)
        }
    }

    private func processArtworkInvalidations() async {
        let invalidations = libraryRepository.drainArtworkInvalidationInfo()
            + playlistRepository.drainArtworkInvalidationInfo()
        guard !invalidations.isEmpty else { return }

        EnsembleLogger.debug("[Sync] \(invalidations.count) artwork item(s) changed — invalidating cache")
        await onArtworkMetadataChanged?(invalidations)
    }

    private func syncExecutionController() -> SyncExecutionController {
        SyncExecutionController(
            dependencies: .init(
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                isSyncing: { self.isSyncing },
                setIsSyncing: { self.isSyncing = $0 },
                isOffline: { self.isOffline },
                statusForSource: { self.sourceStatuses[$0] },
                setStatus: { self.sourceStatuses[$0] = $1 },
                loadLastSyncDate: { await self.loadLastSyncDate(for: $0) },
                removeDuplicatePlaylists: { try? await self.playlistRepository.removeDuplicatePlaylists() },
                publishProgress: { self.throttledProgressUpdate(for: $0, mappedProgress: $1) },
                processReparentedTracks: { await self.processReparentedTracks() },
                processArtworkInvalidations: { await self.processArtworkInvalidations() },
                cacheArtworkForSource: { await self.cacheArtworkForSource(sourceId: $0, provider: $1) },
                cacheAlbumArtwork: { await self.cacheAlbumArtwork(sourceId: $0, provider: $1) },
                cacheArtistArtwork: { await self.cacheArtistArtwork(sourceId: $0, provider: $1) },
                cachePlaylistArtwork: { await self.cachePlaylistArtwork(sourceId: $0, provider: $1) },
                notifyPlaylistRefreshCompleted: { self.notifyPlaylistRefreshCompleted(serverSourceKey: $0) },
                connectionStateAfterSuccessfulSync: {
                    await self.serverConnectionController.connectionStateAfterSuccessfulSync(for: $0, fallback: $1)
                },
                publishContentChange: { self.publishContentChangeIfNeeded(for: $0, libraryResult: $1, playlistResult: $2, syncedAt: $3) },
                restoreStatusAfterCancellation: { self.restoreStatusAfterCancellation(for: $0, previousStatus: $1, fallbackConnectionState: $2) },
                syncErrorMessage: { self.syncErrorMessage(for: $0) },
                effectiveConnectionState: { self.effectiveConnectionState(for: $0) },
                postSiriRebuildRequest: { SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed") },
                sourceNeedsGenreMetadataRepair: { await self.sourceNeedsGenreMetadataRepair($0) },
                runStartupHealthChecksIfNeeded: { await self.runStartupHealthChecksIfNeeded(reason: $0, completionMessage: $1) },
                enabledServerKeysForHealthChecks: { self.enabledServerKeysForHealthChecks() },
                isCheckingHealth: { self.isCheckingHealth },
                lastHealthCheckCompletion: { self.lastHealthCheckCompletion },
                updateSourceConnectionStates: { self.updateSourceConnectionStates() },
                setLastStartupSyncCompletion: { self.lastStartupSyncCompletion = $0 }
            )
        )
    }

    /// Ensure the server connection is ready for a given track
    /// This ensures we have a working connection URL before attempting playback
    public func ensureServerConnection(for track: Track) async throws {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }
        try await serverConnectionController.ensureServerConnection(sourceKey: sourceKey)
    }

    public func serverFailureMessage(for track: Track) async -> String? {
        guard let sourceKey = await resolvedTrackSourceCompositeKey(for: track) else {
            return nil
        }
        return serverConnectionController.serverFailureMessage(sourceKey: sourceKey)
    }

    /// Proactively refreshes Plex server connections across configured accounts.
    /// Playback retry paths use this to recover from transient connection failures.
    public func refreshConnection() async throws {
        try await serverConnectionController.refreshConnections()
    }

    /// Get the stream URL for a track, routing to the correct provider
    /// - Parameters:
    ///   - track: The track to stream
    ///   - quality: Streaming quality preference (default: original)
    public func getStreamURL(for track: Track, quality: StreamingQuality = .original) async throws -> StreamResolution {
        EnsembleLogger.debug("🔍 Getting stream URL for track: \(track.title) [quality: \(quality.rawValue)]")
        EnsembleLogger.debug("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        EnsembleLogger.debug("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        EnsembleLogger.debug("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")

        let sourceKey = await resolvedTrackSourceCompositeKey(for: track)
        if let resolution = providerResolver.resolve(sourceKey: sourceKey, allowFallback: true) {
            logStreamProviderResolution(resolution)
            return try await resolution.provider.getStreamURL(
                for: track.id, trackStreamKey: track.streamKey,
                quality: quality, metadataDurationSeconds: track.duration
            )
        }

        EnsembleLogger.debug("❌ No providers available")
        throw PlexAPIError.noServerSelected
    }

    // MARK: - Two-Phase Stream Resolution

    /// Phase 1: Make a streaming decision for a track without embedding the server endpoint URL.
    /// The returned `StreamDecision` can be cached across network transitions — it captures
    /// codec, quality, and session parameters that don't change when the endpoint changes.
    public func makeStreamDecision(
        for track: Track,
        quality: StreamingQuality = .original,
        startTime: TimeInterval = 0
    ) async throws -> StreamDecision {
        let sourceKey = await resolvedTrackSourceCompositeKey(for: track)
        if let resolution = providerResolver.resolvePlex(sourceKey: sourceKey, allowFallback: true) {
            return try await resolution.provider.makeStreamDecision(
                for: track.id, trackStreamKey: track.streamKey,
                quality: quality, metadataDurationSeconds: track.duration, startTime: startTime
            )
        }

        throw PlexAPIError.noServerSelected
    }

    /// Phase 2: Assemble a `StreamResolution` from a cached `StreamDecision` using the
    /// current server endpoint. Call this at download start time for a fresh URL.
    /// This is a lightweight operation (no network calls) — the endpoint is read from
    /// `ServerConnectionRegistry` at assembly time.
    public func assembleStreamResolution(for track: Track, from decision: StreamDecision) async throws -> StreamResolution {
        let sourceKey = await resolvedTrackSourceCompositeKey(for: track)
        if let resolution = providerResolver.resolvePlex(sourceKey: sourceKey, allowFallback: true) {
            return try await resolution.provider.assembleStreamResolution(from: decision)
        }

        throw PlexAPIError.noServerSelected
    }

    /// Get a download URL for offline use, skipping the transcode decision endpoint.
    /// Routes through the provider's dedicated download path which avoids the unnecessary
    /// HTTP roundtrip that the streaming path requires for AVPlayer session warmup.
    public func getDownloadURL(for track: Track, quality: StreamingQuality = .original) async throws -> URL {
        let sourceKey = await resolvedTrackSourceCompositeKey(for: track)
        if let resolution = providerResolver.resolvePlex(sourceKey: sourceKey, allowFallback: true) {
            return try await resolution.provider.getDownloadURL(
                for: track.id,
                trackStreamKey: track.streamKey,
                quality: quality
            )
        }

        throw PlexAPIError.noServerSelected
    }

    /// Get a quality-aware universal stream URL for offline downloading.
    /// Playback should continue using direct stream URLs for AVPlayer compatibility.
    public func getOfflineDownloadURL(for track: Track, quality: StreamingQuality) async throws -> URL {
        let apiClient = try await apiClientForTrack(track)

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
        let apiClient = try await apiClientForTrack(track)

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
        let apiClient = try await apiClientForTrack(track)

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

    private func apiClientForTrack(_ track: Track) async throws -> PlexAPIClient {
        let sourceKey = await resolvedTrackSourceCompositeKey(for: track)
        return try serverConnectionController.requireAPIClient(sourceKey: sourceKey)
    }

    /// Get artwork URL, routing to the correct provider
    public func getArtworkURL(path: String?, sourceKey: String?, size: Int = 300) async throws -> URL? {
        guard let path = path else { return nil }

        if let resolution = providerResolver.resolve(sourceKey: sourceKey, allowFallback: true) {
            return try await resolution.provider.getArtworkURL(path: path, size: size)
        }

        return nil
    }
    
    /// Rate a track, routing to the correct provider.
    /// After a successful rating change, triggers a debounced playlist sync so smart playlists
    /// reflect the updated rating state.
    public func rateTrack(track: Track, rating: Int?) async throws {
        guard let sourceKey = track.sourceCompositeKey else { throw PlexAPIError.noServerSelected }
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)

        try await provider.rateTrack(ratingKey: track.id, rating: rating)

        // Trigger debounced playlist sync so smart playlists reflect the new rating
        refreshOrchestrator.schedulePostRatingPlaylistSync(
            serverSourceKey: sourceKey,
            action: { [weak self] serverSourceKey in
                await self?.refreshServerPlaylists(serverSourceKey: serverSourceKey)
            }
        )

        // Trigger debounced favorites download reconciliation
        refreshOrchestrator.schedulePostRatingFavoritesReconciliation(
            action: { [weak self] in
                await self?.onFavoritesRatingChanged?()
            }
        )
    }

    /// Report playback timeline to Plex server
    /// This updates the server with current playback state and position
    /// - Parameters:
    ///   - track: The currently playing track
    ///   - state: Playback state ("playing", "paused", or "stopped")
    ///   - time: Current playback time in seconds
    public func reportTimeline(track: Track, state: String, time: TimeInterval) async {
        try? await reportTimelineThrowing(track: track, state: state, time: time)
    }

    /// Throwing variant of reportTimeline that propagates errors to the caller.
    /// Used by PlaybackService for failure-aware backoff during offline periods.
    public func reportTimelineThrowing(track: Track, state: String, time: TimeInterval) async throws {
        try await playbackReportingController.reportTimeline(
            track: track,
            state: state,
            time: time,
            providers: syncProviders
        )
    }

    /// Scrobble a track (mark as played)
    /// This should be called when a track reaches ~90% completion
    /// - Parameter track: The track to scrobble
    public func scrobbleTrack(_ track: Track) async {
        do {
            try await scrobbleTrackThrowing(track)
        } catch {
            // Scrobbling is non-critical, just log the error
            EnsembleLogger.debug("⚠️ Failed to scrobble track: \(error.localizedDescription)")
        }
    }

    /// Scrobble a track, throwing on failure so MutationCoordinator can queue retries.
    public func scrobbleTrackThrowing(_ track: Track) async throws {
        try await playbackReportingController.scrobble(track: track, providers: syncProviders)
    }

    /// Get tracks for an album from the music source
    public func getAlbumTracks(albumId: String, sourceKey: String) async throws -> [Track] {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)
        
        return try await provider.getAlbumTracks(albumKey: albumId)
    }

    /// Get albums for an artist from the music source
    public func getArtistAlbums(artistId: String, sourceKey: String) async throws -> [Album] {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)
        
        return try await provider.getArtistAlbums(artistKey: artistId)
    }

    /// Get all tracks for an artist from the music source
    public func getArtistTracks(artistId: String, sourceKey: String) async throws -> [Track] {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)

        return try await provider.getArtistTracks(artistKey: artistId)
    }

    /// Get detailed artist metadata (genres, country, similar artists, styles) from the source
    public func getArtistDetail(artistId: String, sourceKey: String) async throws -> ArtistDetail? {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)

        return try await provider.getArtistDetail(artistKey: artistId)
    }

    /// Get detailed album metadata (genres, styles, studio/label) from the source
    public func getAlbumDetail(albumId: String, sourceKey: String) async throws -> AlbumDetail? {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)

        return try await provider.getAlbumDetail(albumKey: albumId)
    }

    /// Get similar/related albums from Plex's recommendation engine
    public func getSimilarAlbums(albumId: String, sourceKey: String) async throws -> [Album] {
        let provider = try providerResolver.requireProvider(sourceKey: sourceKey)

        return try await provider.getSimilarAlbums(albumKey: albumId)
    }

    /// Delete all CoreData for a removed music source
    public func cleanupRemovedSource(_ sourceId: MusicSourceIdentifier) async {
        do {
            EnsembleLogger.debug("🗑️ Cleaning up data for removed source: \(sourceId.compositeKey)")

            if let sourceCacheCleanupService {
                _ = try await sourceCacheCleanupService.cleanupSource(sourceId.compositeKey)
            } else {
                try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceId.compositeKey)
            }

            // Remove from status tracking
            sourceStatuses.removeValue(forKey: sourceId)

            // Clear API client cache for this source
            accountManager.clearAPIClientCache(accountId: sourceId.accountId, serverId: sourceId.serverId)

            EnsembleLogger.debug("✅ Successfully cleaned up source: \(sourceId.compositeKey)")
        } catch {
            EnsembleLogger.debug("❌ Failed to cleanup source \(sourceId.compositeKey): \(error)")
        }
    }

    /// Best-effort cleanup for removed/disabled sources that are still cached locally.
    /// Used by iCloud library-flag reconciliation to evict stale library data even when
    /// the remote flags match current account state (no transition event).
    public func cleanupRemovedSourcesIfPresent(_ sources: [MusicSourceIdentifier]) async {
        let uniqueSources = Array(Set(sources))
        guard !uniqueSources.isEmpty else { return }

        do {
            let cachedSources = try await libraryRepository.fetchMusicSources()
            let cachedCompositeKeys = Set(cachedSources.compactMap(\.compositeKey))

            for source in uniqueSources where cachedCompositeKeys.contains(source.compositeKey) {
                await cleanupRemovedSource(source)
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to reconcile cached disabled sources: \(error.localizedDescription)")
        }
    }

    /// Delete server-scoped playlists when no enabled libraries remain on that server.
    public func cleanupServerPlaylists(accountId: String, serverId: String) async {
        let serverSourceKey = "plex:\(accountId):\(serverId)"
        do {
            // Collect playlist ratingKeys before deletion for artwork cleanup
            var playlistKeys = Set<String>()
            if let playlists = try? await playlistRepository.fetchPlaylists(sourceCompositeKey: serverSourceKey) {
                for playlist in playlists {
                    playlistKeys.insert(playlist.ratingKey)
                }
            }

            try await playlistRepository.deletePlaylists(sourceCompositeKey: serverSourceKey)
            clearLastPlaylistTargets(forServerSourceKey: serverSourceKey)
            let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
            UserDefaults.standard.removeObject(forKey: timestampKey)

            // Delete cached playlist artwork files
            if !playlistKeys.isEmpty {
                artworkDownloadManager.deleteArtwork(forRatingKeys: playlistKeys)
                EnsembleLogger.debug("🗑️ Deleted \(playlistKeys.count) playlist artwork files for server: \(serverSourceKey)")
            }
        } catch {
            EnsembleLogger.debug("❌ Failed to cleanup server playlists \(serverSourceKey): \(error)")
        }
    }
    
    // MARK: - Artwork Pre-Caching

    /// Cache artwork for all albums, artists, and playlists in a source.
    /// Each helper skips items already cached at detail size, so repeat calls are lightweight.
    private func cacheArtworkForSource(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        await cacheAlbumArtwork(sourceId: sourceId, provider: provider)
        await cacheArtistArtwork(sourceId: sourceId, provider: provider)
        await cachePlaylistArtwork(sourceId: sourceId, provider: provider)
    }

    /// Cache artwork for all albums belonging to a source.
    /// Lightweight — skips albums that already have detail-grade cached artwork on disk.
    private func cacheAlbumArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            let allAlbums = try await libraryRepository.fetchAlbums()
            let sourceAlbums = allAlbums.filter { $0.sourceCompositeKey == sourceId.compositeKey }
            var cached = 0

            for album in sourceAlbums {
                if await artworkDownloadManager.localArtworkExists(
                    for: album,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    continue
                }

                guard let thumbPath = album.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: album.ratingKey,
                            type: .album,
                            sourcePath: thumbPath,
                            dateModified: album.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension
                        )
                    )
                    cached += 1
                } catch {
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for album \(album.title): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) albums (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch albums for artwork caching: \(error.localizedDescription)")
        }
    }

    /// Cache artwork for all artists belonging to a source.
    /// Lightweight — skips artists that already have detail-grade cached artwork on disk.
    private func cacheArtistArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            let allArtists = try await libraryRepository.fetchArtists()
            let sourceArtists = allArtists.filter { $0.sourceCompositeKey == sourceId.compositeKey }
            var cached = 0

            for artist in sourceArtists {
                if await artworkDownloadManager.localArtworkExists(
                    for: artist,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    continue
                }

                guard let thumbPath = artist.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: artist.ratingKey,
                            type: .artist,
                            sourcePath: thumbPath,
                            dateModified: artist.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension
                        )
                    )
                    cached += 1
                } catch {
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for artist \(artist.name): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) artists (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch artists for artwork caching: \(error.localizedDescription)")
        }
    }

    /// Cache composite artwork for all playlists belonging to a source.
    /// Lightweight — skips playlists that already have detail-grade cached artwork on disk.
    private func cachePlaylistArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            // Playlists use a server-level key (plex:account:server), not the
            // library-level compositeKey (plex:account:server:library)
            let serverKey = MediaSourceIdentity.serverSourceKey(from: sourceId.compositeKey) ?? sourceId.compositeKey
            let playlists = try await playlistRepository.fetchPlaylists(sourceCompositeKey: serverKey)
            var cached = 0
            let now = nowProviderForTesting()

            for playlist in playlists {
                if await artworkDownloadManager.localArtworkExists(
                    for: playlist,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    playlistArtworkRetryAfter.removeValue(forKey: playlist.ratingKey)
                    continue
                }

                if let retryAfter = playlistArtworkRetryAfter[playlist.ratingKey], retryAfter > now {
                    continue
                }

                guard let thumbPath = playlist.compositePath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: playlist.ratingKey,
                            type: .playlist,
                            sourcePath: thumbPath,
                            dateModified: playlist.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension
                        )
                    )
                    playlistArtworkRetryAfter.removeValue(forKey: playlist.ratingKey)
                    cached += 1
                } catch {
                    playlistArtworkRetryAfter[playlist.ratingKey] = now.addingTimeInterval(playlistArtworkFailureBackoff)
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for playlist \(playlist.title): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) playlists (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch playlists for artwork caching: \(error.localizedDescription)")
        }
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
        if let parsed = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) {
            return parsed
        }

        if let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id),
           let parsed = MediaSourceIdentity.serverSourceKey(from: cachedTrack.sourceCompositeKey) {
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
            EnsembleLogger.debug("🎵 Resolved missing track source from cache: \(track.id) -> \(source)")
            return source
        }

        // Last resort: single-provider assumption when app is connected to one library source.
        if syncProviders.count == 1, let onlyKey = syncProviders.keys.first {
            EnsembleLogger.debug("🎵 Resolved missing track source via single-provider fallback: \(track.id) -> \(onlyKey)")
            return onlyKey
        }

        EnsembleLogger.debug("⚠️ Could not resolve source key for track: \(track.id)")
        return nil
    }

    private func logStreamProviderResolution(_ resolution: SyncProviderResolver.ProviderResolution) {
        guard !resolution.usedFallback else {
            EnsembleLogger.debug("⚠️ Using fallback provider")
            return
        }

        guard let sourceKey = resolution.sourceKey else {
            EnsembleLogger.debug("🔍 Using provider without source key")
            return
        }

        let components = sourceKey.split(separator: ":")
        guard components.count >= 4 else {
            EnsembleLogger.debug("🔍 Using provider for sourceKey: \(sourceKey)")
            return
        }

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])

        if let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
           let server = account.servers.first(where: { $0.id == serverId }) {
            EnsembleLogger.debug("🔍 Using provider for server: \(server.name) (ID: \(serverId), Library: \(libraryId))")
        } else {
            EnsembleLogger.debug("🔍 Using provider for sourceKey: \(sourceKey)")
        }
    }

    private func hasSingleServerMatching(_ serverSourceKey: String) -> Bool {
        let uniqueServerSources = Set(
            syncProviders.keys.compactMap { key in
                MediaSourceIdentity.serverSourceKey(from: key)
            }
        )
        return uniqueServerSources.count == 1 && uniqueServerSources.first == serverSourceKey
    }

    private func apiClient(forServerSourceKey serverSourceKey: String) -> (MediaSourceIdentity, PlexAPIClient)? {
        guard let server = MediaSourceIdentity.parse(serverSourceKey),
              let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            return nil
        }
        return (server, apiClient)
    }

    private func seedTrackIDForServer(
        serverSourceKey: String,
        parsedServer: MediaSourceIdentity,
        apiClient: PlexAPIClient
    ) async -> String? {
        // Fast path: try local cache first.
        if let allTracks = try? await libraryRepository.fetchTracks(),
           let cachedTrackID = allTracks.first(where: { track in
            guard let trackSourceCompositeKey = track.sourceCompositeKey,
                  let trackServerSourceKey = MediaSourceIdentity.serverSourceKey(from: trackSourceCompositeKey) else {
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
        do {
            guard let result = try await playlistRefreshController.refreshServer(
                serverSourceKey: serverSourceKey,
                providers: syncProviders,
                playlistRepository: playlistRepository,
                trigger: .mutationRefresh,
                allowFullFallback: true
            ) else {
                return
            }

            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        } catch is CancellationError {
            EnsembleLogger.debug("⏹️ SyncCoordinator: Playlist refresh cancelled for \(serverSourceKey)")
        } catch {
            EnsembleLogger.debug("⚠️ SyncCoordinator: Playlist refresh failed for \(serverSourceKey): \(error.localizedDescription)")
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

        EnsembleLogger.debug("🌐 SyncCoordinator: App entering foreground with state \(currentState.description)")
        UserJourneyLogger.log(
            context: "network",
            event: "appForeground",
            details: ["state": currentState.description]
        )

        let decision = networkLifecycleController.foregroundDecision(for: currentState)
        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Foreground decision \(decision.diagnosticSummary)"
        )
        applyOfflineDecision(decision.offlineValue)

        if let request = decision.healthRefreshRequest {
            EnsembleLogger.debug(
                "🌐 SyncCoordinator: Scheduling foreground health refresh force=\(request.forceServerRefresh)"
            )
            scheduleHealthRefresh(reason: request.reason, forceServerRefresh: request.forceServerRefresh)
        } else if decision.offlineValue == true {
            EnsembleLogger.debug("🌐 SyncCoordinator: Foreground health refresh skipped because app is offline")
            updateSourceConnectionStates()
        }
    }

    private func handleObservedNetworkState(_ state: NetworkState) async {
        let decision = networkLifecycleController.observeNetworkState(state)

        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Network transition \(decision.diagnosticSummary)"
        )
        UserJourneyLogger.log(
            context: "network",
            event: "stateChanged",
            details: [
                "from": decision.previousState?.description ?? "nil",
                "to": state.description,
                "transition": decision.transition.logDescription
            ]
        )
        if case .interfaceSwitch(let from, let to) = decision.transition {
            EnsembleLogger.debug("🌐 SyncCoordinator: Detected interface switch \(from.description) -> \(to.description)")
        }

        applyOfflineDecision(decision.offlineValue)
        if decision.offlineValue == true {
            updateSourceConnectionStates()
        }

        if decision.skippedAsInitialTransition {
            return
        }

        if decision.shouldInvalidateConnectionHealth {
            // Invalidate connection health caches on reconnect.
            // Stale endpoints from before the network went down may no longer work
            // (e.g. if IP addresses changed or TLS state is corrupted).
            await serverHealthChecker.invalidateConnectionHealth()
        }

        if decision.shouldInvalidateArtworkConnections {
            // Immediately invalidate artwork URL cache on reconnect.
            // This prevents stale artwork requests that use old endpoint URLs while
            // health checks are still running.
            EnsembleLogger.debug("🖼️ SyncCoordinator: Early artwork cache invalidation for network transition")
            await onConnectionsRefreshed?()
        }

        if let request = decision.healthRefreshRequest {
            scheduleHealthRefresh(reason: request.reason, forceServerRefresh: request.forceServerRefresh)
        }
    }

    private func applyOfflineDecision(_ offlineValue: Bool?) {
        guard let offlineValue else { return }

        if offlineValue {
            if !isOffline { isOffline = true }
        } else if isOffline {
            isOffline = false
        }
    }

    private func scheduleHealthRefresh(reason: RefreshOrchestrator.HealthRefreshReason, forceServerRefresh: Bool) {
        let request = RefreshOrchestrator.HealthRefreshRequest(
            reason: reason,
            forceServerRefresh: forceServerRefresh
        )

        let didSchedule = refreshOrchestrator.scheduleHealthRefresh(
            request: request,
            now: nowProviderForTesting,
            shouldDeferForegroundHealthRefresh: shouldDeferForegroundHealthRefresh,
            eligibleServerKeysProvider: { self.enabledServerKeysForHealthChecks() },
            runRefresh: { [weak self] request, eligibleServerKeys, startedAt in
                guard let self else { return }

                // Capture pre-check states to detect unknown→connected transitions.
                let preCheckStates = self.serverHealthChecker.serverStates

                let summary = await self.runHealthChecks(
                    forceServerRefresh: request.forceServerRefresh,
                    eligibleServerKeys: eligibleServerKeys
                )
                await self.completeHealthRefresh(
                    preCheckStates: preCheckStates,
                    reasonDescription: request.reason.description,
                    summary: summary,
                    startedAt: startedAt,
                    completionMessage: "🌐 SyncCoordinator: Health refresh complete"
                )
            },
            didComplete: { [weak self] completionTime in
                self?.isCheckingHealth = false
                self?.lastHealthCheckCompletion = completionTime
            }
        )

        if didSchedule {
            isCheckingHealth = true
        }
        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Health refresh request reason=\(reason.description) force=\(forceServerRefresh) scheduled=\(didSchedule)"
        )
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

        await serverConnectionController.refreshAPIClientConnections()
    }

    // MARK: - Targeted Server Health Checks

    /// Trigger a health check for a specific server identified by sourceCompositeKey.
    /// Called by PlaybackService when a playback failure indicates the server may be unreachable.
    /// Updates serverStates and source connection states so TrackAvailabilityResolver reacts.
    public func triggerServerHealthCheck(sourceKey: String) async {
        guard let server = MediaSourceIdentity.parse(sourceKey) else { return }

        EnsembleLogger.debug("🏥 SyncCoordinator: Targeted health check for server \(server.accountId):\(server.serverId)")

        let state = await serverHealthChecker.checkServer(
            accountId: server.accountId,
            serverId: server.serverId
        )
        updateSourceConnectionStates()

        EnsembleLogger.debug("🏥 SyncCoordinator: Targeted health check result: \(state)")
    }

    /// Check whether a server is known to be available based on cached health state.
    /// Returns false if the server is offline, degraded-offline, or has no cached state.
    public func isServerAvailable(sourceKey: String?) -> Bool {
        guard let server = MediaSourceIdentity.parse(sourceKey) else {
            return true // Assume available if we can't determine the server
        }
        let serverKey = "\(server.accountId):\(server.serverId)"
        guard let state = serverHealthChecker.serverStates[serverKey] else {
            return true // No cached state means we haven't checked — assume available
        }
        return state.isAvailable
    }

    /// Optimistic availability check for non-critical operations like artwork loading.
    /// Returns true if the server is available OR if health checks haven't completed yet
    /// (.unknown/.connecting). This avoids premature local-file fallback during startup
    /// when health checks are still in flight. Nuke handles network failures gracefully.
    public func isServerPossiblyAvailable(sourceKey: String?) -> Bool {
        guard let server = MediaSourceIdentity.parse(sourceKey) else {
            return true
        }
        let serverKey = "\(server.accountId):\(server.serverId)"
        guard let state = serverHealthChecker.serverStates[serverKey] else {
            return true
        }
        switch state {
        case .connected, .degraded, .unknown, .connecting:
            return true
        case .offline:
            return false
        }
    }

    internal func handleObservedNetworkStateForTesting(_ state: NetworkState) async {
        await handleObservedNetworkState(state)
    }

    internal func awaitHealthRefreshForTesting() async {
        await refreshOrchestrator.awaitHealthRefreshForTesting()
    }

    internal func setLastHealthRefreshForTesting(_ date: Date?) {
        refreshOrchestrator.setLastHealthRefreshForTesting(date)
    }

    internal func installSyncProviderForTesting(
        _ provider: MusicSourceSyncProvider,
        status: MusicSourceStatus? = nil
    ) {
        let source = provider.sourceIdentifier
        syncProviders[source.compositeKey] = provider
        if let status {
            sourceStatuses[source] = status
        } else if sourceStatuses[source] == nil {
            sourceStatuses[source] = MusicSourceStatus()
        }
    }

    /// Update all API clients with the latest working connection URLs from health checks.
    /// When a `ServerConnectionRegistry` is active, most updates flow reactively through
    /// `ServerConnectionController`. This method remains as a fallback for tests and
    /// the non-registry path.
    public func refreshAPIClientConnections() async {
        await serverConnectionController.refreshAPIClientConnections()
    }

    /// Run early health checks at startup and update source connection states.
    /// Routes through the same cooldown tracking as `scheduleHealthRefresh` so
    /// the initial Unknown→Online network transition won't trigger a duplicate pass.
    public func performStartupHealthChecks() async {
        let didRun = await runStartupHealthChecksIfNeeded(
            reason: "early health checks",
            completionMessage: "🏥 SyncCoordinator: Startup health checks complete"
        )
        if !didRun {
            EnsembleLogger.debug("🏥 SyncCoordinator: Skipping early health checks — startup sync already handling them")
        }
    }

    /// Public entry point for callers outside SyncCoordinator (e.g. AppDelegate)
    /// that need to push health-check results into sourceStatuses.
    public func updateSourceConnectionStatesFromAppDelegate() {
        updateSourceConnectionStates()
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

    // MARK: - Provider Access

    /// Returns the PlexAPIClient for a given source composite key, if available.
    /// Used by LyricsService to fetch track metadata and lyrics content.
    public func apiClient(for sourceCompositeKey: String?) -> PlexAPIClient? {
        providerResolver.resolvePlex(
            sourceKey: sourceCompositeKey,
            allowFallback: false
        )?.provider.exposedAPIClient
    }

    // MARK: - Radio Provider Factory

    /// Create a radio provider for a specific music source
    /// Returns nil if the source doesn't support radio or isn't configured
    /// - Parameter sourceKey: The music source composite key
    public func makeRadioProvider(for sourceKey: String) -> RadioProviderProtocol? {
        EnsembleLogger.debug("🔄 SyncCoordinator.makeRadioProvider() called")
        EnsembleLogger.debug("  - Source key: \(sourceKey)")
        
        // Parse source key to extract identifiers
        // Format: sourceType:accountId:serverId:libraryId (e.g., "plex:account123:server456:library789")
        let components = sourceKey.split(separator: ":")
        EnsembleLogger.debug("  - Key components: \(components)")
        EnsembleLogger.debug("  - Component count: \(components.count)")
        
        guard components.count >= 4,
              let sourceType = MusicSourceType(rawValue: String(components[0])) else {
            EnsembleLogger.debug("❌ Invalid source key format: \(sourceKey)")
            return nil
        }
        EnsembleLogger.debug("  - Source type: \(sourceType)")

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])
        EnsembleLogger.debug("  - Account ID: \(accountId)")
        EnsembleLogger.debug("  - Server ID: \(serverId)")
        EnsembleLogger.debug("  - Library ID: \(libraryId)")

        // Currently only Plex is supported
        guard sourceType == .plex else {
            EnsembleLogger.debug("ℹ️ Radio not available for source type: \(sourceType)")
            return nil
        }

        // Get API client for this source
        EnsembleLogger.debug("🔄 Creating API client...")
        guard let apiClient = accountManager.makeAPIClient(
            accountId: accountId,
            serverId: serverId
        ) else {
            EnsembleLogger.debug("❌ Could not create API client for source: \(sourceKey)")
            return nil
        }
        EnsembleLogger.debug("✅ API client created")

        // Create Plex radio provider
        EnsembleLogger.debug("🔄 Creating PlexRadioProvider...")
        let radioProvider = PlexRadioProvider(
            sourceKey: sourceKey,
            apiClient: apiClient,
            libraryRepository: libraryRepository,
            sectionKey: libraryId
        )

        EnsembleLogger.debug("✅ Created PlexRadioProvider for source: \(sourceKey)")
        return radioProvider
    }
    
    // MARK: - Periodic Sync During Active Use
    
    /// Start periodic incremental sync while app is active (every 1 hour)
    public func startPeriodicSync() {
        EnsembleLogger.debug("⏰ Starting periodic sync timer (every 1 hour)")
        periodicSyncController.start { [weak self] in
            await self?.performPeriodicSync()
        }
    }
    
    /// Stop periodic sync
    public func stopPeriodicSync() {
        periodicSyncController.stop()
        EnsembleLogger.debug("🛑 Stopped periodic sync timer")
    }
    
    /// Perform periodic incremental sync (called by timer)
    private func performPeriodicSync() async {
        EnsembleLogger.debug("⏰ Periodic sync triggered")
        
        // Don't sync if offline
        guard !isOffline else {
            EnsembleLogger.debug("📴 Offline - skipping periodic sync")
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            EnsembleLogger.debug("⏳ Sync already in progress - skipping periodic sync")
            return
        }
        
        // Check network connectivity - only sync when connected
        #if os(iOS)
        if !networkMonitor.isConnected {
            EnsembleLogger.debug("📡 Not connected - skipping periodic sync")
            return
        }
        #endif
        
        EnsembleLogger.debug("🔄 Performing periodic incremental sync...")
        await syncAllIncremental()
        EnsembleLogger.debug("✅ Periodic sync complete")
    }

    // MARK: - WebSocket-Triggered Sync

    /// Trigger an incremental sync for a specific library section.
    /// Called by `PlexWebSocketCoordinator` when a library update notification arrives.
    public func syncSectionIncremental(sectionKey: String) async {
        guard !isOffline else {
            EnsembleLogger.debug("🔌 SyncCoordinator: Skipping WebSocket-triggered sync for section \(sectionKey) while offline")
            return
        }

        guard let resolution = webSocketSyncController.resolveSection(
            sectionKey: sectionKey,
            providers: syncProviders,
            knownSources: Set(sourceStatuses.keys)
        ) else {
            EnsembleLogger.error("🔌 SyncCoordinator: No provider found for section \(sectionKey) — providers: \(syncProviders.keys.joined(separator: ", "))")
            return
        }

        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered incremental sync for section \(sectionKey) (source=\(resolution.compositeKey))")

        await syncIncremental(source: resolution.sourceId)

        EnsembleLogger.debug("🔌 SyncCoordinator: Incremental sync completed for section \(sectionKey)")
    }

    /// Trigger a playlist-only sync for a specific server.
    /// Called by `PlexWebSocketCoordinator` when a playlist update notification arrives.
    /// Does not depend on `isSyncing` so it can run alongside library sync.
    public func syncServerPlaylistsIncremental(serverKey: String) async {
        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered playlist sync for server \(serverKey)")

        do {
            guard let result = try await webSocketSyncController.refreshServerPlaylists(
                serverKey: serverKey,
                providers: syncProviders,
                playlistRepository: playlistRepository,
                playlistRefreshController: playlistRefreshController
            ) else {
                EnsembleLogger.error("🔌 SyncCoordinator: No playlist refresh result for server \(serverKey)")
                return
            }
            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            EnsembleLogger.debug("🔌 SyncCoordinator: Playlist sync completed for server \(serverKey), posting notification")
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        } catch is CancellationError {
            EnsembleLogger.debug("⏹️ SyncCoordinator: Playlist sync cancelled for server \(serverKey)")
        } catch {
            EnsembleLogger.error("🔌 SyncCoordinator: Playlist sync failed for server \(serverKey): \(error.localizedDescription)")
        }
    }

    /// Adjust periodic sync intervals based on WebSocket availability.
    /// When WebSocket is active for servers, polling can be relaxed since updates arrive in real-time.
    public func adjustTimersForWebSocket(hasActiveWebSocket: Bool) {
        periodicSyncController.adjustForWebSocket(hasActiveWebSocket: hasActiveWebSocket) { [weak self] in
            await self?.performPeriodicSync()
        }
        if hasActiveWebSocket {
            EnsembleLogger.debug("⏰ SyncCoordinator: WebSocket active — relaxed periodic sync to 4h")
        } else {
            EnsembleLogger.debug("⏰ SyncCoordinator: No WebSocket — using default 1h periodic sync")
        }
    }

    private func notifyPlaylistRefreshCompleted(serverSourceKey: String) {
        onPlaylistRefreshCompleted?(serverSourceKey)
        NotificationCenter.default.post(
            name: Self.playlistsDidRefresh,
            object: nil,
            userInfo: ["serverSourceKey": serverSourceKey]
        )
    }

    private func runStartupHealthChecksIfNeeded(
        reason: String,
        completionMessage: String
    ) async -> Bool {
        let eligibleServers = enabledServerKeysForHealthChecks()
        guard !eligibleServers.isEmpty else { return false }
        isCheckingHealth = true

        let didRun = await refreshOrchestrator.runStartupHealthChecksIfNeeded(
            now: nowProviderForTesting,
            runRefresh: { [weak self] in
                guard let self else { return }
                let healthCheckStart = self.nowProviderForTesting()
                EnsembleLogger.debug("🏥 SyncCoordinator: Running \(reason) for \(eligibleServers.count) server(s)...")

                let preCheckStates = self.serverHealthChecker.serverStates
                let summary = await self.runHealthChecks(
                    forceServerRefresh: false,
                    eligibleServerKeys: eligibleServers
                )
                await self.completeHealthRefresh(
                    preCheckStates: preCheckStates,
                    reasonDescription: reason,
                    summary: summary,
                    startedAt: healthCheckStart,
                    completionMessage: completionMessage
                )
            },
            didComplete: { [weak self] completionTime in
                self?.isCheckingHealth = false
                self?.lastHealthCheckCompletion = completionTime
            }
        )
        if !didRun {
            isCheckingHealth = false
        }
        return didRun
    }

    private func completeHealthRefresh(
        preCheckStates: [String: ServerConnectionState],
        reasonDescription: String,
        summary: ServerHealthChecker.CheckSummary,
        startedAt: Date,
        completionMessage: String
    ) async {
        updateSourceConnectionStates()
        await runAPIClientConnectionRefresh()

        let postCheckStates = serverHealthChecker.serverStates
        let anyBecameAvailable = preCheckStates.contains { key, preState in
            guard !preState.isAvailable else { return false }
            return postCheckStates[key]?.isAvailable == true
        }
        if anyBecameAvailable {
            NotificationCenter.default.post(name: ArtworkLoader.serversBecameAvailable, object: nil)
        }

        let duration = nowProviderForTesting().timeIntervalSince(startedAt)
        EnsembleLogger.debug(
            "\(completionMessage) in \(String(format: "%.2f", duration))s — checked=\(summary.checkedCount), skipped=\(summary.skippedCount), reason=\(reasonDescription)"
        )
    }
}
