import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public struct PersistentArtworkCacheHint: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case album
        case artist
        case playlist

        public init?(_ pinnedItemType: PinnedItemType) {
            switch pinnedItemType {
            case .album:
                self = .album
            case .artist:
                self = .artist
            case .playlist:
                self = .playlist
            }
        }

        public init?(_ downloadTargetKind: CDOfflineDownloadTarget.Kind) {
            switch downloadTargetKind {
            case .album:
                self = .album
            case .artist:
                self = .artist
            case .playlist:
                self = .playlist
            case .library, .favorites:
                return nil
            }
        }
    }

    public let ratingKey: String
    public let kind: Kind
    public let sourcePath: String
    public let dateModifiedSeconds: Int?

    public init?(
        ratingKey: String?,
        kind: Kind,
        sourcePath: String?,
        dateModified: Date? = nil
    ) {
        self.init(
            ratingKey: ratingKey,
            kind: kind,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModified.map { Int($0.timeIntervalSince1970) }
        )
    }

    public init?(
        ratingKey: String?,
        kind: Kind,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) {
        guard let ratingKey, !ratingKey.isEmpty,
              let sourcePath, !sourcePath.isEmpty else {
            return nil
        }

        self.ratingKey = ratingKey
        self.kind = kind
        self.sourcePath = sourcePath
        self.dateModifiedSeconds = dateModifiedSeconds
    }
}

public extension PersistentArtworkCacheHint {
    init?(album: Album) {
        self.init(
            ratingKey: album.id,
            kind: .album,
            sourcePath: album.thumbPath,
            dateModified: album.dateModified
        )
    }

    init?(artist: Artist) {
        self.init(
            ratingKey: artist.id,
            kind: .artist,
            sourcePath: artist.thumbPath,
            dateModified: artist.dateModified
        )
    }

    init?(playlist: Playlist) {
        self.init(
            ratingKey: playlist.id,
            kind: .playlist,
            sourcePath: playlist.compositePath,
            dateModified: playlist.dateModified
        )
    }

    init?(fallbackAlbumArtworkFor track: Track) {
        self.init(
            ratingKey: track.fallbackRatingKey,
            kind: .album,
            sourcePath: track.fallbackThumbPath
        )
    }
}

public protocol ArtworkLoaderProtocol {
    func artworkURLAsync(for path: String?, sourceKey: String?, ratingKey: String?, fallbackPath: String?, fallbackRatingKey: String?, size: Int) async -> URL?
    func localArtworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        minimumPixelDimension: Int?,
        allowStaleIdentity: Bool
    ) async -> URL?
    func cacheResolvedArtwork(from url: URL, cacheHint: PersistentArtworkCacheHint?, minimumPixelDimension: Int?) async
    func invalidateURLCache() async
}

public extension ArtworkLoaderProtocol {
    func localArtworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        minimumPixelDimension: Int?,
        allowStaleIdentity: Bool
    ) async -> URL? {
        nil
    }

    func cacheResolvedArtwork(from url: URL, cacheHint: PersistentArtworkCacheHint?, minimumPixelDimension: Int? = nil) async {}
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
    private static let maximumArtworkRequestDimension = ArtworkSize.detail.rawValue
    private static let minimumPersistentArtworkWriteDimension = 500
    
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

    private actor PersistentArtworkCacheTracker {
        private var inFlight: Set<PersistentArtworkCacheHint> = []

        func begin(_ hint: PersistentArtworkCacheHint) -> Bool {
            guard !inFlight.contains(hint) else { return false }
            inFlight.insert(hint)
            return true
        }

        func finish(_ hint: PersistentArtworkCacheHint) {
            inFlight.remove(hint)
        }
    }

    private let persistentCacheTracker = PersistentArtworkCacheTracker()

    private actor StalePersistentArtworkTracker {
        private struct Key: Hashable {
            let ratingKey: String
            let type: ArtworkType
        }

        private var keys: Set<Key> = []

        func mark(ratingKey: String, type: ArtworkType) {
            keys.insert(Key(ratingKey: ratingKey, type: type))
        }

        func clear(ratingKey: String, type: ArtworkType) {
            keys.remove(Key(ratingKey: ratingKey, type: type))
        }

        func contains(ratingKey: String, type: ArtworkType) -> Bool {
            keys.contains(Key(ratingKey: ratingKey, type: type))
        }
    }

    private let stalePersistentArtworkTracker = StalePersistentArtworkTracker()

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
        
        // Limit memory cache for decoded images in RAM.
        // 20 MB / 40 images keeps ~30 MB of CG raster headroom free on 2 GB devices
        // (iPhone 6s measured 50 MB CG raster at idle with the previous 50 MB limit).
        // Disk cache still holds 100 MB so evicted images reload from local storage, not network.
        let memoryCache = ImageCache()
        memoryCache.costLimit = 20 * 1024 * 1024  // 20 MB in memory
        memoryCache.countLimit = 40  // Max 40 decoded images in memory
        config.imageCache = memoryCache
        
        // Enable aggressive memory cache trimming on warnings
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ImagePipeline.shared.cache.removeAll()
            EnsembleLogger.debug("⚠️ Memory warning: Cleared artwork cache")
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
            EnsembleLogger.debug("🎨 ArtworkLoader: Coalesced URL cache invalidation (last was <\(Int(Self.bulkInvalidationCooldown))s ago)")
            return
        }

        lastBulkInvalidationDate = Date()
        await urlCache.clearAll()
        // Connection changed — all tracked URLs are stale
        await artworkURLTracker.clearAll()
        EnsembleLogger.debug("🎨 ArtworkLoader: Invalidated URL cache after connection change")
    }

    /// Invalidate a specific artwork so views re-fetch from the server.
    /// Clears in-memory URL/image cache and marks the persistent file stale, then posts a notification.
    /// The disk file is intentionally preserved so offline sessions can keep showing the last
    /// resolved artwork until a replacement is downloaded.
    public func invalidateArtwork(ratingKey: String, type: ArtworkType) async {
        // Clear URL cache entries containing this ratingKey
        await urlCache.clearEntries(matching: ratingKey)

        await stalePersistentArtworkTracker.mark(ratingKey: ratingKey, type: type)

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

        EnsembleLogger.debug("🎨 ArtworkLoader: Marked artwork stale for ratingKey=\(ratingKey)")
    }

    public func cacheResolvedArtwork(
        from url: URL,
        cacheHint: PersistentArtworkCacheHint?,
        minimumPixelDimension: Int? = nil
    ) async {
        guard let cacheHint, !url.isFileURL else { return }
        if let minimumPixelDimension,
           minimumPixelDimension < Self.minimumPersistentArtworkWriteDimension {
            return
        }
        guard await persistentCacheTracker.begin(cacheHint) else { return }

        let artworkDownloadManager = artworkDownloadManager
        let tracker = persistentCacheTracker
        let staleTracker = stalePersistentArtworkTracker
        Task.detached(priority: .utility) {
            defer {
                Task {
                    await tracker.finish(cacheHint)
                }
            }

            let artworkType = cacheHint.kind.artworkType
            if let localPath = try? await artworkDownloadManager.getLocalArtworkPath(
                ratingKey: cacheHint.ratingKey,
                type: artworkType,
                sourcePath: cacheHint.sourcePath,
                dateModifiedSeconds: cacheHint.dateModifiedSeconds
            ),
               ArtworkFileInspector.fileExists(
                   atPath: localPath,
                   minimumPixelDimension: minimumPixelDimension
               ) {
                return
            }

            do {
                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: url,
                    identity: ArtworkIdentity(
                        ratingKey: cacheHint.ratingKey,
                        type: artworkType,
                        sourcePath: cacheHint.sourcePath,
                        dateModifiedSeconds: cacheHint.dateModifiedSeconds,
                        requestedPixelDimension: minimumPixelDimension
                    )
                )
                await staleTracker.clear(ratingKey: cacheHint.ratingKey, type: artworkType)
                EnsembleLogger.debug("🎨 ArtworkLoader: Persisted \(cacheHint.kind.rawValue) artwork for ratingKey=\(cacheHint.ratingKey)")
            } catch {
                EnsembleLogger.debug("🎨 ArtworkLoader: Failed to persist \(cacheHint.kind.rawValue) artwork for ratingKey=\(cacheHint.ratingKey): \(error.localizedDescription)")
            }
        }
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
        // Cap size to avoid excessive memory usage while still serving retina detail headers.
        let cappedSize = min(size, Self.maximumArtworkRequestDimension)
        // Determine which path and ratingKey to use.
        let actualPath: String?
        let actualRatingKey: String?
        if path != nil && !path!.isEmpty {
            actualPath = path
            actualRatingKey = ratingKey
        } else if fallbackPath != nil && !fallbackPath!.isEmpty {
            actualPath = fallbackPath
            actualRatingKey = fallbackRatingKey
        } else {
            return nil
        }
        
        guard let finalPath = actualPath else { return nil }

        // Prefer local cache when it can satisfy this request. Undersized persistent
        // artwork is allowed as offline fallback, but should not block an online
        // detail surface from fetching and replacing a better image.
        if let localURL = await localCachedArtworkURL(
            ratingKey: actualRatingKey,
            path: finalPath,
            allowStaleIdentity: false,
            minimumPixelDimension: cappedSize
        ) {
            let localCacheKey = "\(sourceKey ?? ""):\(finalPath):\(actualRatingKey ?? ""):local"
            if await urlCache.get(localCacheKey) == nil {
                await urlCache.set(localCacheKey, url: localURL, ttl: Self.asyncArtworkURLCacheTTL)
            }
            return localURL
        }

        let isOffline = await syncCoordinator.isOffline
        // Artwork should wait for a confirmed healthy endpoint. Returning a remote URL
        // while the server is still in .unknown/.connecting can hand the UI a stale
        // pre-health-check endpoint that never resolves, especially on macOS Feed startup.
        let serverAvailable = await syncCoordinator.isServerAvailable(sourceKey: sourceKey)
        let connectivityTag = isOffline ? "offline" : (serverAvailable ? "online" : "server-offline")
        let cacheKey = "\(sourceKey ?? ""):\(finalPath):\(actualRatingKey ?? ""):\(cappedSize):\(connectivityTag)"

        if let cachedURL = await urlCache.get(cacheKey) {
            return cachedURL
        }

        // Server is unavailable and no local cache — return nil immediately
        // rather than building a URL that will time out
        let serverUnavailable = !isOffline && !serverAvailable
        if isOffline || serverUnavailable {
            if let localURL = await localCachedArtworkURL(
                ratingKey: actualRatingKey,
                path: finalPath,
                allowStaleIdentity: true,
                minimumPixelDimension: nil
            ) {
                #if DEBUG
                await loadStats.recordLocalFallback()
                #endif
                return localURL
            }
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
        if let localURL = await localCachedArtworkURL(
            ratingKey: actualRatingKey,
            path: finalPath,
            allowStaleIdentity: true,
            minimumPixelDimension: nil
        ) {
            #if DEBUG
            await loadStats.recordLocalFallback()
            #endif
            return localURL
        }

        return nil
    }

    public func localArtworkURLAsync(
        for path: String?,
        sourceKey: String? = nil,
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        minimumPixelDimension: Int? = nil,
        allowStaleIdentity: Bool = true
    ) async -> URL? {
        let actualPath: String?
        let actualRatingKey: String?
        if let path, !path.isEmpty {
            actualPath = path
            actualRatingKey = ratingKey
        } else if let fallbackPath, !fallbackPath.isEmpty {
            actualPath = fallbackPath
            actualRatingKey = fallbackRatingKey
        } else {
            return nil
        }

        return await localCachedArtworkURL(
            ratingKey: actualRatingKey,
            path: actualPath,
            allowStaleIdentity: allowStaleIdentity,
            minimumPixelDimension: minimumPixelDimension
        )
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
    private func localCachedArtworkURL(
        ratingKey: String?,
        path: String? = nil,
        allowStaleIdentity: Bool,
        minimumPixelDimension: Int?
    ) async -> URL? {
        // Try the passed ratingKey first
        if let key = ratingKey {
            for type in [ArtworkType.album, .artist, .playlist] {
                if await stalePersistentArtworkTracker.contains(ratingKey: key, type: type) {
                    continue
                }
                if let filePath = try? await artworkDownloadManager.getLocalArtworkPath(
                    ratingKey: key,
                    type: type,
                    sourcePath: path,
                    dateModifiedSeconds: nil
                ),
                   ArtworkFileInspector.fileExists(
                       atPath: filePath,
                       minimumPixelDimension: minimumPixelDimension
                   ) {
                    return URL(fileURLWithPath: filePath)
                }
            }

            if allowStaleIdentity {
                for type in [ArtworkType.album, .artist, .playlist] {
                    if let filePath = try? await artworkDownloadManager.getStaleLocalArtworkPath(ratingKey: key, type: type),
                       ArtworkFileInspector.fileExists(
                           atPath: filePath,
                           minimumPixelDimension: minimumPixelDimension
                       ) {
                        return URL(fileURLWithPath: filePath)
                    }
                }
            }
        }

        // Fall back to the ratingKey embedded in the artwork path.
        // Tracks inherit their album's thumbPath (`parentThumb`), so the path
        // contains the album ratingKey while the passed ratingKey is the track's.
        if let path, let pathKey = Self.extractRatingKey(from: path), pathKey != ratingKey {
            for type in [ArtworkType.album, .artist, .playlist] {
                if await stalePersistentArtworkTracker.contains(ratingKey: pathKey, type: type) {
                    continue
                }
                if let filePath = try? await artworkDownloadManager.getLocalArtworkPath(
                    ratingKey: pathKey,
                    type: type,
                    sourcePath: path,
                    dateModifiedSeconds: nil
                ),
                   ArtworkFileInspector.fileExists(
                       atPath: filePath,
                       minimumPixelDimension: minimumPixelDimension
                   ) {
                    return URL(fileURLWithPath: filePath)
                }
            }

            if allowStaleIdentity {
                for type in [ArtworkType.album, .artist, .playlist] {
                    if let filePath = try? await artworkDownloadManager.getStaleLocalArtworkPath(ratingKey: pathKey, type: type),
                       ArtworkFileInspector.fileExists(
                           atPath: filePath,
                           minimumPixelDimension: minimumPixelDimension
                       ) {
                        return URL(fileURLWithPath: filePath)
                    }
                }
            }
        }

        return nil
    }
}

// MARK: - Artwork Size Presets

public enum ArtworkSize: Int {
    case tiny = 44
    case thumbnail = 100
    case card = 160
    case small = 200
    case medium = 300
    case large = 500
    case extraLarge = 800
    case detail = 1000

    public var cgSize: CGSize {
        CGSize(width: rawValue, height: rawValue)
    }
}

private extension PersistentArtworkCacheHint.Kind {
    var artworkType: ArtworkType {
        switch self {
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        }
    }
}
