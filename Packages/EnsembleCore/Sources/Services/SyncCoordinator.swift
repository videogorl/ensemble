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

public enum PlaylistMutationError: LocalizedError {
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
            print("⏳ syncAllIncremental: Already syncing, skipping")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        print("🔄 syncAllIncremental: Starting...")
        
        // Track which servers have had their playlists synced
        var syncedServerKeys = Set<String>()
        
        for (_, provider) in syncProviders {
            let sourceId = provider.sourceIdentifier
            let currentConnectionState = sourceStatuses[sourceId]?.connectionState ?? .unknown
            
            // Get last sync timestamp
            guard let lastSyncDate = await loadLastSyncDate(for: sourceId) else {
                // No previous sync - fall back to full sync
                print("⚠️ No previous sync found for \(sourceId.compositeKey), performing full sync")
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
            print("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
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
                print("⚠️ Failed to sync playlists for server \(serverKey): \(error.localizedDescription)")
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

        let filteredTrackIds = filteredTrackIDsForServer(tracks: tracks, serverSourceKey: serverSourceKey)
        guard !filteredTrackIds.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        guard let apiClient = accountManager.makeAPIClient(accountId: server.accountId, serverId: server.serverId) else {
            throw PlaylistMutationError.invalidSource
        }

        try await apiClient.createPlaylist(
            title: trimmed,
            trackRatingKeys: filteredTrackIds,
            serverIdentifier: server.serverId
        )

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

        let filteredTrackIds = filteredTrackIDsForServer(tracks: tracks, serverSourceKey: serverSourceKey)
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

        let filteredTrackIds = filteredTrackIDsForServer(tracks: orderedTracks, serverSourceKey: serverSourceKey)
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
        print("🚀 Performing startup sync...")
        
        // Don't sync if offline
        guard !isOffline else {
            print("📴 Offline - skipping startup sync")
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            print("⏳ Sync already in progress - skipping startup sync")
            return
        }
        
        // Check if we have any sources configured
        guard !syncProviders.isEmpty else {
            print("ℹ️ No sync providers configured - skipping startup sync")
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
                    print("⏰ Source \(sourceId.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs full sync")
                    needsFullSync = true
                    break
                } else if hoursSinceSync > 1 {
                    print("⏰ Source \(sourceId.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs incremental sync")
                    needsIncrementalSync = true
                }
            } else {
                print("⏰ Source \(sourceId.compositeKey) has never been synced - needs full sync")
                needsFullSync = true
                break
            }
        }
        
        // Perform appropriate sync
        if needsFullSync {
            print("🔄 Starting full sync on startup...")
            await syncAll()
        } else if needsIncrementalSync {
            print("🔄 Starting incremental sync on startup...")
            await syncAllIncremental()
        } else {
            print("✅ Library is fresh - skipping startup sync")
        }
    }

    /// Ensure the server connection is ready for a given track
    /// This ensures we have a working connection URL before attempting playback
    public func ensureServerConnection(for track: Track) async throws {
        guard let sourceKey = track.sourceCompositeKey else {
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
        print("🔍 Checking server connection before playback...")
        let newState = await serverHealthChecker.checkServer(accountId: accountId, serverId: serverId)
        
        // Update the API client with the working URL
        switch newState {
        case .connected(let url), .degraded(let url):
            if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
                await apiClient.updateCurrentServerURL(url)
                print("✅ Server connection ready for playback: \(url)")
            }
        case .offline:
            print("❌ Server is offline, cannot play track")
            throw PlexAPIError.noServerSelected
        case .connecting, .unknown:
            print("⚠️ Server state uncertain, attempting playback anyway")
        }
    }
    
    /// Get the stream URL for a track, routing to the correct provider
    public func getStreamURL(for track: Track) async throws -> URL {
        print("🔍 Getting stream URL for track: \(track.title)")
        print("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        print("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        print("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")
        
        if let sourceKey = track.sourceCompositeKey,
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
                    print("🔍 Using provider for server: \(server.name) (ID: \(serverId), Library: \(libraryId))")
                } else {
                    print("🔍 Using provider for sourceKey: \(sourceKey)")
                }
            }
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey)
        }

        // Fallback: try any available provider
        if let provider = syncProviders.values.first {
            print("⚠️ Using fallback provider")
            return try await provider.getStreamURL(for: track.id, trackStreamKey: track.streamKey)
        }

        print("❌ No providers available")
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
            print("⚠️ Failed to report timeline: \(error.localizedDescription)")
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
            print("⚠️ Failed to scrobble track: \(error.localizedDescription)")
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
            print("🗑️ Cleaning up data for removed source: \(sourceId.compositeKey)")
            try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceId.compositeKey)
            
            // Remove from status tracking
            sourceStatuses.removeValue(forKey: sourceId)
            
            // Clear API client cache for this source
            accountManager.clearAPIClientCache(accountId: sourceId.accountId, serverId: sourceId.serverId)
            
            print("✅ Successfully cleaned up source: \(sourceId.compositeKey)")
        } catch {
            print("❌ Failed to cleanup source \(sourceId.compositeKey): \(error)")
        }
    }
    
    // MARK: - Artwork Pre-Caching
    
    /// Cache artwork for all albums in a source
    private func cacheArtworkForSource(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            // Fetch all albums for this source
            let allAlbums = try await libraryRepository.fetchAlbums()
            let sourceAlbums = allAlbums.filter { $0.sourceCompositeKey == sourceId.compositeKey }
            
            print("📸 Pre-caching artwork for \(sourceAlbums.count) albums from source \(sourceId.compositeKey)")
            
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
                    print("Failed to cache artwork for album \(album.title): \(error)")
                }
            }
            
            print("✅ Cached \(cachedCount) album artworks")
        } catch {
            print("❌ Failed to cache artwork: \(error)")
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
    private func filteredTrackIDsForServer(tracks: [Track], serverSourceKey targetServerSourceKey: String) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []

        for track in tracks {
            guard let trackServerSource = serverSourceKey(from: track.sourceCompositeKey),
                  trackServerSource == targetServerSourceKey else { continue }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            ids.append(track.id)
        }

        return ids
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
                    print("⚠️ Failed to refresh playlists for \(serverSourceKey): \(error.localizedDescription)")
                }
            }
            return
        }
    }
    
    // MARK: - Network Monitoring
    
    /// Set up observation of network state changes
    private func setupNetworkMonitoring() {
        networkMonitor.$networkState
            .sink { [weak self] state in
                print("🌐 SyncCoordinator.sink: Received network state \(state.description)")
                // Don't await - let the handler run asynchronously
                Task { @MainActor [weak self] in
                    print("🌐 SyncCoordinator.sink: Task spawned, calling handleNetworkChange")
                    self?.handleNetworkChange(state)
                    print("🌐 SyncCoordinator.sink: handleNetworkChange returned")
                }
            }
            .store(in: &cancellables)
    }
    
    /// Handle network state changes
    private func handleNetworkChange(_ state: NetworkState) {
        print("🌐 SyncCoordinator: Network state changed to \(state.description)")

        switch state {
        case .online:
            isOffline = false
            
            // Throttle health checks - don't run if one is already in progress
            // or if we checked within the last 5 seconds
            if isCheckingHealth {
                print("🌐 SyncCoordinator: Health check already in progress, skipping")
                return
            }
            
            if let lastCheck = lastHealthCheckTime,
               Date().timeIntervalSince(lastCheck) < 5.0 {
                print("🌐 SyncCoordinator: Health check too recent (\(Date().timeIntervalSince(lastCheck))s ago), skipping")
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
        print("🔄 SyncCoordinator: Updating API client connections...")

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
                    print("✅ Updated API client for server \(server.name) to use: \(workingURL)")
                } else if case .degraded(let workingURL) = connectionState,
                          let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    await apiClient.updateCurrentServerURL(workingURL)
                    print("⚠️ Updated API client for server \(server.name) to use degraded connection: \(workingURL)")
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
        print("🔄 SyncCoordinator.makeRadioProvider() called")
        print("  - Source key: \(sourceKey)")
        
        // Parse source key to extract identifiers
        // Format: sourceType:accountId:serverId:libraryId (e.g., "plex:account123:server456:library789")
        let components = sourceKey.split(separator: ":")
        print("  - Key components: \(components)")
        print("  - Component count: \(components.count)")
        
        guard components.count >= 4,
              let sourceType = MusicSourceType(rawValue: String(components[0])) else {
            print("❌ Invalid source key format: \(sourceKey)")
            return nil
        }
        print("  - Source type: \(sourceType)")

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])
        print("  - Account ID: \(accountId)")
        print("  - Server ID: \(serverId)")
        print("  - Library ID: \(libraryId)")

        // Currently only Plex is supported
        guard sourceType == .plex else {
            print("ℹ️ Radio not available for source type: \(sourceType)")
            return nil
        }

        // Get API client for this source
        print("🔄 Creating API client...")
        guard let apiClient = accountManager.makeAPIClient(
            accountId: accountId,
            serverId: serverId
        ) else {
            print("❌ Could not create API client for source: \(sourceKey)")
            return nil
        }
        print("✅ API client created")

        // Create Plex radio provider
        print("🔄 Creating PlexRadioProvider...")
        let radioProvider = PlexRadioProvider(
            sourceKey: sourceKey,
            apiClient: apiClient,
            libraryRepository: libraryRepository,
            sectionKey: libraryId
        )

        print("✅ Created PlexRadioProvider for source: \(sourceKey)")
        return radioProvider
    }
    
    // MARK: - Periodic Sync During Active Use
    
    /// Start periodic incremental sync while app is active (every 1 hour)
    public func startPeriodicSync() {
        stopPeriodicSync()  // Stop any existing timer
        
        print("⏰ Starting periodic sync timer (every 1 hour)")
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
        print("🛑 Stopped periodic sync timer")
    }
    
    /// Perform periodic incremental sync (called by timer)
    private func performPeriodicSync() async {
        print("⏰ Periodic sync triggered")
        
        // Don't sync if offline
        guard !isOffline else {
            print("📴 Offline - skipping periodic sync")
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            print("⏳ Sync already in progress - skipping periodic sync")
            return
        }
        
        // Check network connectivity - only sync when connected
        #if os(iOS)
        if !networkMonitor.isConnected {
            print("📡 Not connected - skipping periodic sync")
            return
        }
        #endif
        
        print("🔄 Performing periodic incremental sync...")
        await syncAllIncremental()
        lastIncrementalSyncTime = Date()
        print("✅ Periodic sync complete")
    }
}
