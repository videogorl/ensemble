import EnsemblePersistence
import Foundation

/// Summary of a destructive source cache cleanup pass.
public struct SourceCacheCleanupResult: Sendable, Equatable {
    public let sourceKeys: Set<String>
    public let artworkKeyCount: Int
    public let deletedAllLibraryData: Bool

    /// Creates a cleanup result for logging and tests.
    public init(sourceKeys: Set<String>, artworkKeyCount: Int, deletedAllLibraryData: Bool) {
        self.sourceKeys = sourceKeys
        self.artworkKeyCount = artworkKeyCount
        self.deletedAllLibraryData = deletedAllLibraryData
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
    public typealias LyricsCacheCleanup = @Sendable (String) async -> Void
    public typealias AllLyricsCacheCleanup = @Sendable () async -> Void
    public typealias ArtworkKeyLookup = @Sendable (String) async throws -> Set<String>

    private let libraryRepository: LibraryRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let fetchArtworkRatingKeys: ArtworkKeyLookup
    private let clearLyricsCache: LyricsCacheCleanup
    private let clearAllLyricsCaches: AllLyricsCacheCleanup

    /// Creates a source cleanup worker from repository/file-cache dependencies.
    public init(
        libraryRepository: LibraryRepositoryProtocol,
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        fetchArtworkRatingKeys: @escaping ArtworkKeyLookup,
        clearLyricsCache: @escaping LyricsCacheCleanup,
        clearAllLyricsCaches: @escaping AllLyricsCacheCleanup
    ) {
        self.libraryRepository = libraryRepository
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.fetchArtworkRatingKeys = fetchArtworkRatingKeys
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
        async let lyricsCleanup: Void = clearAllLyricsCaches()
        async let targetCleanup: Void = targetRepository.deleteAllTargets()
        async let downloadCleanup: Void = downloadManager.deleteAllDownloads()

        _ = await lyricsCleanup
        try await targetCleanup
        try await downloadCleanup
        try await libraryRepository.deleteAllLibraryData()
        try await artworkDownloadManager.clearArtworkCache()

        EnsembleLogger.info("Source cache cleanup finished sources=\(cachedSourceKeys.count) artworkKeys=all deleteAll=true")
        return SourceCacheCleanupResult(
            sourceKeys: cachedSourceKeys,
            artworkKeyCount: 0,
            deletedAllLibraryData: true
        )
    }

    private func cleanupSources(_ sourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
        var artworkKeysToDelete = Set<String>()

        for sourceKey in sourceKeys {
            let sourceArtworkKeys = try await fetchArtworkRatingKeys(sourceKey)
            artworkKeysToDelete.formUnion(sourceArtworkKeys)

            async let lyricsCleanup: Void = clearLyricsCache(sourceKey)
            async let targetCleanup: Void = targetRepository.deleteTargets(forSourceCompositeKey: sourceKey)
            async let downloadCleanup: Void = downloadManager.deleteDownloads(forSourceCompositeKey: sourceKey)

            _ = await lyricsCleanup
            try await targetCleanup
            try await downloadCleanup

            try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceKey)
        }

        if !artworkKeysToDelete.isEmpty {
            artworkDownloadManager.deleteArtwork(forRatingKeys: artworkKeysToDelete)
        }

        EnsembleLogger.info(
            "Source cache cleanup finished sources=\(sourceKeys.count) artworkKeys=\(artworkKeysToDelete.count) deleteAll=false"
        )
        return SourceCacheCleanupResult(
            sourceKeys: sourceKeys,
            artworkKeyCount: artworkKeysToDelete.count,
            deletedAllLibraryData: false
        )
    }
}
