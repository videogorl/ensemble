import EnsemblePersistence
import Foundation

/// Types of cache that can be managed
public enum CacheType: String, CaseIterable {
    case libraryMetadata = "Library Metadata"
    case albumArtwork = "Album Artwork"
    case downloadedTracks = "Downloaded Tracks"
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
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Coordinates all cache management across the app
@MainActor
public final class CacheManager: ObservableObject {
    @Published public private(set) var cacheInfos: [CacheType: CacheInfo] = [:]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var totalCacheSize: Int64 = 0
    
    private let libraryRepository: LibraryRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let downloadManager: DownloadManagerProtocol
    private let lyricsService: LyricsService

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        downloadManager: DownloadManagerProtocol,
        lyricsService: LyricsService
    ) {
        self.libraryRepository = libraryRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.downloadManager = downloadManager
        self.lyricsService = lyricsService
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
            let downloadSize = try await downloadManager.getTotalDownloadSize()
            let downloads = try await downloadManager.fetchCompletedDownloads()
            infos[.downloadedTracks] = CacheInfo(
                type: .downloadedTracks,
                size: downloadSize,
                itemCount: downloads.count
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
        
        cacheInfos = infos
        totalCacheSize = infos.values.reduce(0) { $0 + $1.size }
    }
    
    /// Clear a specific cache type
    public func clearCache(type: CacheType) async throws {
        switch type {
        case .libraryMetadata:
            try await clearLibraryMetadata()
        case .albumArtwork:
            try await artworkDownloadManager.clearArtworkCache()
        case .downloadedTracks:
            try await clearAllDownloads()
        case .nukeImageCache:
            try await clearNukeImageCache()
        }
        
        await refreshCacheInfo()
    }
    
    /// Clear all caches
    public func clearAllCaches() async throws {
        for type in CacheType.allCases {
            try await clearCache(type: type)
        }
    }
    
    // MARK: - Private Cache Size Calculations
    
    private func getLibraryMetadataSize() async throws -> Int64 {
        // Get CoreData store file size
        let storeURL = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator.persistentStores.first?.url
        guard let url = storeURL else { return 0 }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
    
    private func getLibraryItemCount() async throws -> Int {
        let artists = try await libraryRepository.fetchArtists()
        let albums = try await libraryRepository.fetchAlbums()
        let tracks = try await libraryRepository.fetchTracks()
        return artists.count + albums.count + tracks.count
    }
    
    private func getNukeImageCacheSize() async throws -> Int64 {
        // Nuke stores cache in Library/Caches/com.github.kean.Nuke
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let nukeCacheDir = cacheDir.appendingPathComponent("com.github.kean.Nuke")
        
        guard FileManager.default.fileExists(atPath: nukeCacheDir.path) else { return 0 }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: nukeCacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        
        var totalSize: Int64 = 0
        for url in contents {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int64 {
                totalSize += size
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
        lyricsService.clearAllCaches()
    }
    
    private func clearAllDownloads() async throws {
        let downloads = try await downloadManager.fetchCompletedDownloads()
        for download in downloads {
            if let trackKey = download.track?.ratingKey {
                try await downloadManager.deleteDownload(forTrackRatingKey: trackKey)
            }
        }
    }
    
    private func clearNukeImageCache() async throws {
        // Clear Nuke's disk cache
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let nukeCacheDir = cacheDir.appendingPathComponent("com.github.kean.Nuke")
        
        if FileManager.default.fileExists(atPath: nukeCacheDir.path) {
            try FileManager.default.removeItem(at: nukeCacheDir)
        }
    }
    
    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalCacheSize, countStyle: .file)
    }
}
