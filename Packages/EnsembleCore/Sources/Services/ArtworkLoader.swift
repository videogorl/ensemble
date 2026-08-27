import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func resolve(_ request: ArtworkRequest, policy: ArtworkResolutionPolicy) async -> ArtworkImageResolutionOutcome
    func invalidateURLCache() async
    @MainActor func clearCaches() async throws
}

public extension ArtworkLoaderProtocol {
    func resolve(_ request: ArtworkRequest) async -> ArtworkImageResolutionOutcome {
        await resolve(request, policy: .allowRemote)
    }

    func resolvedImage(for request: ArtworkRequest) async -> ArtworkResolvedImage? {
        guard case .resolved(let image) = await resolve(request) else { return nil }
        return image
    }

    func cachedImage(for request: ArtworkRequest) async -> ArtworkResolvedImage? {
        guard case .resolved(let image) = await resolve(request, policy: .cachedOnly) else { return nil }
        return image
    }

    func blurredImage(
        for image: PlatformImage?,
        cacheKey: String? = nil,
        scheduler: ForegroundWorkScheduling = DependencyContainer.shared.foregroundWorkScheduler,
        requiresIdle: Bool = false
    ) async -> PlatformImage? {
        guard let image else { return nil }
        if let cacheKey,
           let cached = ArtworkBlurRenderer.cachedBlurredImage(forStableKey: cacheKey) {
            return cached
        }
        if let cached = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            return cached
        }

        let kind: ForegroundWorkKind = requiresIdle ? .artworkRetry : .visibleArtworkRetry
        let policy: ForegroundWorkPolicy = requiresIdle ? .idleOnly : .immediate
        guard await scheduler.waitUntilAllowed(kind, policy: policy) else { return nil }

        let sendableImage = SendableArtworkPlatformImage(image)
        let blurred = await Task.detached(priority: .utility) {
            ArtworkBlurRenderer.blurredImage(from: sendableImage.value, stableKey: cacheKey)
                .map(SendableArtworkPlatformImage.init)
        }.value
        return blurred?.value
    }
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
    static let transientCacheDirectoryNames = [
        "com.ensemble.artwork",
        "com.github.kean.Nuke"
    ]

    private struct ArtworkLookup {
        let path: String
        let ratingKey: String?
    }
    
    /// Tracks artwork URLs keyed by ratingKey so we can do targeted Nuke cache eviction
    /// instead of wiping the entire pipeline cache when a single artwork changes.
    private actor ArtworkURLTracker {
        private var urlsByRatingKey: [String: Set<URL>] = [:]
        private var generation: UInt64 = 0

        func currentGeneration() -> UInt64 {
            generation
        }

        func record(url: URL, forRatingKey ratingKey: String, generation expectedGeneration: UInt64) {
            guard generation == expectedGeneration else { return }
            urlsByRatingKey[ratingKey, default: []].insert(url)
        }

        func urls(forRatingKey ratingKey: String) -> Set<URL> {
            urlsByRatingKey[ratingKey] ?? []
        }

        func clear(forRatingKey ratingKey: String) {
            urlsByRatingKey.removeValue(forKey: ratingKey)
        }

        func clearAll() {
            generation &+= 1
            urlsByRatingKey.removeAll()
        }
    }

    private let artworkURLTracker = ArtworkURLTracker()
    private var memoryWarningObserver: NSObjectProtocol?

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
        private var inFlight: Set<ArtworkRequest.Identity> = []

        func begin(_ identity: ArtworkRequest.Identity) -> Bool {
            guard !inFlight.contains(identity) else { return false }
            inFlight.insert(identity)
            return true
        }

        func finish(_ identity: ArtworkRequest.Identity) {
            inFlight.remove(identity)
        }
    }

    private let persistentCacheTracker = PersistentArtworkCacheTracker()

    private actor StalePersistentArtworkTracker {
        private struct Key: Hashable {
            let ratingKey: String
            let type: ArtworkType
            let sourceCompositeKey: String?
        }

        private var keys: Set<Key> = []

        func mark(ratingKey: String, type: ArtworkType, sourceCompositeKey: String? = nil) {
            keys.insert(Key(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            ))
        }

        func clear(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?) {
            keys.remove(Key(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            ))
            keys.remove(Key(ratingKey: ratingKey, type: type, sourceCompositeKey: nil))
        }

        func contains(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?) -> Bool {
            keys.contains(Key(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            )) || keys.contains(Key(ratingKey: ratingKey, type: type, sourceCompositeKey: nil))
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
        private var generation: UInt64 = 0

        func currentGeneration() -> UInt64 {
            generation
        }

        func isCurrent(_ expectedGeneration: UInt64) -> Bool {
            generation == expectedGeneration
        }

        func get(_ key: String) -> URL? {
            guard let entry = cache[key] else { return nil }
            if entry.expiresAt <= Date() {
                cache.removeValue(forKey: key)
                return nil
            }
            return entry.url
        }

        func set(
            _ key: String,
            url: URL,
            ttl: TimeInterval,
            generation expectedGeneration: UInt64
        ) {
            guard generation == expectedGeneration else { return }
            cache[key] = Entry(url: url, expiresAt: Date().addingTimeInterval(ttl))
        }

        /// Clear all cached URL entries (used when server connection changes)
        func clearAll() {
            generation &+= 1
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
        installMemoryWarningObserver()
    }

    public func resolve(
        _ request: ArtworkRequest,
        policy: ArtworkResolutionPolicy
    ) async -> ArtworkImageResolutionOutcome {
        if let local = await locallyCachedImage(for: request, minimumPixelDimension: request.tier.rawValue) {
            return .resolved(local)
        }
        guard policy == .allowRemote else { return .unavailable(.noArtworkURL) }

        var failedURL: URL?
        for candidate in request.candidates {
            let url = await artworkURLAsync(
                for: candidate.path,
                sourceKey: candidate.sourceKey,
                ratingKey: candidate.ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                size: candidate.tier.rawValue
            )

            if let url {
                if let localURL = await cacheRemoteArtwork(
                    from: url,
                    identity: candidate.identity?.scoped(to: candidate.sourceKey),
                    minimumPixelDimension: candidate.tier.rawValue
                ), let resolved = await image(at: localURL, for: candidate) {
                    return .resolved(resolved)
                }
                if let resolved = await image(at: url, for: candidate) {
                    return .resolved(resolved)
                }
                failedURL = url
            }

            if let local = await locallyCachedImage(for: candidate, minimumPixelDimension: nil),
               local.url != url {
                return .resolved(local)
            }
        }

        return failedURL.map { .unavailable(.imageLoadFailed($0)) } ?? .unavailable(.noArtworkURL)
    }

    @MainActor
    public func clearCaches() async throws {
        try await resetTransientCaches()
        try await artworkDownloadManager.clearArtworkCache()
    }

    private func locallyCachedImage(
        for request: ArtworkRequest,
        minimumPixelDimension: Int?
    ) async -> ArtworkResolvedImage? {
        for candidate in request.candidates {
            guard let localURL = await localArtworkURLAsync(
                for: candidate.path,
                sourceKey: candidate.sourceKey,
                ratingKey: candidate.ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                minimumPixelDimension: minimumPixelDimension,
                allowStaleIdentity: true
            ), let resolved = await image(at: localURL, for: candidate) else {
                continue
            }
            return resolved
        }
        return nil
    }

    private func image(at url: URL, for request: ArtworkRequest) async -> ArtworkResolvedImage? {
        let imageRequest = ArtworkImageRequest.resized(
            url: url,
            size: request.tier.rawValue,
            priority: request.priority.nukePriority
        )
        let image: PlatformImage?
        if let cached = ImagePipeline.shared.cache.cachedImage(for: imageRequest)?.image {
            image = cached
        } else {
            image = try? await ImagePipeline.shared.image(for: imageRequest)
        }
        return image.map {
            ArtworkResolvedImage(
                url: url,
                image: $0,
                blurCacheKey: request.stableBlurCacheKey,
                identityKey: request.stableIdentityKey
            )
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    private func configurePipeline() {
        ImagePipeline.shared = Self.makeImagePipeline()
    }

    private static func makeImagePipeline() -> ImagePipeline {
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

        return ImagePipeline(configuration: config)
    }

    private func installMemoryWarningObserver() {
        // Enable aggressive memory cache trimming on warnings
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ImagePipeline.shared.cache.removeAll()
            ArtworkBlurRenderer.clearMemoryCache()
            EnsembleLogger.debug("⚠️ Memory warning: Cleared artwork and blur caches")
        }
        #endif
    }

    /// Cancels transient image work, clears bounded render caches, and installs a fresh pipeline.
    @MainActor
    func resetTransientCaches() async throws {
        await urlCache.clearAll()
        await artworkURLTracker.clearAll()
        lastBulkInvalidationDate = nil
        try await Self.resetSharedPipelineCaches()
    }

    @MainActor
    static func resetSharedPipelineCaches() async throws {
        let oldPipeline = ImagePipeline.shared
        oldPipeline.invalidate()
        defer { ImagePipeline.shared = makeImagePipeline() }

        // Enqueueing a request after invalidation provides a barrier for Nuke's
        // pipeline queue, so cancelled work cannot repopulate the cache we clear.
        let barrierURL = URL(fileURLWithPath: "/dev/null")
        _ = try? await oldPipeline.image(for: ImageRequest(url: barrierURL))
        oldPipeline.cache.removeAll()
        if let dataCache = oldPipeline.configuration.dataCache as? DataCache {
            dataCache.flush()
        }

        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for directoryName in transientCacheDirectoryNames {
            let directory = cacheDirectory.appendingPathComponent(directoryName)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }

        ArtworkBlurRenderer.clearCache()
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
        NotificationCenter.default.post(name: Self.serversBecameAvailable, object: self)
    }

    /// Invalidate a specific artwork so views re-fetch from the server.
    /// Clears in-memory URL/image cache and marks the persistent file stale, then posts a notification.
    /// The disk file is intentionally preserved so offline sessions can keep showing the last
    /// resolved artwork until a replacement is downloaded.
    public func invalidateArtwork(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String? = nil
    ) async {
        await invalidateArtwork([
            ArtworkInvalidationInfo(
                ratingKey: ratingKey,
                type: type,
                reason: .metadataModified,
                sourceCompositeKey: sourceCompositeKey
            )
        ])
    }

    public func invalidateArtwork(_ invalidations: [ArtworkInvalidationInfo]) async {
        let invalidations = Array(Set(invalidations))
        guard !invalidations.isEmpty else { return }

        var trackedURLs = Set<URL>()
        let ratingKeys = Set(invalidations.map(\.ratingKey))
        for invalidation in invalidations {
            await urlCache.clearEntries(matching: invalidation.ratingKey)
            await stalePersistentArtworkTracker.mark(
                ratingKey: invalidation.ratingKey,
                type: invalidation.type,
                sourceCompositeKey: invalidation.sourceCompositeKey
            )
            trackedURLs.formUnion(
                await artworkURLTracker.urls(forRatingKey: invalidation.ratingKey)
            )
            await artworkURLTracker.clear(forRatingKey: invalidation.ratingKey)
        }

        if trackedURLs.isEmpty {
            ImagePipeline.shared.cache.removeAll()
        } else {
            for url in trackedURLs {
                ImagePipeline.shared.cache.removeCachedImage(for: ImageRequest(url: url))
                for size in [160, 512, 1_000] {
                    ImagePipeline.shared.cache.removeCachedImage(
                        for: ArtworkImageRequest.resized(url: url, size: size)
                    )
                }
            }
        }

        NotificationCenter.default.post(
            name: Self.artworkDidInvalidate,
            object: nil,
            userInfo: ["ratingKeys": ratingKeys]
        )
        EnsembleLogger.debug("🎨 ArtworkLoader: Marked \(invalidations.count) artwork item(s) stale")
    }

    func cacheRemoteArtwork(
        from url: URL,
        identity: ArtworkRequest.Identity?,
        minimumPixelDimension: Int? = nil
    ) async -> URL? {
        guard let identity, !url.isFileURL else { return nil }
        let scopedIdentity = identity.scoped(to: identity.sourceCompositeKey)
        if let minimumPixelDimension,
           minimumPixelDimension < Self.minimumPersistentArtworkWriteDimension {
            return nil
        }
        guard await persistentCacheTracker.begin(scopedIdentity) else { return nil }

        guard let sourceCompositeKey = scopedIdentity.sourceCompositeKey,
              let persistenceHandle = await syncCoordinator.beginCurrentSourcePersistenceWork(
                  sourceKey: sourceCompositeKey
              ) else {
            await persistentCacheTracker.finish(scopedIdentity)
            return nil
        }

        let generation = await urlCache.currentGeneration()
        let artworkType = scopedIdentity.kind.artworkType
        var resolvedLocalURL: URL?

        if await artworkDownloadManager.localArtworkExists(
            ratingKey: scopedIdentity.ratingKey,
            type: artworkType,
            sourceCompositeKey: scopedIdentity.sourceCompositeKey,
            sourcePath: scopedIdentity.sourcePath,
            dateModifiedSeconds: scopedIdentity.dateModifiedSeconds,
            minimumPixelDimension: minimumPixelDimension
        ),
           let localPath = try? await artworkDownloadManager.getLocalArtworkPath(
               ratingKey: scopedIdentity.ratingKey,
               type: artworkType,
               sourceCompositeKey: scopedIdentity.sourceCompositeKey,
               sourcePath: scopedIdentity.sourcePath,
               dateModifiedSeconds: scopedIdentity.dateModifiedSeconds
           ) {
            resolvedLocalURL = URL(fileURLWithPath: localPath)
        } else {
            do {
                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: url,
                    identity: ArtworkIdentity(
                        ratingKey: scopedIdentity.ratingKey,
                        type: artworkType,
                        sourcePath: scopedIdentity.sourcePath,
                        dateModifiedSeconds: scopedIdentity.dateModifiedSeconds,
                        requestedPixelDimension: minimumPixelDimension,
                        sourceCompositeKey: scopedIdentity.sourceCompositeKey
                    )
                )
                if await urlCache.isCurrent(generation),
                   let localPath = try? await artworkDownloadManager.getLocalArtworkPath(
                       ratingKey: scopedIdentity.ratingKey,
                       type: artworkType,
                       sourceCompositeKey: scopedIdentity.sourceCompositeKey,
                       sourcePath: scopedIdentity.sourcePath,
                       dateModifiedSeconds: scopedIdentity.dateModifiedSeconds
                   ) {
                    await stalePersistentArtworkTracker.clear(
                        ratingKey: scopedIdentity.ratingKey,
                        type: artworkType,
                        sourceCompositeKey: scopedIdentity.sourceCompositeKey
                    )
                    resolvedLocalURL = URL(fileURLWithPath: localPath)
                    EnsembleLogger.debug("🎨 ArtworkLoader: Persisted \(scopedIdentity.kind.rawValue) artwork for ratingKey=\(scopedIdentity.ratingKey)")
                } else {
                    artworkDownloadManager.deleteArtwork(
                        ratingKey: scopedIdentity.ratingKey,
                        type: artworkType,
                        sourceCompositeKey: scopedIdentity.sourceCompositeKey
                    )
                }
            } catch {
                EnsembleLogger.debug("🎨 ArtworkLoader: Failed to persist \(scopedIdentity.kind.rawValue) artwork for ratingKey=\(scopedIdentity.ratingKey): \(error.localizedDescription)")
            }
        }

        await persistentCacheTracker.finish(scopedIdentity)
        await syncCoordinator.finishSourcePersistenceWork(persistenceHandle)
        return resolvedLocalURL
    }

    /// Async version for modern Swift concurrency
    /// Checks local cache first if ratingKey is provided, otherwise fetches from network
    /// Supports fallback artwork (e.g., album artwork for tracks without specific artwork)
    func artworkURLAsync(
        for path: String?, 
        sourceKey: String? = nil, 
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        size: Int = 300
    ) async -> URL? {
        // Cap size to avoid excessive memory usage while still serving retina detail headers.
        let cappedSize = min(size, Self.maximumArtworkRequestDimension)
        guard let lookup = Self.artworkLookup(
            path: path,
            ratingKey: ratingKey,
            fallbackPath: fallbackPath,
            fallbackRatingKey: fallbackRatingKey
        ) else { return nil }
        let urlCacheGeneration = await urlCache.currentGeneration()
        let artworkURLTrackerGeneration = await artworkURLTracker.currentGeneration()

        // Prefer local cache when it can satisfy this request. Undersized persistent
        // artwork is allowed as offline fallback, but should not block an online
        // detail surface from fetching and replacing a better image.
        if let localURL = await localCachedArtworkURL(
            ratingKey: lookup.ratingKey,
            sourceCompositeKey: sourceKey,
            path: lookup.path,
            allowStaleIdentity: false,
            minimumPixelDimension: cappedSize
        ) {
            guard await urlCache.isCurrent(urlCacheGeneration) else { return nil }
            let localCacheKey = "\(sourceKey ?? ""):\(lookup.path):\(lookup.ratingKey ?? ""):local"
            if await urlCache.get(localCacheKey) == nil {
                await urlCache.set(
                    localCacheKey,
                    url: localURL,
                    ttl: Self.asyncArtworkURLCacheTTL,
                    generation: urlCacheGeneration
                )
            }
            return localURL
        }

        let isOffline = await syncCoordinator.isOffline
        // Artwork should wait for a confirmed healthy endpoint. Returning a remote URL
        // while the server is still in .unknown/.connecting can hand the UI a stale
        // pre-health-check endpoint that never resolves, especially on macOS Feed startup.
        let serverAvailable = await syncCoordinator.isServerAvailable(sourceKey: sourceKey)
        let connectivityTag = isOffline ? "offline" : (serverAvailable ? "online" : "server-offline")
        let cacheKey = "\(sourceKey ?? ""):\(lookup.path):\(lookup.ratingKey ?? ""):\(cappedSize):\(connectivityTag)"

        if let cachedURL = await urlCache.get(cacheKey) {
            return cachedURL
        }

        // Server is unavailable and no local cache — return nil immediately
        // rather than building a URL that will time out
        let serverUnavailable = !isOffline && !serverAvailable
        if isOffline || serverUnavailable {
            if let localURL = await localCachedArtworkURL(
                ratingKey: lookup.ratingKey,
                sourceCompositeKey: sourceKey,
                path: lookup.path,
                allowStaleIdentity: true,
                minimumPixelDimension: nil
            ) {
                guard await urlCache.isCurrent(urlCacheGeneration) else { return nil }
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
        let networkURL = try? await syncCoordinator.getArtworkURL(path: lookup.path, sourceKey: sourceKey, size: cappedSize)
        if let url = networkURL {
            guard await urlCache.isCurrent(urlCacheGeneration) else { return nil }
            #if DEBUG
            await loadStats.recordNetwork()
            #endif
            // Track the URL for targeted cache eviction on invalidation
            if let key = lookup.ratingKey {
                await artworkURLTracker.record(
                    url: url,
                    forRatingKey: key,
                    generation: artworkURLTrackerGeneration
                )
            }
            await urlCache.set(
                cacheKey,
                url: url,
                ttl: Self.asyncArtworkURLCacheTTL,
                generation: urlCacheGeneration
            )
            return url
        }

        // Network URL resolution failed — fall back to local cache if available
        if let localURL = await localCachedArtworkURL(
            ratingKey: lookup.ratingKey,
            sourceCompositeKey: sourceKey,
            path: lookup.path,
            allowStaleIdentity: true,
            minimumPixelDimension: nil
        ) {
            guard await urlCache.isCurrent(urlCacheGeneration) else { return nil }
            #if DEBUG
            await loadStats.recordLocalFallback()
            #endif
            return localURL
        }

        return nil
    }

    func localArtworkURLAsync(
        for path: String?,
        sourceKey: String? = nil,
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        minimumPixelDimension: Int? = nil,
        allowStaleIdentity: Bool = true
    ) async -> URL? {
        guard let lookup = Self.artworkLookup(
            path: path,
            ratingKey: ratingKey,
            fallbackPath: fallbackPath,
            fallbackRatingKey: fallbackRatingKey
        ) else { return nil }

        return await localCachedArtworkURL(
            ratingKey: lookup.ratingKey,
            sourceCompositeKey: sourceKey,
            path: lookup.path,
            allowStaleIdentity: allowStaleIdentity,
            minimumPixelDimension: minimumPixelDimension
        )
    }

    private static func artworkLookup(
        path: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?
    ) -> ArtworkLookup? {
        if let path, !path.isEmpty {
            return ArtworkLookup(path: path, ratingKey: ratingKey)
        }

        if let fallbackPath, !fallbackPath.isEmpty {
            return ArtworkLookup(path: fallbackPath, ratingKey: fallbackRatingKey)
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
    private func localCachedArtworkURL(
        ratingKey: String?,
        sourceCompositeKey: String?,
        path: String? = nil,
        allowStaleIdentity: Bool,
        minimumPixelDimension: Int?
    ) async -> URL? {
        if let ratingKey,
           let cached = await cachedArtworkURL(
               ratingKey: ratingKey,
               sourceCompositeKey: sourceCompositeKey,
               sourcePath: path,
               allowStaleIdentity: allowStaleIdentity,
               minimumPixelDimension: minimumPixelDimension
           ) {
            return cached
        }

        // Fall back to the ratingKey embedded in the artwork path.
        // Tracks inherit their album's thumbPath (`parentThumb`), so the path
        // contains the album ratingKey while the passed ratingKey is the track's.
        if let path,
           let pathKey = Self.extractRatingKey(from: path),
           pathKey != ratingKey,
           let cached = await cachedArtworkURL(
               ratingKey: pathKey,
               sourceCompositeKey: sourceCompositeKey,
               sourcePath: path,
               allowStaleIdentity: allowStaleIdentity,
               minimumPixelDimension: minimumPixelDimension
           ) {
            return cached
        }

        return nil
    }

    private func cachedArtworkURL(
        ratingKey: String,
        sourceCompositeKey: String?,
        sourcePath: String?,
        allowStaleIdentity: Bool,
        minimumPixelDimension: Int?
    ) async -> URL? {
        for type in [ArtworkType.track, .album, .artist, .playlist] {
            let isMarkedStale = await stalePersistentArtworkTracker.contains(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            )
            if !isMarkedStale,
               let filePath = try? await artworkDownloadManager.getLocalArtworkPath(
                   ratingKey: ratingKey,
                   type: type,
                   sourceCompositeKey: sourceCompositeKey,
                   sourcePath: sourcePath,
                   dateModifiedSeconds: nil
               ),
               await persistentArtworkIsUsable(
                   filePath: filePath,
                   ratingKey: ratingKey,
                   type: type,
                   sourceCompositeKey: sourceCompositeKey,
                   sourcePath: sourcePath,
                   minimumPixelDimension: minimumPixelDimension
               ) {
                return URL(fileURLWithPath: filePath)
            }

            guard allowStaleIdentity,
                  let filePath = try? await artworkDownloadManager.getStaleLocalArtworkPath(
                      ratingKey: ratingKey,
                      type: type,
                      sourceCompositeKey: sourceCompositeKey
                  ),
                  await persistentArtworkIsUsable(
                      filePath: filePath,
                      ratingKey: ratingKey,
                      type: type,
                      sourceCompositeKey: sourceCompositeKey,
                      sourcePath: nil,
                      minimumPixelDimension: minimumPixelDimension
                  ) else {
                continue
            }
            return URL(fileURLWithPath: filePath)
        }
        return nil
    }

    private func persistentArtworkIsUsable(
        filePath: String,
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        minimumPixelDimension: Int?
    ) async -> Bool {
        guard ArtworkFileInspector.fileExists(atPath: filePath) else {
            artworkDownloadManager.deleteArtwork(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            )
            return false
        }
        return await artworkDownloadManager.localArtworkExists(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey,
            sourcePath: sourcePath,
            dateModifiedSeconds: nil,
            minimumPixelDimension: minimumPixelDimension
        )
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

    public var requestPixelDimension: Int {
        requestTier.rawValue
    }

    public var requestTier: ArtworkRequest.Tier {
        switch self {
        case .tiny, .thumbnail, .card: return .thumbnail
        case .small, .medium, .large: return .standard
        case .extraLarge, .detail: return .hero
        }
    }
}

private extension ArtworkRequest.Identity.Kind {
    var artworkType: ArtworkType {
        switch self {
        case .album:
            return .album
        case .artist:
            return .artist
        case .track:
            return .track
        case .playlist:
            return .playlist
        }
    }
}
