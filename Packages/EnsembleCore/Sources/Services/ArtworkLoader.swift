import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, sourceKey: String?, size: Int) -> URL?
    func artworkURLAsync(for path: String?, sourceKey: String?, ratingKey: String?, fallbackPath: String?, fallbackRatingKey: String?, size: Int) async -> URL?
    func predownloadArtwork(for albums: [CDAlbum], sourceKey: String, size: Int) async throws -> Int
    func predownloadArtwork(for artists: [CDArtist], sourceKey: String, size: Int) async throws -> Int
    func predownloadArtwork(for playlists: [CDPlaylist], sourceKey: String, size: Int) async throws -> Int
    func invalidateURLCache() async
}

public final class ArtworkLoader: ArtworkLoaderProtocol {
    /// Posted when a specific artwork is invalidated. `userInfo` contains `"ratingKey"`.
    public static let artworkDidInvalidate = Notification.Name("ArtworkLoaderArtworkDidInvalidate")
    /// Posted when servers transition from unknown/connecting to connected after health checks.
    /// ArtworkView listens for this to re-trigger loads that got local-file fallback during startup.
    public static let serversBecameAvailable = Notification.Name("ArtworkLoaderServersBecameAvailable")

    private let syncCoordinator: SyncCoordinator
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private static let asyncArtworkURLCacheTTL: TimeInterval = 60
    private static let legacyArtworkURLCacheTTL: TimeInterval = 60
    
    /// Tracks artwork URLs keyed by ratingKey so we can do targeted Nuke cache eviction
    /// instead of wiping the entire pipeline cache when a single artwork changes.
    private actor ArtworkURLTracker {
        private var urlsByRatingKey: [String: Set<URL>] = [:]

        func record(url: URL, forRatingKey ratingKey: String) {
            urlsByRatingKey[ratingKey, default: []].insert(url)
        }

        func urls(forRatingKey ratingKey: String) -> Set<URL> {
            urlsByRatingKey[ratingKey] ?? []
        }

        func clear(forRatingKey ratingKey: String) {
            urlsByRatingKey.removeValue(forKey: ratingKey)
        }

        func clearAll() {
            urlsByRatingKey.removeAll()
        }
    }

    private let artworkURLTracker = ArtworkURLTracker()

    /// Minimum interval between bulk URL cache invalidations to coalesce
    /// rapid startup events (reconnect, interface switch, health check, etc.)
    private var lastBulkInvalidationDate: Date?
    private static let bulkInvalidationCooldown: TimeInterval = 5

    #if DEBUG
    /// Batch counters for artwork load summary instead of per-item logs.
    /// After a burst of artwork loads settles, a single summary is logged.
    private actor ArtworkLoadStats {
        private var networkCount = 0
        private var localFallbackCount = 0
        private var unavailableCount = 0
        private var pendingSummaryTask: Task<Void, Never>?

        func recordNetwork() { networkCount += 1; scheduleSummary() }
        func recordLocalFallback() { localFallbackCount += 1; scheduleSummary() }
        func recordUnavailable() { unavailableCount += 1; scheduleSummary() }

        private func scheduleSummary() {
            pendingSummaryTask?.cancel()
            pendingSummaryTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s after last load
                guard !Task.isCancelled else { return }
                let n = networkCount; let l = localFallbackCount; let u = unavailableCount
                networkCount = 0; localFallbackCount = 0; unavailableCount = 0
                EnsembleLogger.debug("🎨 ArtworkLoader batch: \(n) network, \(l) local-fallback, \(u) unavailable")
            }
        }
    }
    private let loadStats = ArtworkLoadStats()
    #endif

    // Using an actor for thread-safe cache access in Swift 6
    private actor URLCacheActor {
        private struct Entry {
            let url: URL
            let expiresAt: Date
        }

        private var cache: [String: Entry] = [:]

        func get(_ key: String) -> URL? {
            guard let entry = cache[key] else { return nil }
            if entry.expiresAt <= Date() {
                cache.removeValue(forKey: key)
                return nil
            }
            return entry.url
        }

        func set(_ key: String, url: URL, ttl: TimeInterval) {
            cache[key] = Entry(url: url, expiresAt: Date().addingTimeInterval(ttl))
        }

        /// Clear all cached URL entries (used when server connection changes)
        func clearAll() {
            cache.removeAll()
        }

        /// Clear cached URL entries whose key contains the given substring (e.g. a ratingKey)
        func clearEntries(matching substring: String) {
            for key in cache.keys where key.contains(substring) {
                cache.removeValue(forKey: key)
            }
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
            EnsembleLogger.debug("⚠️ Memory warning: Cleared artwork cache")
            #endif
        }
        #endif
        
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    /// Invalidate all cached artwork URLs.
    /// Called when server connection changes to clear stale URLs pointing to unreachable endpoints.
    /// Coalesces rapid successive calls (e.g. startup reconnect + health check) within a 5s window.
    public func invalidateURLCache() async {
        // Coalesce rapid invalidations during startup
        if let lastDate = lastBulkInvalidationDate,
           Date().timeIntervalSince(lastDate) < Self.bulkInvalidationCooldown {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkLoader: Coalesced URL cache invalidation (last was <\(Int(Self.bulkInvalidationCooldown))s ago)")
            #endif
            return
        }

        lastBulkInvalidationDate = Date()
        await urlCache.clearAll()
        // Connection changed — all tracked URLs are stale
        await artworkURLTracker.clearAll()
        #if DEBUG
        EnsembleLogger.debug("🎨 ArtworkLoader: Invalidated URL cache after connection change")
        #endif
    }

    /// Invalidate a specific artwork so views re-fetch from the server.
    /// Clears both the in-memory URL cache and local file, then posts a notification.
    public func invalidateArtwork(ratingKey: String, type: ArtworkType) async {
        // Clear URL cache entries containing this ratingKey
        await urlCache.clearEntries(matching: ratingKey)

        // Remove the local file
        artworkDownloadManager.deleteArtwork(ratingKey: ratingKey, type: type)

        // Evict tracked URLs from Nuke's cache (targeted instead of clearing all)
        let trackedURLs = await artworkURLTracker.urls(forRatingKey: ratingKey)
        if !trackedURLs.isEmpty {
            for url in trackedURLs {
                let request = ImageRequest(url: url)
                ImagePipeline.shared.cache.removeCachedImage(for: request)
            }
            await artworkURLTracker.clear(forRatingKey: ratingKey)
        } else {
            // No tracked URLs (edge case) — fall back to clearing all
            ImagePipeline.shared.cache.removeAll()
        }

        // Post notification so ArtworkView can re-trigger loads
        NotificationCenter.default.post(
            name: Self.artworkDidInvalidate,
            object: nil,
            userInfo: ["ratingKey": ratingKey]
        )

        #if DEBUG
        EnsembleLogger.debug("🎨 ArtworkLoader: Invalidated artwork for ratingKey=\(ratingKey)")
        #endif
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
                // Track the URL for targeted cache eviction on invalidation
                if let ratingKey = Self.extractRatingKey(from: path) {
                    await self.artworkURLTracker.record(url: url, forRatingKey: ratingKey)
                }
                await urlCache.set(cacheKey, url: url, ttl: Self.legacyArtworkURLCacheTTL)
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
        // Determine which path and ratingKey to use.
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
        } else {
            return nil
        }
        
        guard let finalPath = actualPath else { return nil }
        let isOffline = await syncCoordinator.isOffline
        // Use optimistic check: treat .unknown/.connecting as "possibly available"
        // so artwork attempts the network URL instead of falling back to local files
        // before health checks complete. Nuke handles failures gracefully.
        let serverAvailable = await syncCoordinator.isServerPossiblyAvailable(sourceKey: sourceKey)
        let connectivityTag = isOffline ? "offline" : (serverAvailable ? "online" : "server-offline")
        let cacheKey = "\(sourceKey ?? ""):\(finalPath):\(actualRatingKey ?? ""):\(cappedSize):\(connectivityTag)"

        if let cachedURL = await urlCache.get(cacheKey) {
            return cachedURL
        }

        // When offline or server is known to be unreachable, use local cache directly.
        // This avoids building a network URL that Nuke would time out fetching.
        let serverUnavailable = !isOffline && !serverAvailable
        if (isOffline || serverUnavailable), let localURL = localCachedArtworkURL(ratingKey: actualRatingKey, path: finalPath) {
            #if DEBUG
            await loadStats.recordLocalFallback()
            #endif
            await urlCache.set(cacheKey, url: localURL, ttl: Self.asyncArtworkURLCacheTTL)
            return localURL
        }

        // Server is unavailable and no local cache — return nil immediately
        // rather than building a URL that will time out
        if serverUnavailable {
            #if DEBUG
            await loadStats.recordUnavailable()
            #endif
            return nil
        }

        // Use network to fetch artwork
        let networkURL = try? await syncCoordinator.getArtworkURL(path: finalPath, sourceKey: sourceKey, size: cappedSize)
        if let url = networkURL {
            #if DEBUG
            await loadStats.recordNetwork()
            #endif
            // Track the URL for targeted cache eviction on invalidation
            if let key = actualRatingKey {
                await artworkURLTracker.record(url: url, forRatingKey: key)
            }
            await urlCache.set(cacheKey, url: url, ttl: Self.asyncArtworkURLCacheTTL)
            return url
        }

        // Network URL resolution failed — fall back to local cache if available
        if let localURL = localCachedArtworkURL(ratingKey: actualRatingKey, path: finalPath) {
            #if DEBUG
            await loadStats.recordLocalFallback()
            #endif
            await urlCache.set(cacheKey, url: localURL, ttl: Self.asyncArtworkURLCacheTTL)
            return localURL
        }

        return nil
    }
    
    /// Extract ratingKey from an artwork path like `/library/metadata/{ratingKey}/thumb/...`
    private static func extractRatingKey(from path: String) -> String? {
        let components = path.split(separator: "/")
        // Expected: ["library", "metadata", "{ratingKey}", "thumb", ...]
        guard components.count >= 3,
              components[0] == "library",
              components[1] == "metadata" else { return nil }
        return String(components[2])
    }

    /// Look up locally cached artwork file for a given ratingKey.
    /// Checks album, artist, and playlist artwork caches in order.
    /// Falls back to extracting the ratingKey from the artwork path when the
    /// passed ratingKey doesn't match a cached file (e.g., track ratingKey vs.
    /// album ratingKey embedded in the inherited parentThumb path).
    private func localCachedArtworkURL(ratingKey: String?, path: String? = nil) -> URL? {
        let artworkDir = ArtworkDownloadManager.artworkDirectory

        // Try the passed ratingKey first
        if let key = ratingKey {
            for suffix in ["album", "artist", "playlist"] {
                let filePath = artworkDir.appendingPathComponent("\(key)_\(suffix).jpg").path
                if FileManager.default.fileExists(atPath: filePath) {
                    return URL(fileURLWithPath: filePath)
                }
            }
        }

        // Fall back to the ratingKey embedded in the artwork path.
        // Tracks inherit their album's thumbPath (`parentThumb`), so the path
        // contains the album ratingKey while the passed ratingKey is the track's.
        if let path, let pathKey = Self.extractRatingKey(from: path), pathKey != ratingKey {
            for suffix in ["album", "artist", "playlist"] {
                let filePath = artworkDir.appendingPathComponent("\(pathKey)_\(suffix).jpg").path
                if FileManager.default.fileExists(atPath: filePath) {
                    return URL(fileURLWithPath: filePath)
                }
            }
        }

        return nil
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
                EnsembleLogger.debug("Failed to download artwork for album \(album.title): \(error)")
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
                EnsembleLogger.debug("Failed to download artwork for artist \(artist.name): \(error)")
                #endif
                continue
            }
        }
        
        return downloadedCount
    }
    /// Pre-download playlist artwork for offline viewing using the composite thumb path
    /// Returns the number of artworks successfully downloaded
    public func predownloadArtwork(for playlists: [CDPlaylist], sourceKey: String, size: Int = 500) async throws -> Int {
        var downloadedCount = 0

        for playlist in playlists {
            // Playlists use compositePath for their server-generated composite artwork
            guard let thumbPath = playlist.compositePath else { continue }
            let ratingKey = playlist.ratingKey

            // Skip if already cached
            if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(for: playlist),
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
                    type: .playlist
                )
                downloadedCount += 1
            } catch {
                #if DEBUG
                EnsembleLogger.debug("Failed to download artwork for playlist \(playlist.title): \(error)")
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
