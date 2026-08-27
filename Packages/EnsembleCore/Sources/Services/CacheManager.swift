import EnsemblePersistence
import Foundation

/// Types of cache that can be managed
public enum CacheType: String, CaseIterable {
    case libraryMetadata = "Library Metadata"
    case albumArtwork = "Album Artwork"
    case downloadedTracks = "Downloaded Tracks"
    case playbackAudio = "Playback Audio Cache"
    case nukeImageCache = "Image Cache (Nuke)"
    
    public var description: String {
        return rawValue
    }
}

/// Information about a cache type
public struct CacheInfo {
    public let type: CacheType
    public let size: Int64
    public let itemCount: Int?
    
    public init(type: CacheType, size: Int64, itemCount: Int? = nil) {
        self.type = type
        self.size = size
        self.itemCount = itemCount
    }
    
    public var formattedSize: String {
        MediaFormatters.fileBytes(size)
    }
}

/// Privacy-safe cleanup snapshot used to verify destructive cache operations.
public struct CacheCleanupSnapshot: Sendable, Equatable {
    public let libraryItemCount: Int
    public let sourceCount: Int
    public let downloadRecordCount: Int
    public let completedDownloadCount: Int
    public let downloadFileCount: Int
    public let downloadSize: Int64
    public let artworkSize: Int64
    public let playbackAudioSize: Int64
    public let nukeImageCacheSize: Int64

    public var totalFileCacheSize: Int64 {
        downloadSize + artworkSize + playbackAudioSize + nukeImageCacheSize
    }

    public var logDescription: String {
        "libraryItems=\(libraryItemCount), sources=\(sourceCount), downloads=\(downloadRecordCount), completedDownloads=\(completedDownloadCount), downloadFiles=\(downloadFileCount), downloadBytes=\(downloadSize), artworkBytes=\(artworkSize), playbackAudioBytes=\(playbackAudioSize), nukeBytes=\(nukeImageCacheSize), totalFileBytes=\(totalFileCacheSize)"
    }
}

/// Coordinates all cache management across the app
@MainActor
public final class CacheManager: ObservableObject {
    public nonisolated static let libraryDataDidClear = Notification.Name("CacheManagerLibraryDataDidClear")
    public nonisolated static let artworkCachesDidClear = Notification.Name("CacheManagerArtworkCachesDidClear")

    @Published public private(set) var cacheInfos: [CacheType: CacheInfo] = [:]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var totalCacheSize: Int64 = 0
    @Published public private(set) var artworkCacheInvalidationGeneration: UInt64 = 0
    
    private let libraryRepository: LibraryRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let downloadManager: DownloadManagerProtocol
    private let lyricsService: LyricsService
    private let artworkCacheClear: @MainActor () async throws -> Void
    private let playbackArtifactCache = PlaybackArtifactCache.shared
    public var sourceCacheCleanupService: SourceCacheCleaning?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        downloadManager: DownloadManagerProtocol,
        lyricsService: LyricsService,
        artworkCacheClear: (@MainActor () async throws -> Void)? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.downloadManager = downloadManager
        self.lyricsService = lyricsService
        self.artworkCacheClear = artworkCacheClear ?? {
            try await ArtworkLoader.resetSharedPipelineCaches()
            try await artworkDownloadManager.clearArtworkCache()
        }
    }
    
    /// Refresh cache size information for all cache types
    public func refreshCacheInfo() async {
        isRefreshing = true
        defer { isRefreshing = false }
        
        var infos: [CacheType: CacheInfo] = [:]
        
        // Library metadata (CoreData store size)
        do {
            let metadataSize = try await getLibraryMetadataSize()
            let itemCount = try await getLibraryItemCount()
            infos[.libraryMetadata] = CacheInfo(
                type: .libraryMetadata,
                size: metadataSize,
                itemCount: itemCount
            )
        } catch {
            EnsembleLogger.debug("Failed to get library metadata size: \(error)")
        }
        
        // Album artwork cache
        do {
            let artworkSize = try await artworkDownloadManager.getArtworkCacheSize()
            infos[.albumArtwork] = CacheInfo(
                type: .albumArtwork,
                size: artworkSize
            )
        } catch {
            EnsembleLogger.debug("Failed to get artwork cache size: \(error)")
        }
        
        // Downloaded tracks
        do {
            let downloadSize = try getDownloadDirectorySize()
            let downloadCount = try await downloadManager.countCompletedDownloads()
            infos[.downloadedTracks] = CacheInfo(
                type: .downloadedTracks,
                size: downloadSize,
                itemCount: downloadCount
            )
        } catch {
            EnsembleLogger.debug("Failed to get download size: \(error)")
        }
        
        // Nuke image cache (estimate)
        do {
            let nukeSize = try await getNukeImageCacheSize()
            infos[.nukeImageCache] = CacheInfo(
                type: .nukeImageCache,
                size: nukeSize
            )
        } catch {
            EnsembleLogger.debug("Failed to get Nuke cache size: \(error)")
        }

        let playbackAudioSize = playbackArtifactCache.size()
        infos[.playbackAudio] = CacheInfo(
            type: .playbackAudio,
            size: playbackAudioSize
        )
        
        cacheInfos = infos
        totalCacheSize = infos.values.reduce(0) { $0 + $1.size }
    }
    
    /// Clear a specific cache type
    public func clearCache(type: CacheType) async throws {
        let before = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: clearing \(type.rawValue) (before: \(before.logDescription))")
        let clearsLibraryData = type == .libraryMetadata

        switch type {
        case .libraryMetadata:
            try await clearLibraryMetadata()
        case .albumArtwork:
            try await clearArtworkStorageAndConsumers()
        case .downloadedTracks:
            try await clearAllDownloads()
        case .playbackAudio:
            try playbackArtifactCache.removeAll()
        case .nukeImageCache:
            try await clearNukeImageCache()
        }
        
        await refreshCacheInfo()
        let after = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: cleared \(type.rawValue) (after: \(after.logDescription))")
        if clearsLibraryData {
            notifyLibraryDataDidClear()
        }
    }

    /// Clear artwork-only caches without deleting library metadata, downloads, lyrics, or account state.
    public func clearArtworkCaches() async throws {
        let before = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: clearing artwork caches (before: \(before.logDescription))")

        try await clearArtworkStorageAndConsumers()
        await refreshCacheInfo()

        let after = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: cleared artwork caches (after: \(after.logDescription))")
    }

    /// Clears shared transient artwork render caches without touching source-owned durable files.
    public func clearTransientArtworkCaches() async throws {
        try await clearNukeImageCache()
    }
    
    /// Clear all caches
    public func clearAllCaches() async throws {
        let before = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: clearAllCaches starting (before: \(before.logDescription))")

        if let sourceCacheCleanupService {
            let sourceKeys = Set(try await libraryRepository.fetchMusicSources().compactMap(\.compositeKey))
            let result = try await sourceCacheCleanupService.cleanupAllLibraryData(cachedSourceKeys: sourceKeys)
            EnsembleLogger.info("CacheManager: source cleanup worker finished (\(result.logDescription))")
        } else {
            try await clearAllDownloads()
            try await clearLibraryMetadata()
            try await artworkDownloadManager.clearArtworkCache()
        }
        try await clearNukeImageCache()
        await refreshCacheInfo()

        let after = try await cleanupSnapshot()
        EnsembleLogger.info("CacheManager: clearAllCaches finished (after: \(after.logDescription))")
        notifyLibraryDataDidClear()
    }

    /// Captures cache counts and file sizes for verification logs and tests.
    public func cleanupSnapshot() async throws -> CacheCleanupSnapshot {
        async let libraryCount = getLibraryItemCount()
        async let sourceCount = getMusicSourceCount()
        async let allDownloadCount = downloadManager.countDownloads()
        async let completedDownloadCount = downloadManager.countCompletedDownloads()
        let downloadDirectoryStats = try getDownloadDirectoryStats()
        async let artworkSize = artworkDownloadManager.getArtworkCacheSize()
        async let nukeSize = getNukeImageCacheSize()
        let playbackAudioSize = playbackArtifactCache.size()

        return try await CacheCleanupSnapshot(
            libraryItemCount: libraryCount,
            sourceCount: sourceCount,
            downloadRecordCount: allDownloadCount,
            completedDownloadCount: completedDownloadCount,
            downloadFileCount: downloadDirectoryStats.fileCount,
            downloadSize: downloadDirectoryStats.size,
            artworkSize: artworkSize,
            playbackAudioSize: playbackAudioSize,
            nukeImageCacheSize: nukeSize
        )
    }
    
    // MARK: - Private Cache Size Calculations
    
    private func getLibraryMetadataSize() async throws -> Int64 {
        // Get CoreData store file size
        let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator.persistentStores.first?.url
        guard let url = storeURL else { return 0 }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    private func invalidateArtworkCacheConsumers() {
        artworkCacheInvalidationGeneration &+= 1
    }

    private func clearArtworkStorageAndConsumers() async throws {
        // Reset generations first so late requests cannot refill storage after deletion.
        try await artworkCacheClear()
        invalidateArtworkCacheConsumers()
        NotificationCenter.default.post(name: Self.artworkCachesDidClear, object: self)
    }

    private func notifyLibraryDataDidClear() {
        NotificationCenter.default.post(name: Self.libraryDataDidClear, object: self)
    }
    
    private func getLibraryItemCount() async throws -> Int {
        try await libraryRepository.countLibraryMetadataItems()
    }

    private func getDownloadDirectorySize() throws -> Int64 {
        try getDownloadDirectoryStats().size
    }

    private func getDownloadDirectoryStats() throws -> (size: Int64, fileCount: Int) {
        let directory = DownloadManager.downloadsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return (0, 0)
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        )

        var totalSize: Int64 = 0
        var fileCount = 0
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            totalSize += Int64(values.fileSize ?? 0)
        }
        return (totalSize, fileCount)
    }

    private func getMusicSourceCount() async throws -> Int {
        try await libraryRepository.countMusicSources()
    }
    
    private func getNukeImageCacheSize() async throws -> Int64 {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var totalSize: Int64 = 0

        for directoryName in ArtworkLoader.transientCacheDirectoryNames {
            let nukeCacheDir = cacheDir.appendingPathComponent(directoryName)
            guard FileManager.default.fileExists(atPath: nukeCacheDir.path) else { continue }

            let contents = try FileManager.default.contentsOfDirectory(
                at: nukeCacheDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes[.size] as? Int64 {
                    totalSize += size
                }
            }
        }
        
        return totalSize
    }
    
    // MARK: - Private Clear Methods
    
    private func clearLibraryMetadata() async throws {
        // This is destructive - delete all CoreData entities
        // We should confirm with user before calling this
        try await libraryRepository.deleteAllLibraryData()
        // Also clear persistent lyrics cache
        await lyricsService.clearAllCaches()
    }
    
    private func clearAllDownloads() async throws {
        try await downloadManager.deleteAllDownloads()
    }
    
    private func clearNukeImageCache() async throws {
        try await ArtworkLoader.resetSharedPipelineCaches()
        invalidateArtworkCacheConsumers()
    }
    
    public var formattedTotalSize: String {
        MediaFormatters.fileBytes(totalCacheSize)
    }
}
