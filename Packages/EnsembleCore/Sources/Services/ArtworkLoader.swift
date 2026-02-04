import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, sourceKey: String?, size: Int) -> URL?
    func artworkURLAsync(for path: String?, sourceKey: String?, size: Int) async -> URL?
    func predownloadArtwork(for albums: [CDAlbum], sourceKey: String, size: Int) async throws -> Int
    func predownloadArtwork(for artists: [CDArtist], sourceKey: String, size: Int) async throws -> Int
}

public final class ArtworkLoader: ArtworkLoaderProtocol {
    private let syncCoordinator: SyncCoordinator
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private var urlCache: [String: URL] = [:]
    private let cacheLock = NSLock()

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
        
        // Check cache first
        cacheLock.lock()
        if let cachedURL = urlCache[cacheKey] {
            cacheLock.unlock()
            return cachedURL
        }
        cacheLock.unlock()

        // Fetch asynchronously and cache
        Task {
            if let url = try? await self.syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: size) {
                cacheLock.lock()
                urlCache[cacheKey] = url
                cacheLock.unlock()
            }
        }

        // Return nil for first render, will update once loaded
        return nil
    }

    /// Async version for modern Swift concurrency
    public func artworkURLAsync(for path: String?, sourceKey: String? = nil, size: Int = 300) async -> URL? {
        guard let path = path else { return nil }
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
                print("Failed to download artwork for album \(album.title ?? "unknown"): \(error)")
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
                print("Failed to download artwork for artist \(artist.name ?? "unknown"): \(error)")
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
