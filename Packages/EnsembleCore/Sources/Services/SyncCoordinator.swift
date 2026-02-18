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
    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false
    @Published public private(set) var isOffline = false
    @Published public private(set) var lastPlaylistTarget: LastPlaylistTarget?

    public let accountManager: AccountManager
    public let networkMonitor: NetworkMonitor
    public let serverHealthChecker: ServerHealthChecker
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private var syncProviders: [String: MusicSourceSyncProvider] = [:]  // keyed by compositeKey
    private var cancellables = Set<AnyCancellable>()
    private var isCheckingHealth = false
    private var lastHealthCheckTime: Date?
    
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

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        networkMonitor: NetworkMonitor,
        serverHealthChecker: ServerHealthChecker
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.networkMonitor = networkMonitor
        self.serverHealthChecker = serverHealthChecker
        self.lastPlaylistTargetsByServer = Self.loadLastPlaylistTargetsByServer()
        self.lastPlaylistTarget = Self.loadLastPlaylistTarget()

        // Observe network state changes
        setupNetworkMonitoring()
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
                
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .lastSynced(Date()),
                    connectionState: currentConnectionState
                )
            } catch {
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .error(error.localizedDescription),
                    connectionState: currentConnectionState
                )
            }
        }
    }

    /// Sync a single source
    public func sync(source: MusicSourceIdentifier) async {
        guard let provider = syncProviders[source.compositeKey] else { return }

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
            
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .lastSynced(Date()),
                connectionState: currentConnectionState
            )
        } catch {
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .error(error.localizedDescription),
                connectionState: currentConnectionState
            )
        }
    }
    
    /// Sync all enabled sources incrementally (only fetch changes since last sync)
    public func syncAllIncremental() async {
        guard !isSyncing else {
            #if DEBUG
            print("⏳ syncAllIncremental: Already syncing, skipping")
            #endif
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        #if DEBUG
        print("🔄 syncAllIncremental: Starting...")
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
                print("⚠️ No previous sync found for \(sourceId.compositeKey), performing full sync")
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
                    
                    sourceStatuses[sourceId] = MusicSourceStatus(
                        syncStatus: .lastSynced(Date()),
                        connectionState: currentConnectionState
                    )
                } catch {
                    sourceStatuses[sourceId] = MusicSourceStatus(
                        syncStatus: .error(error.localizedDescription),
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
                
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .lastSynced(Date()),
                    connectionState: currentConnectionState
                )
            } catch {
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .error(error.localizedDescription),
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
            print("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
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
            
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .lastSynced(Date()),
                connectionState: currentConnectionState
            )
        } catch {
            sourceStatuses[source] = MusicSourceStatus(
                syncStatus: .error(error.localizedDescription),
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
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync playlists for server \(serverKey): \(error.localizedDescription)")
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
            print("ℹ️ Empty playlist create returned 400; retrying with seed track fallback")
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

        if let createdPlaylist = try? await fetchPlaylists(forServerSourceKey: serverSourceKey)
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
        print("🚀 Performing startup sync...")
        #endif
        
        // Don't sync if offline
        guard !isOffline else {
            #if DEBUG
            print("📴 Offline - skipping startup sync")
            #endif
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            #if DEBUG
            print("⏳ Sync already in progress - skipping startup sync")
            #endif
            return
        }
        
        // Check if we have any sources configured
        guard !syncProviders.isEmpty else {
            #if DEBUG
            print("ℹ️ No sync providers configured - skipping startup sync")
            #endif
            return
        }
        
        // Determine if we need to sync
        var needsFullSync = false
        var needsIncrementalSync = false
        
        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier
            
            if let lastSyncDate = await loadLastSyncDate(for: sourceId) {
                let hoursSinceSync = Date().timeIntervalSince(lastSyncDate) / 3600
                
                if hoursSinceSync > 24 {
                    #if DEBUG
                    print("⏰ Source \(sourceId.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs full sync")
                    #endif
                    needsFullSync = true
                    break
                } else if hoursSinceSync > 1 {
                    #if DEBUG
                    print("⏰ Source \(sourceId.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs incremental sync")
                    #endif
                    needsIncrementalSync = true
                }
            } else {
                #if DEBUG
                print("⏰ Source \(sourceId.compositeKey) has never been synced - needs full sync")
                #endif
                needsFullSync = true
                break
            }
        }
        
        // Perform appropriate sync
        if needsFullSync {
            #if DEBUG
            print("🔄 Starting full sync on startup...")
            #endif
            await syncAll()
        } else if needsIncrementalSync {
            #if DEBUG
            print("🔄 Starting incremental sync on startup...")
            #endif
            await syncAllIncremental()
        } else {
            #if DEBUG
            print("✅ Library is fresh - skipping startup sync")
            #endif
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
        
        // If already connected or degraded, we're good
        if case .connected = currentState {
            return
        }
        if case .degraded = currentState {
            return
        }
        
        // Need to check server health
        #if DEBUG
        print("🔍 Checking server connection before playback...")
        #endif
        let newState = await serverHealthChecker.checkServer(accountId: accountId, serverId: serverId)
        
        // Update the API client with the working URL
        switch newState {
        case .connected(let url), .degraded(let url):
            if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
                await apiClient.updateCurrentServerURL(url)
                #if DEBUG
                print("✅ Server connection ready for playback: \(url)")
                #endif
            }
        case .offline:
            #if DEBUG
            print("❌ Server is offline, cannot play track")
            #endif
            throw PlexAPIError.noServerSelected
        case .connecting, .unknown:
            #if DEBUG
            print("⚠️ Server state uncertain, attempting playback anyway")
            #endif
        }
    }

    /// Proactively refreshes Plex server connections across configured accounts.
    /// Playback retry paths use this to recover from transient connection failures.
    public func refreshConnection() async throws {
        var refreshedAnyConnection = false

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }
                await apiClient.refreshConnection()
                refreshedAnyConnection = true
            }
        }

        guard refreshedAnyConnection else {
            throw PlexAPIError.noServerSelected
        }
    }
    
    /// Get the stream URL for a track, routing to the correct provider
    public func getStreamURL(for track: Track) async throws -> URL {
        #if DEBUG
        print("🔍 Getting stream URL for track: \(track.title)")
        print("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        print("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        print("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")
        #endif

        if let sourceKey = await resolvedTrackSourceCompositeKey(for: track),
           let provider = syncProviders[sourceKey] {
            // Parse the composite key to extract serverId
            let components = sourceKey.split(separator: ":")
            if components.count >= 3 {
                let accountId = String(components[0])
                let serverId = String(components[1])
                let libraryId = String(components[2])
                
                // Find the server name
                if let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
                   let server = account.servers.first(where: { $0.id == serverId }) {
                    #if DEBUG
                    print("🔍 Using provider for server: \(server.name) (ID: \(serverId), Library: \(libraryId))")
                    #endif
                } else {
                    #if DEBUG
                    print("🔍 Using provider for sourceKey: \(sourceKey)")
                    #endif
                }
            }
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey)
        }

        // Fallback: try any available provider
        if let provider = syncProviders.values.first {
            #if DEBUG
            print("⚠️ Using fallback provider")
            #endif
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey)
        }

        #if DEBUG
        print("❌ No providers available")
        #endif
        throw PlexAPIError.noServerSelected
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
    
    /// Rate a track, routing to the correct provider
    public func rateTrack(track: Track, rating: Int?) async throws {
        guard let sourceKey = track.sourceCompositeKey,
              let provider = syncProviders[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }

        try await provider.rateTrack(ratingKey: track.id, rating: rating)
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
            print("⚠️ Failed to report timeline: \(error.localizedDescription)")
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
            print("⚠️ Failed to scrobble track: \(error.localizedDescription)")
            #endif
        }
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
            print("🗑️ Cleaning up data for removed source: \(sourceId.compositeKey)")
            #endif
            try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceId.compositeKey)
            
            // Remove from status tracking
            sourceStatuses.removeValue(forKey: sourceId)
            
            // Clear API client cache for this source
            accountManager.clearAPIClientCache(accountId: sourceId.accountId, serverId: sourceId.serverId)
            
            #if DEBUG
            print("✅ Successfully cleaned up source: \(sourceId.compositeKey)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to cleanup source \(sourceId.compositeKey): \(error)")
            #endif
        }
    }
    
    // MARK: - Artwork Pre-Caching
    
    /// Cache artwork for all albums in a source
    private func cacheArtworkForSource(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            // Fetch all albums for this source
            let allAlbums = try await libraryRepository.fetchAlbums()
            let sourceAlbums = allAlbums.filter { $0.sourceCompositeKey == sourceId.compositeKey }
            
            #if DEBUG
            print("📸 Pre-caching artwork for \(sourceAlbums.count) albums from source \(sourceId.compositeKey)")
            #endif
            
            var cachedCount = 0
            for (index, album) in sourceAlbums.enumerated() {
                // Update progress (artwork caching is 10% of total, happens at 70-80%)
                let artworkProgress = 0.7 + (0.1 * Double(index) / Double(max(sourceAlbums.count, 1)))
                let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
                sourceStatuses[sourceId] = MusicSourceStatus(
                    syncStatus: .syncing(progress: artworkProgress),
                    connectionState: currentConnectionState
                )
                
                // Skip if already cached
                if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: album),
                   FileManager.default.fileExists(atPath: localPath) {
                    continue
                }
                
                // Get artwork URL from provider
                guard let thumbPath = album.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(path: thumbPath, size: 500) else {
                    continue
                }
                
                // Download and cache
                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        ratingKey: album.ratingKey,
                        type: .album
                    )
                    cachedCount += 1
                } catch {
                    // Continue with next album on error
                    #if DEBUG
                    print("Failed to cache artwork for album \(album.title): \(error)")
                    #endif
                }
            }
            
            #if DEBUG
            print("✅ Cached \(cachedCount) album artworks")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to cache artwork: \(error)")
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
            print("🎵 Resolved missing track source from cache: \(track.id) -> \(source)")
            #endif
            return source
        }

        // Last resort: single-provider assumption when app is connected to one library source.
        if syncProviders.count == 1, let onlyKey = syncProviders.keys.first {
            #if DEBUG
            print("🎵 Resolved missing track source via single-provider fallback: \(track.id) -> \(onlyKey)")
            #endif
            return onlyKey
        }

        #if DEBUG
        print("⚠️ Could not resolve source key for track: \(track.id)")
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
            do {
                try await provider.syncPlaylistsIncremental(to: playlistRepository, progressHandler: { _ in })
            } catch {
                // Fall back to full sync if incremental fails for any reason.
                do {
                    try await provider.syncPlaylists(to: playlistRepository, progressHandler: { _ in })
                } catch {
                    #if DEBUG
                    print("⚠️ Failed to refresh playlists for \(serverSourceKey): \(error.localizedDescription)")
                    #endif
                }
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
            .sink { [weak self] state in
                #if DEBUG
                print("🌐 SyncCoordinator.sink: Received network state \(state.description)")
                #endif
                // Don't await - let the handler run asynchronously
                Task { @MainActor [weak self] in
                    #if DEBUG
                    print("🌐 SyncCoordinator.sink: Task spawned, calling handleNetworkChange")
                    #endif
                    self?.handleNetworkChange(state)
                    #if DEBUG
                    print("🌐 SyncCoordinator.sink: handleNetworkChange returned")
                    #endif
                }
            }
            .store(in: &cancellables)
    }
    
    /// Handle network state changes
    private func handleNetworkChange(_ state: NetworkState) {
        #if DEBUG
        print("🌐 SyncCoordinator: Network state changed to \(state.description)")
        #endif

        switch state {
        case .online:
            isOffline = false
            
            // Throttle health checks - don't run if one is already in progress
            // or if we checked within the last 5 seconds
            if isCheckingHealth {
                #if DEBUG
                print("🌐 SyncCoordinator: Health check already in progress, skipping")
                #endif
                return
            }
            
            if let lastCheck = lastHealthCheckTime,
               Date().timeIntervalSince(lastCheck) < 5.0 {
                #if DEBUG
                print("🌐 SyncCoordinator: Health check too recent (\(Date().timeIntervalSince(lastCheck))s ago), skipping")
                #endif
                return
            }
            
            isCheckingHealth = true
            lastHealthCheckTime = Date()
            
            // Check server health when coming back online (non-blocking)
            // Run in background to avoid blocking UI
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                await self.serverHealthChecker.checkAllServers()
                
                // Update states on main actor after checks complete
                await MainActor.run {
                    self.updateSourceConnectionStates()
                    self.isCheckingHealth = false
                }
                
                // Update API clients with new connection URLs
                await self.refreshAPIClientConnections()
            }

        case .offline, .limited:
            isOffline = true
            updateSourceConnectionStates()

        case .unknown:
            // Don't trigger health checks for unknown state
            break
        }
    }

    /// Update all API clients with the latest working connection URLs from health checks
    public func refreshAPIClientConnections() async {
        #if DEBUG
        print("🔄 SyncCoordinator: Updating API client connections...")
        #endif

        for account in accountManager.plexAccounts {
            for server in account.servers {
                // Get the working URL from health checker
                let connectionState = serverHealthChecker.getServerState(
                    accountId: account.id,
                    serverId: server.id
                )

                // If we found a working URL, update the API client
                if case .connected(let workingURL) = connectionState,
                   let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(workingURL)
                    #if DEBUG
                    print("✅ Updated API client for server \(server.name) to use: \(workingURL)")
                    #endif
                } else if case .degraded(let workingURL) = connectionState,
                          let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(workingURL)
                    #if DEBUG
                    print("⚠️ Updated API client for server \(server.name) to use degraded connection: \(workingURL)")
                    #endif
                }
            }
        }
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
        print("🔄 SyncCoordinator.makeRadioProvider() called")
        print("  - Source key: \(sourceKey)")
        #endif
        
        // Parse source key to extract identifiers
        // Format: sourceType:accountId:serverId:libraryId (e.g., "plex:account123:server456:library789")
        let components = sourceKey.split(separator: ":")
        #if DEBUG
        print("  - Key components: \(components)")
        print("  - Component count: \(components.count)")
        #endif
        
        guard components.count >= 4,
              let sourceType = MusicSourceType(rawValue: String(components[0])) else {
            #if DEBUG
            print("❌ Invalid source key format: \(sourceKey)")
            #endif
            return nil
        }
        #if DEBUG
        print("  - Source type: \(sourceType)")
        #endif

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])
        #if DEBUG
        print("  - Account ID: \(accountId)")
        print("  - Server ID: \(serverId)")
        print("  - Library ID: \(libraryId)")
        #endif

        // Currently only Plex is supported
        guard sourceType == .plex else {
            #if DEBUG
            print("ℹ️ Radio not available for source type: \(sourceType)")
            #endif
            return nil
        }

        // Get API client for this source
        #if DEBUG
        print("🔄 Creating API client...")
        #endif
        guard let apiClient = accountManager.makeAPIClient(
            accountId: accountId,
            serverId: serverId
        ) else {
            #if DEBUG
            print("❌ Could not create API client for source: \(sourceKey)")
            #endif
            return nil
        }
        #if DEBUG
        print("✅ API client created")
        #endif

        // Create Plex radio provider
        #if DEBUG
        print("🔄 Creating PlexRadioProvider...")
        #endif
        let radioProvider = PlexRadioProvider(
            sourceKey: sourceKey,
            apiClient: apiClient,
            libraryRepository: libraryRepository,
            sectionKey: libraryId
        )

        #if DEBUG
        print("✅ Created PlexRadioProvider for source: \(sourceKey)")
        #endif
        return radioProvider
    }
    
    // MARK: - Periodic Sync During Active Use
    
    /// Start periodic incremental sync while app is active (every 1 hour)
    public func startPeriodicSync() {
        stopPeriodicSync()  // Stop any existing timer
        
        #if DEBUG
        print("⏰ Starting periodic sync timer (every 1 hour)")
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
        print("🛑 Stopped periodic sync timer")
        #endif
    }
    
    /// Perform periodic incremental sync (called by timer)
    private func performPeriodicSync() async {
        #if DEBUG
        print("⏰ Periodic sync triggered")
        #endif
        
        // Don't sync if offline
        guard !isOffline else {
            #if DEBUG
            print("📴 Offline - skipping periodic sync")
            #endif
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            #if DEBUG
            print("⏳ Sync already in progress - skipping periodic sync")
            #endif
            return
        }
        
        // Check network connectivity - only sync when connected
        #if os(iOS)
        if !networkMonitor.isConnected {
            #if DEBUG
            print("📡 Not connected - skipping periodic sync")
            #endif
            return
        }
        #endif
        
        #if DEBUG
        print("🔄 Performing periodic incremental sync...")
        #endif
        await syncAllIncremental()
        lastIncrementalSyncTime = Date()
        #if DEBUG
        print("✅ Periodic sync complete")
        #endif
    }
}
