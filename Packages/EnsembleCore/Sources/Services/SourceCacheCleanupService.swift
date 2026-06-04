import EnsemblePersistence
import Foundation

/// Summary of a destructive source cache cleanup pass.
public struct SourceCacheCleanupResult: Sendable, Equatable {
    public let sourceKeys: Set<String>
    public let deletedAllLibraryData: Bool
    public let libraryItemCount: Int
    public let downloadRecordCount: Int
    public let targetCount: Int
    public let artworkItemCount: Int
    public let lyricsItemCount: Int
    public let duration: TimeInterval

    /// Creates a cleanup result for logging and tests.
    public init(
        sourceKeys: Set<String>,
        deletedAllLibraryData: Bool,
        libraryItemCount: Int,
        downloadRecordCount: Int,
        targetCount: Int,
        artworkItemCount: Int,
        lyricsItemCount: Int,
        duration: TimeInterval
    ) {
        self.sourceKeys = sourceKeys
        self.deletedAllLibraryData = deletedAllLibraryData
        self.libraryItemCount = libraryItemCount
        self.downloadRecordCount = downloadRecordCount
        self.targetCount = targetCount
        self.artworkItemCount = artworkItemCount
        self.lyricsItemCount = lyricsItemCount
        self.duration = duration
    }

    public var logDescription: String {
        "sources=\(sourceKeys.count), libraryItems=\(libraryItemCount), downloads=\(downloadRecordCount), targets=\(targetCount), artworkItems=\(artworkItemCount), lyricsItems=\(lyricsItemCount), deleteAll=\(deletedAllLibraryData), duration=\(String(format: "%.3f", duration))s"
    }
}

/// Worker boundary for destructive source/library cache cleanup.
public protocol SourceCacheCleaning: Sendable {
    /// Removes cached data, downloads, and file caches for one library source.
    func cleanupSource(_ sourceKey: String) async throws -> SourceCacheCleanupResult

    /// Removes every cached library/download/artwork/lyrics artifact.
    func cleanupAllLibraryData(cachedSourceKeys: Set<String>) async throws -> SourceCacheCleanupResult
}

/// Removes source-owned cached data without routing heavy work through UI view models.
public final class SourceCacheCleanupService: SourceCacheCleaning, @unchecked Sendable {
    public typealias LyricsCacheCleanup = @Sendable (String) async -> Int
    public typealias AllLyricsCacheCleanup = @Sendable () async -> Int
    public typealias ArtworkKeyLookup = @Sendable (String) async throws -> Set<String>
    public typealias SourceLibraryItemCounter = @Sendable (String) async throws -> Int
    public typealias AllLibraryItemCounter = @Sendable () async throws -> Int
    public typealias SourceTargetCounter = @Sendable (String) async throws -> Int
    public typealias AllTargetCounter = @Sendable () async throws -> Int
    public typealias ArtworkItemCounter = @Sendable () async throws -> Int

    private let libraryRepository: LibraryRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let fetchArtworkRatingKeys: ArtworkKeyLookup
    private let countLibraryItemsForSource: SourceLibraryItemCounter
    private let countAllLibraryItems: AllLibraryItemCounter
    private let countTargetsForSource: SourceTargetCounter
    private let countAllTargets: AllTargetCounter
    private let countArtworkItems: ArtworkItemCounter
    private let clearLyricsCache: LyricsCacheCleanup
    private let clearAllLyricsCaches: AllLyricsCacheCleanup

    /// Creates a source cleanup worker from repository/file-cache dependencies.
    public init(
        libraryRepository: LibraryRepositoryProtocol,
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        fetchArtworkRatingKeys: @escaping ArtworkKeyLookup,
        countLibraryItemsForSource: @escaping SourceLibraryItemCounter,
        countAllLibraryItems: @escaping AllLibraryItemCounter,
        countTargetsForSource: @escaping SourceTargetCounter,
        countAllTargets: @escaping AllTargetCounter,
        countArtworkItems: @escaping ArtworkItemCounter,
        clearLyricsCache: @escaping LyricsCacheCleanup,
        clearAllLyricsCaches: @escaping AllLyricsCacheCleanup
    ) {
        self.libraryRepository = libraryRepository
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.fetchArtworkRatingKeys = fetchArtworkRatingKeys
        self.countLibraryItemsForSource = countLibraryItemsForSource
        self.countAllLibraryItems = countAllLibraryItems
        self.countTargetsForSource = countTargetsForSource
        self.countAllTargets = countAllTargets
        self.countArtworkItems = countArtworkItems
        self.clearLyricsCache = clearLyricsCache
        self.clearAllLyricsCaches = clearAllLyricsCaches
    }

    /// Removes one source's caches while preserving unrelated sources.
    public func cleanupSource(_ sourceKey: String) async throws -> SourceCacheCleanupResult {
        try await Task.detached(priority: .utility) {
            try await self.cleanupSources([sourceKey])
        }.value
    }

    /// Removes all library-owned caches, including orphaned downloads without source rows.
    public func cleanupAllLibraryData(cachedSourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
        try await Task.detached(priority: .utility) {
            try await self.cleanupAll(cachedSourceKeys: cachedSourceKeys)
        }.value
    }

    private func cleanupAll(cachedSourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
        let startedAt = Date()
        async let libraryItemCount = countAllLibraryItems()
        async let downloadRecordCount = downloadManager.fetchDownloads().count
        async let targetCount = countAllTargets()
        async let artworkItemCount = countArtworkItems()
        let counts = try await (
            libraryItems: libraryItemCount,
            downloads: downloadRecordCount,
            targets: targetCount,
            artworkItems: artworkItemCount
        )

        async let lyricsCleanup: Int = clearAllLyricsCaches()
        async let targetCleanup: Void = targetRepository.deleteAllTargets()
        async let downloadCleanup: Void = downloadManager.deleteAllDownloads()

        let lyricsItemCount = await lyricsCleanup
        try await targetCleanup
        try await downloadCleanup
        try await libraryRepository.deleteAllLibraryData()
        try await artworkDownloadManager.clearArtworkCache()

        let result = SourceCacheCleanupResult(
            sourceKeys: cachedSourceKeys,
            deletedAllLibraryData: true,
            libraryItemCount: counts.libraryItems,
            downloadRecordCount: counts.downloads,
            targetCount: counts.targets,
            artworkItemCount: counts.artworkItems,
            lyricsItemCount: lyricsItemCount,
            duration: Date().timeIntervalSince(startedAt)
        )
        EnsembleLogger.info("Source cache cleanup finished \(result.logDescription)")
        return result
    }

    private func cleanupSources(_ sourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
        let startedAt = Date()
        var artworkKeysToDelete = Set<String>()
        var libraryItemCount = 0
        var downloadRecordCount = 0
        var targetCount = 0
        var lyricsItemCount = 0

        for sourceKey in sourceKeys {
            async let sourceArtworkKeys = fetchArtworkRatingKeys(sourceKey)
            async let sourceLibraryItems = countLibraryItemsForSource(sourceKey)
            async let sourceDownloads = downloadManager.fetchDownloads(forSourceCompositeKey: sourceKey).count
            async let sourceTargets = countTargetsForSource(sourceKey)

            let sourceCounts = try await (
                artworkKeys: sourceArtworkKeys,
                libraryItems: sourceLibraryItems,
                downloads: sourceDownloads,
                targets: sourceTargets
            )
            artworkKeysToDelete.formUnion(sourceCounts.artworkKeys)
            libraryItemCount += sourceCounts.libraryItems
            downloadRecordCount += sourceCounts.downloads
            targetCount += sourceCounts.targets

            async let lyricsCleanup: Int = clearLyricsCache(sourceKey)
            async let targetCleanup: Void = targetRepository.deleteTargets(forSourceCompositeKey: sourceKey)
            async let downloadCleanup: Void = downloadManager.deleteDownloads(forSourceCompositeKey: sourceKey)

            lyricsItemCount += await lyricsCleanup
            try await targetCleanup
            try await downloadCleanup

            try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceKey)
        }

        if !artworkKeysToDelete.isEmpty {
            artworkDownloadManager.deleteArtwork(forRatingKeys: artworkKeysToDelete)
        }

        let result = SourceCacheCleanupResult(
            sourceKeys: sourceKeys,
            deletedAllLibraryData: false,
            libraryItemCount: libraryItemCount,
            downloadRecordCount: downloadRecordCount,
            targetCount: targetCount,
            artworkItemCount: artworkKeysToDelete.count,
            lyricsItemCount: lyricsItemCount,
            duration: Date().timeIntervalSince(startedAt)
        )
        EnsembleLogger.info("Source cache cleanup finished \(result.logDescription)")
        return result
    }
}
