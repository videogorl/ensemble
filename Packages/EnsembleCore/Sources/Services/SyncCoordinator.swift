import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

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

    /// Get the stream URL for a track, routing to the correct provider
    public func getStreamURL(for track: Track) async throws -> URL {
        print("🔍 Getting stream URL for track: \(track.title)")
        print("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        print("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        print("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")
        
        if let sourceKey = track.sourceCompositeKey,
           let provider = syncProviders[sourceKey] {
            print("🔍 Using provider for sourceKey: \(sourceKey)")
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
                    print("Failed to cache artwork for album \(album.title ?? "unknown"): \(error)")
                }
            }
            
            print("✅ Cached \(cachedCount) album artworks")
        } catch {
            print("❌ Failed to cache artwork: \(error)")
        }
    }
    
    // MARK: - Network Monitoring
    
    /// Set up observation of network state changes
    private func setupNetworkMonitoring() {
        networkMonitor.$networkState
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.handleNetworkChange(state)
                }
            }
            .store(in: &cancellables)
    }
    
    /// Handle network state changes
    private func handleNetworkChange(_ state: NetworkState) async {
        print("🌐 SyncCoordinator: Network state changed to \(state.description)")

        switch state {
        case .online:
            isOffline = false
            // Check server health when coming back online
            await serverHealthChecker.checkAllServers()
            updateSourceConnectionStates()
            // Update API clients with new connection URLs
            await refreshAPIClientConnections()

        case .offline, .limited:
            isOffline = true
            updateSourceConnectionStates()

        case .unknown:
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
}
