import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, sourceKey: String?, size: Int) -> URL?
    func artworkURLAsync(for path: String?, sourceKey: String?, ratingKey: String?, size: Int) async -> URL?
    func predownloadArtwork(for albums: [CDAlbum], sourceKey: String, size: Int) async throws -> Int
    func predownloadArtwork(for artists: [CDArtist], sourceKey: String, size: Int) async throws -> Int
}

public final class ArtworkLoader: ArtworkLoaderProtocol {
    private let syncCoordinator: SyncCoordinator
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    
    // Using an actor for thread-safe cache access in Swift 6
    private actor URLCacheActor {
        private var cache: [String: URL] = [:]
        
        func get(_ key: String) -> URL? {
            cache[key]
        }
        
        func set(_ key: String, url: URL) {
            cache[key] = url
        }
    }
    
    private let urlCache = URLCacheActor()

    public init(
        syncCoordinator: SyncCoordinator,
        artworkDownloadManager: ArtworkDownloadManagerProtocol = ArtworkDownloadManager()
    ) {
        self.syncCoordinator = syncCoordinator
        self.artworkDownloadManager = artworkDownloadManager
        configurePipeline()
    }

    private func configurePipeline() {
        let config = ImagePipeline.Configuration.withDataCache(
            name: "com.ensemble.artwork",
            sizeLimit: 100 * 1024 * 1024  // 100 MB cache
        )
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    public func artworkURL(for path: String?, sourceKey: String? = nil, size: Int = 300) -> URL? {
        guard let path = path else { return nil }

        let cacheKey = "\(sourceKey ?? ""):\(path):\(size)"
        
        // Note: This method returns nil immediately on first call and triggers background fetch
        // This is a legacy pattern for UI components that can't wait for async.
        // The View will re-render once the cache is populated.
        
        // Fetch asynchronously and cache
        Task {
            // Check cache first via actor
            if await urlCache.get(cacheKey) != nil {
                return
            }
            
            if let url = try? await self.syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: size) {
                await urlCache.set(cacheKey, url: url)
            }
        }

        // Return nil for first render, will update once loaded
        return nil
    }

    /// Async version for modern Swift concurrency
    /// Checks local cache first if ratingKey is provided, otherwise fetches from network
    public func artworkURLAsync(for path: String?, sourceKey: String? = nil, ratingKey: String? = nil, size: Int = 300) async -> URL? {
        guard let path = path else { return nil }
        
        // Check local cache first if we have a ratingKey
        if let key = ratingKey {
            // Try album artwork cache
            let albumFilename = "\(key)_album.jpg"
            let albumPath = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(albumFilename).path
            if FileManager.default.fileExists(atPath: albumPath) {
                return URL(fileURLWithPath: albumPath)
            }
            
            // Try artist artwork cache
            let artistFilename = "\(key)_artist.jpg"
            let artistPath = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(artistFilename).path
            if FileManager.default.fileExists(atPath: artistPath) {
                return URL(fileURLWithPath: artistPath)
            }
        }
        
        // Fall back to network
        return try? await syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: size)
    }
    
    // MARK: - Pre-downloading
    
    /// Pre-download album artwork for offline viewing
    /// Returns the number of artworks successfully downloaded
    public func predownloadArtwork(for albums: [CDAlbum], sourceKey: String, size: Int = 500) async throws -> Int {
        var downloadedCount = 0
        
        for album in albums {
            guard let thumbPath = album.thumbPath else { continue }
            let ratingKey = album.ratingKey
            
            // Check if already cached locally
            if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: album),
               FileManager.default.fileExists(atPath: localPath) {
                continue
            }
            
            // Get the artwork URL from the server
            guard let artworkURL = try? await syncCoordinator.getArtworkURL(
                path: thumbPath,
                sourceKey: sourceKey,
                size: size
            ) else {
                continue
            }
            
            // Download and cache the artwork
            do {
                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: artworkURL,
                    ratingKey: ratingKey,
                    type: ArtworkType.album
                )
                downloadedCount += 1
            } catch {
                print("Failed to download artwork for album \(album.title): \(error)")
                continue
            }
        }
        
        return downloadedCount
    }
    
    /// Pre-download artist artwork for offline viewing
    /// Returns the number of artworks successfully downloaded
    public func predownloadArtwork(for artists: [CDArtist], sourceKey: String, size: Int = 500) async throws -> Int {
        var downloadedCount = 0
        
        for artist in artists {
            guard let thumbPath = artist.thumbPath else { continue }
            let ratingKey = artist.ratingKey
            
            // Check if already cached locally
            if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: artist),
               FileManager.default.fileExists(atPath: localPath) {
                continue
            }
            
            // Get the artwork URL from the server
            guard let artworkURL = try? await syncCoordinator.getArtworkURL(
                path: thumbPath,
                sourceKey: sourceKey,
                size: size
            ) else {
                continue
            }
            
            // Download and cache the artwork
            do {
                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: artworkURL,
                    ratingKey: ratingKey,
                    type: ArtworkType.artist
                )
                downloadedCount += 1
            } catch {
                print("Failed to download artwork for artist \(artist.name): \(error)")
                continue
            }
        }
        
        return downloadedCount
    }
}

// MARK: - Artwork Size Presets

public enum ArtworkSize: Int {
    case tiny = 44
    case thumbnail = 100
    case small = 200
    case medium = 300
    case large = 500
    case extraLarge = 800

    public var cgSize: CGSize {
        CGSize(width: rawValue, height: rawValue)
    }
}
