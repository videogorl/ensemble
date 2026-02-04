import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Coordinates syncing across all configured music sources
@MainActor
public final class SyncCoordinator: ObservableObject {
    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false

    public let accountManager: AccountManager
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private var syncProviders: [String: MusicSourceSyncProvider] = [:]  // keyed by compositeKey
    private var cancellables = Set<AnyCancellable>()

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.artworkDownloadManager = artworkDownloadManager
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
                            if let lastSyncDate = await loadLastSyncDate(for: sourceId) {
                                sourceStatuses[sourceId] = .lastSynced(lastSyncDate)
                            } else {
                                sourceStatuses[sourceId] = .idle
                            }
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
            sourceStatuses[sourceId] = .syncing(progress: 0)

            do {
                // Sync library content (artists, albums, tracks, genres)
                try await provider.syncLibrary(
                    to: libraryRepository,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            // Library sync takes up 70% of the progress
                            self?.sourceStatuses[sourceId] = .syncing(progress: progress * 0.7)
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
                                // Playlist sync takes up the remaining 20%
                                self?.sourceStatuses[sourceId] = .syncing(progress: 0.8 + (progress * 0.2))
                            }
                        }
                    )
                }
                
                sourceStatuses[sourceId] = .lastSynced(Date())
            } catch {
                sourceStatuses[sourceId] = .error(error.localizedDescription)
            }
        }
    }

    /// Sync a single source
    public func sync(source: MusicSourceIdentifier) async {
        guard let provider = syncProviders[source.compositeKey] else { return }

        sourceStatuses[source] = .syncing(progress: 0)

        do {
            // Sync library content
            try await provider.syncLibrary(
                to: libraryRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        // Library sync takes up 80% of the progress
                        self?.sourceStatuses[source] = .syncing(progress: progress * 0.8)
                    }
                }
            )
            
            // Sync playlists for this server
            try await provider.syncPlaylists(
                to: playlistRepository,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        // Playlist sync takes up the remaining 20%
                        self?.sourceStatuses[source] = .syncing(progress: 0.8 + (progress * 0.2))
                    }
                }
            )
            
            sourceStatuses[source] = .lastSynced(Date())
        } catch {
            sourceStatuses[source] = .error(error.localizedDescription)
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
                sourceStatuses[sourceId] = .syncing(progress: artworkProgress)
                
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
}
