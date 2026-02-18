import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, sourceKey: String?, size: Int) -> URL?
    func artworkURLAsync(for path: String?, sourceKey: String?, ratingKey: String?, fallbackPath: String?, fallbackRatingKey: String?, size: Int) async -> URL?
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
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.ensemble.artwork",
            sizeLimit: 100 * 1024 * 1024  // 100 MB disk cache
        )
        
        // Limit memory cache to 50 MB (default can be 150+ MB)
        // This is the decoded image cache in RAM - critical for 2GB devices
        let memoryCache = ImageCache()
        memoryCache.costLimit = 50 * 1024 * 1024  // 50 MB in memory
        memoryCache.countLimit = 100  // Max 100 images in memory
        config.imageCache = memoryCache
        
        // Enable aggressive memory cache trimming on warnings
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ImagePipeline.shared.cache.removeAll()
            #if DEBUG
            print("⚠️ Memory warning: Cleared artwork cache")
            #endif
        }
        #endif
        
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    public func artworkURL(for path: String?, sourceKey: String? = nil, size: Int = 300) -> URL? {
        guard let path = path else { return nil }

        // Cap size at 1000px to avoid excessive memory usage
        let cappedSize = min(size, 1000)
        let cacheKey = "\(sourceKey ?? ""):\(path):\(cappedSize)"
        
        // Note: This method returns nil immediately on first call and triggers background fetch
        // This is a legacy pattern for UI components that can't wait for async.
        // The View will re-render once the cache is populated.
        
        // Fetch asynchronously and cache
        Task {
            // Check cache first via actor
            if await urlCache.get(cacheKey) != nil {
                return
            }
            
            if let url = try? await self.syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: cappedSize) {
                await urlCache.set(cacheKey, url: url)
            }
        }

        // Return nil for first render, will update once loaded
        return nil
    }

    /// Async version for modern Swift concurrency
    /// Checks local cache first if ratingKey is provided, otherwise fetches from network
    /// Supports fallback artwork (e.g., album artwork for tracks without specific artwork)
    public func artworkURLAsync(
        for path: String?, 
        sourceKey: String? = nil, 
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        size: Int = 300
    ) async -> URL? {
        // Cap size at 1000px to avoid excessive memory usage
        let cappedSize = min(size, 1000)
        // Determine which path and ratingKey to use
        let actualPath: String?
        let actualRatingKey: String?
        let usedFallback: Bool
        
        if path != nil && !path!.isEmpty {
            actualPath = path
            actualRatingKey = ratingKey
            usedFallback = false
        } else if fallbackPath != nil && !fallbackPath!.isEmpty {
            actualPath = fallbackPath
            actualRatingKey = fallbackRatingKey
            usedFallback = true
            #if DEBUG
            print("🔄 ArtworkLoader[\(size)]: Using fallback - track:\(ratingKey ?? "nil") → album:\(fallbackRatingKey ?? "nil") path:\(fallbackPath ?? "nil")")
            #endif
        } else {
            #if DEBUG
            print("❌ ArtworkLoader[\(size)]: No artwork - primary:\(path ?? "nil") fallback:\(fallbackPath ?? "nil")")
            #endif
            return nil
        }
        
        guard let finalPath = actualPath else { return nil }

        // Only use local file cache when offline
        // When online, always use network to get fresh artwork (Nuke handles efficient caching)
        let isOffline = await syncCoordinator.isOffline
        if isOffline, let key = actualRatingKey {
            // Try album artwork cache
            let albumFilename = "\(key)_album.jpg"
            let albumCachePath = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(albumFilename).path
            if FileManager.default.fileExists(atPath: albumCachePath) {
                let url = URL(fileURLWithPath: albumCachePath)
                #if DEBUG
                print("📦 ArtworkLoader[\(size)]: Offline - using local file: \(albumFilename)")
                #endif
                return url
            }

            // Try artist artwork cache
            let artistFilename = "\(key)_artist.jpg"
            let artistCachePath = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(artistFilename).path
            if FileManager.default.fileExists(atPath: artistCachePath) {
                let url = URL(fileURLWithPath: artistCachePath)
                #if DEBUG
                print("📦 ArtworkLoader[\(size)]: Offline - using local file: \(artistFilename)")
                #endif
                return url
            }
        }

        // Use network to fetch artwork
        let networkURL = try? await syncCoordinator.getArtworkURL(path: finalPath, sourceKey: sourceKey, size: cappedSize)
        if let url = networkURL {
            if usedFallback {
                #if DEBUG
                print("✅ ArtworkLoader[\(size)]: Network fallback URL - \(url.absoluteString)")
                #endif
            } else {
                #if DEBUG
                print("🌐 ArtworkLoader[\(size)]: Network URL - \(url.absoluteString)")
                #endif
            }
        }
        return networkURL
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
                #if DEBUG
                print("Failed to download artwork for album \(album.title): \(error)")
                #endif
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
                #if DEBUG
                print("Failed to download artwork for artist \(artist.name): \(error)")
                #endif
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
