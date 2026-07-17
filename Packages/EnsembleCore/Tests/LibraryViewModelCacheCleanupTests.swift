import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class LibraryViewModelCacheCleanupTests: XCTestCase {
    private actor CleanupRecorder {
        private var sourceKeys: [String] = []

        func record(_ sourceKey: String) {
            sourceKeys.append(sourceKey)
        }

        func recordedSourceKeys() -> [String] {
            sourceKeys
        }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        private(set) var clearArtworkCacheCallCount = 0

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}

        func clearArtworkCache() async throws {
            clearArtworkCacheCallCount += 1
        }

        func getArtworkCacheSize() async throws -> Int64 {
            0
        }
    }

    func testLoadLibraryPurgesAllCachedLibraryDataWhenNoAccountsExist() async throws {
        let harness = makeHarness()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertTrue(viewModel.albums.isEmpty)
        XCTAssertTrue(viewModel.artists.isEmpty)
        XCTAssertTrue(viewModel.genres.isEmpty)
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testLoadLibraryPreservesCachedLibraryDataWhenConfiguredAccountHasNoEnabledLibraries() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, [sourceKey])

        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(trackSourceKeys, [sourceKey])
    }

    func testLoadLibraryPublishesCachedLibraryWhileCloudSourcesAreRestoring() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        harness.accountManager.setAwaitingCloudSources(true)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, [sourceKey])
    }

    func testLibraryReloadsWhenCloudSourceRestorationSettles() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        harness.accountManager.setAwaitingCloudSources(true)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])

        harness.accountManager.setAwaitingCloudSources(false)
        try await waitForTrackCount(viewModel: viewModel, expectedCount: 0)
    }

    func testBrowseSnapshotPreservesVisibleTracksUntilEmptySourceStateSettles() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        let readiness = AppReadinessCoordinator(
            accountManager: harness.accountManager,
            syncCoordinator: harness.syncCoordinator
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness, appReadinessCoordinator: readiness)
        await viewModel.loadLibrary()
        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: false
        )
        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertFalse(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)

        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "lib-1",
            isEnabled: false
        ))
        await Task.yield()
        await viewModel.loadLibrary()

        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: true
        )
        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertTrue(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)

        readiness.markBootstrapSettled()
        await viewModel.loadLibrary()
        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [],
            isShowingStaleSnapshot: false
        )

        XCTAssertTrue(viewModel.trackBrowseSnapshot.tracks.isEmpty)
        XCTAssertFalse(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)
    }

    func testImmediateTrackBrowseSnapshotExposesCachedTracksBeforeDebouncedSnapshot() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.trackBrowseSnapshot.tracks.isEmpty)
        XCTAssertEqual(viewModel.immediateTrackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertEqual(viewModel.immediateTrackBrowseSnapshot.sections.map(\.letter), ["T"])

        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: false
        )
        XCTAssertEqual(viewModel.immediateTrackBrowseSnapshot, viewModel.trackBrowseSnapshot)
    }

    func testLoadLibraryPublishesArtistMetadataChangesWithStableIdentity() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let metadataDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await harness.libraryRepository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist-1",
                key: "/library/metadata/artist-1",
                name: "Janelle Mon�e",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: metadataDate
            )
        ], sourceCompositeKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        try await waitForArtistName(viewModel: viewModel, expectedName: "Janelle Mon�e")

        try await harness.libraryRepository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist-1",
                key: "/library/metadata/artist-1",
                name: "Janelle Monáe",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: metadataDate
            )
        ], sourceCompositeKey: sourceKey)
        await viewModel.loadLibrary()

        try await waitForArtistName(viewModel: viewModel, expectedName: "Janelle Monáe")
    }

    func testLoadLibraryPurgesCachedSourcesThatAreNoLongerEnabled() async throws {
        let cleanupRecorder = CleanupRecorder()
        let harness = makeHarness { sourceKey in
            await cleanupRecorder.record(sourceKey)
            return 1
        }
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", false)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-2")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        try await waitForDeferredCleanup(repository: harness.libraryRepository, expectedSourceKeys: ["plex:account-1:server-1:lib-1"])

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, ["plex:account-1:server-1:lib-1"])

        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(trackSourceKeys, ["plex:account-1:server-1:lib-1"])
        let cleanedSourceKeys = await cleanupRecorder.recordedSourceKeys()
        XCTAssertEqual(cleanedSourceKeys, ["plex:account-1:server-1:lib-2"])
    }

    func testSourceCleanupResultReportsRemovedCounts() async throws {
        let harness = makeHarness(
            clearLyricsCache: { _ in 2 },
            clearAllLyricsCaches: { 4 }
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")

        let result = try await harness.sourceCacheCleanupService.cleanupSource("plex:account-1:server-1:lib-1")

        XCTAssertEqual(result.sourceKeys, ["plex:account-1:server-1:lib-1"])
        XCTAssertFalse(result.deletedAllLibraryData)
        XCTAssertGreaterThanOrEqual(result.libraryItemCount, 1)
        XCTAssertEqual(result.downloadRecordCount, 1)
        XCTAssertEqual(result.targetCount, 1)
        XCTAssertEqual(result.lyricsItemCount, 2)
        XCTAssertTrue(result.duration >= 0)
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testSourceCleanupRemovesDownloadFilesAndOrphanedSidecars() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        let trackRatingKey = "track-lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let fileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: sourceKey,
            trackRatingKey: trackRatingKey
        )
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        let orphanSidecarURL = DownloadManager.downloadsDirectory
            .appendingPathComponent("orphan-sidecar-\(UUID().uuidString).mp3.freq")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: sidecarURL)
            try? FileManager.default.removeItem(at: orphanSidecarURL)
        }
        try Data("orphan".utf8).write(to: orphanSidecarURL)

        let result = try await harness.sourceCacheCleanupService.cleanupSource(sourceKey)

        XCTAssertEqual(result.sourceKeys, [sourceKey])
        XCTAssertEqual(result.downloadRecordCount, 1)
        XCTAssertEqual(result.targetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanSidecarURL.path))
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testRemoteLibraryDisableCleansSourceDownloadsAndPreservesEnabledSource() async throws {
        let harness = makeHarness()
        let enabledSourceKey = "plex:account-1:server-1:lib-1"
        let disabledSourceKey = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", true)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: enabledSourceKey)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: disabledSourceKey)

        let keptFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: enabledSourceKey,
            trackRatingKey: "track-lib-1"
        )
        let removedFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: disabledSourceKey,
            trackRatingKey: "track-lib-2"
        )
        let keptSidecarURL = URL(fileURLWithPath: keptFileURL.path + ".freq")
        let removedSidecarURL = URL(fileURLWithPath: removedFileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: keptFileURL)
            try? FileManager.default.removeItem(at: keptSidecarURL)
            try? FileManager.default.removeItem(at: removedFileURL)
            try? FileManager.default.removeItem(at: removedSidecarURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedFileURL.path))

        let result = harness.accountManager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:lib-1": true,
                "account-1:server-1:lib-2": false
            ])
        )
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), [disabledSourceKey])

        await harness.syncCoordinator.cleanupRemovedSourcesIfPresent(result.disabledSources)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedSidecarURL.path))
        let keptDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: enabledSourceKey)
        let removedDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: disabledSourceKey)
        let targetSourceKeys = Set(try await harness.targetRepository.fetchTargets().compactMap(\.sourceCompositeKey))
        let cachedSourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(keptDownloadCount, 1)
        XCTAssertEqual(removedDownloadCount, 0)
        XCTAssertEqual(targetSourceKeys, [enabledSourceKey])
        XCTAssertEqual(cachedSourceKeys, [enabledSourceKey])
        XCTAssertEqual(trackSourceKeys, [enabledSourceKey])
    }

    func testRemoteDisabledLibraryFlagCleansAlreadyDisabledSourceDownloads() async throws {
        let harness = makeHarness()
        let enabledSourceKey = "plex:account-1:server-1:lib-1"
        let disabledSourceKey = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", false)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: enabledSourceKey)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: disabledSourceKey)

        let keptFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: enabledSourceKey,
            trackRatingKey: "track-lib-1"
        )
        let removedFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: disabledSourceKey,
            trackRatingKey: "track-lib-2"
        )
        let keptSidecarURL = URL(fileURLWithPath: keptFileURL.path + ".freq")
        let removedSidecarURL = URL(fileURLWithPath: removedFileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: keptFileURL)
            try? FileManager.default.removeItem(at: keptSidecarURL)
            try? FileManager.default.removeItem(at: removedFileURL)
            try? FileManager.default.removeItem(at: removedSidecarURL)
        }

        let result = harness.accountManager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:lib-1": true,
                "account-1:server-1:lib-2": false
            ])
        )
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), [disabledSourceKey])

        await harness.syncCoordinator.cleanupRemovedSourcesIfPresent(result.disabledSources)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedSidecarURL.path))
        let keptDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: enabledSourceKey)
        let removedDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: disabledSourceKey)
        let targetSourceKeys = Set(try await harness.targetRepository.fetchTargets().compactMap(\.sourceCompositeKey))
        let cachedSourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(keptDownloadCount, 1)
        XCTAssertEqual(removedDownloadCount, 0)
        XCTAssertEqual(targetSourceKeys, [enabledSourceKey])
        XCTAssertEqual(cachedSourceKeys, [enabledSourceKey])
        XCTAssertEqual(trackSourceKeys, [enabledSourceKey])
    }

    func testCacheManagerClearAllCachesUsesSourceCleanupWorker() async throws {
        let harness = makeHarness(clearAllLyricsCaches: { 3 })
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService

        try await cacheManager.clearAllCaches()

        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testCacheManagerClearAllCachesDeletesDownloadedFilesFromDisk() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        let trackRatingKey = "track-lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let fileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: sourceKey,
            trackRatingKey: trackRatingKey
        )
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService

        try await cacheManager.clearAllCaches()

        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    func testCacheManagerClearAllCachesPostsLibraryDataClearNotification() async throws {
        let harness = makeHarness()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService
        let notification = expectation(description: "library data clear notification")
        let observer = NotificationCenter.default.addObserver(
            forName: CacheManager.libraryDataDidClear,
            object: cacheManager,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await cacheManager.clearAllCaches()

        await fulfillment(of: [notification], timeout: 1)
    }

    func testCacheManagerClearArtworkCachesPreservesLibraryAndDownloadState() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        try await seedOfflineDownload(harness: harness, sourceKey: sourceKey, trackRatingKey: "track-lib-1")
        let artworkDownloadManager = RecordingArtworkDownloadManager()
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: artworkDownloadManager,
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )

        let before = try await cacheManager.cleanupSnapshot()
        XCTAssertEqual(before.libraryItemCount, 1)
        XCTAssertEqual(before.sourceCount, 1)
        XCTAssertEqual(before.downloadRecordCount, 1)
        XCTAssertEqual(cacheManager.artworkCacheInvalidationGeneration, 0)

        try await cacheManager.clearArtworkCaches()

        let after = try await cacheManager.cleanupSnapshot()
        XCTAssertEqual(after.libraryItemCount, before.libraryItemCount)
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.downloadRecordCount, before.downloadRecordCount)
        XCTAssertEqual(after.completedDownloadCount, before.completedDownloadCount)
        let targets = try await harness.targetRepository.fetchTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(artworkDownloadManager.clearArtworkCacheCallCount, 1)
        XCTAssertEqual(cacheManager.artworkCacheInvalidationGeneration, 1)
    }

    func testCacheManagerClearArtworkCachesDoesNotPostLibraryDataClearNotification() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: RecordingArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        let notification = expectation(description: "library data clear notification should not fire")
        notification.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: CacheManager.libraryDataDidClear,
            object: cacheManager,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await cacheManager.clearArtworkCaches()

        await fulfillment(of: [notification], timeout: 0.2)
    }

    private struct Harness {
        let accountManager: AccountManager
        let syncCoordinator: SyncCoordinator
        let libraryRepository: LibraryRepository
        let downloadManager: DownloadManager
        let targetRepository: OfflineDownloadTargetRepository
        let sourceCacheCleanupService: SourceCacheCleaning
    }

    private func makeHarness(
        clearLyricsCache: @escaping SourceCacheCleanupService.LyricsCacheCleanup = { _ in 0 },
        clearAllLyricsCaches: @escaping SourceCacheCleanupService.AllLyricsCacheCleanup = { 0 }
    ) -> Harness {
        let accountManager = AccountManager(keychain: TestKeychain())
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let targetRepository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let artworkDownloadManager = ArtworkDownloadManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.library-cache-cleanup.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        let sourceCacheCleanupService = SourceCacheCleanupService(
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            artworkDownloadManager: artworkDownloadManager,
            fetchArtworkRatingKeys: { sourceKey in
                try await libraryRepository.fetchArtworkRatingKeys(forSourceCompositeKey: sourceKey)
            },
            countLibraryItemsForSource: { sourceKey in
                try await libraryRepository.countLibraryItems(forSourceCompositeKey: sourceKey)
            },
            countAllLibraryItems: {
                try await libraryRepository.countAllLibraryItems()
            },
            countTargetsForSource: { sourceKey in
                try await targetRepository.countTargets(forSourceCompositeKey: sourceKey)
            },
            countAllTargets: {
                try await targetRepository.countAllTargets()
            },
            countArtworkItems: {
                try await artworkDownloadManager.getArtworkCacheFileCount()
            },
            clearLyricsCache: clearLyricsCache,
            clearAllLyricsCaches: clearAllLyricsCaches
        )
        syncCoordinator.sourceCacheCleanupService = sourceCacheCleanupService

        return Harness(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            sourceCacheCleanupService: sourceCacheCleanupService
        )
    }

    private func waitForDeferredCleanup(
        repository: LibraryRepository,
        expectedSourceKeys: Set<String> = []
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
            let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
            if sourceKeys == expectedSourceKeys && trackSourceKeys == expectedSourceKeys {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(sourceKeys, expectedSourceKeys)
        XCTAssertEqual(trackSourceKeys, expectedSourceKeys)
    }

    private func waitForDeferredOfflineCleanup(harness: Harness) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let downloads = try await harness.downloadManager.fetchDownloads()
            let targets = try await harness.targetRepository.fetchTargets()
            if downloads.isEmpty && targets.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let downloads = try await harness.downloadManager.fetchDownloads()
        let targets = try await harness.targetRepository.fetchTargets()
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    private func waitForTrackCount(viewModel: LibraryViewModel, expectedCount: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.tracks.count == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.tracks.count, expectedCount)
    }

    private func waitForTrackSnapshot(
        viewModel: LibraryViewModel,
        expectedSourceKeys: [String],
        isShowingStaleSnapshot: Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sourceKeys = viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey)
            if sourceKeys == expectedSourceKeys,
               viewModel.trackBrowseSnapshot.isShowingStaleSnapshot == isShowingStaleSnapshot {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), expectedSourceKeys)
        XCTAssertEqual(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot, isShowingStaleSnapshot)
    }

    private func waitForArtistName(viewModel: LibraryViewModel, expectedName: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.artistBrowseSnapshot.displayArtists.first?.name == expectedName {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.artistBrowseSnapshot.displayArtists.first?.name, expectedName)
    }

    private func makeViewModel(
        harness: Harness,
        appReadinessCoordinator: AppReadinessCoordinator? = nil
    ) -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: harness.libraryRepository,
            syncCoordinator: harness.syncCoordinator,
            sourceCacheCleanupService: harness.sourceCacheCleanupService,
            accountManager: harness.accountManager,
            visibilityStore: LibraryVisibilityStore(),
            toastCenter: ToastCenter(),
            appReadinessCoordinator: appReadinessCoordinator
        )
    }

    private func makeAccount(
        libraries: [(key: String, title: String, enabled: Bool)]
    ) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            email: "user@example.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: libraries.map { library in
                        PlexLibraryConfig(
                            id: library.key,
                            key: library.key,
                            title: library.title,
                            isEnabled: library.enabled
                        )
                    }
                )
            ]
        )
    }

    private func makeFlagsData(_ flags: [String: Bool]) throws -> Data {
        try JSONEncoder().encode(flags)
    }

    private func seedSourceAndTrack(repository: LibraryRepository, sourceKey: String) async throws {
        let parts = sourceKey.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 4)
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: parts[0],
            accountId: parts[1],
            serverId: parts[2],
            libraryId: parts[3],
            displayName: "Library \(parts[3])",
            accountName: "Felicity"
        )

        _ = try await repository.upsertTrack(
            ratingKey: "track-\(parts[3])",
            key: "track-\(parts[3])",
            title: "Track \(parts[3])",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 120_000,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: sourceKey
        )
    }

    private func seedOfflineDownload(harness: Harness, sourceKey: String, trackRatingKey: String) async throws {
        _ = try await harness.downloadManager.createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceKey,
            quality: "high"
        )
        _ = try await harness.targetRepository.upsertTarget(
            key: "library:\(sourceKey)",
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: sourceKey,
            displayName: "Library"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "library:\(sourceKey)",
            trackReferences: [
                OfflineTrackReference(trackRatingKey: trackRatingKey, trackSourceCompositeKey: sourceKey)
            ]
        )
    }

    private func seedCompletedOfflineDownloadFile(
        harness: Harness,
        sourceKey: String,
        trackRatingKey: String
    ) async throws -> URL {
        let download = try await harness.downloadManager.createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceKey,
            quality: "high"
        )
        let filename = "cleanup-test-\(UUID().uuidString).mp3"
        let fileURL = DownloadManager.downloadsDirectory.appendingPathComponent(filename)
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        try Data("audio".utf8).write(to: fileURL)
        try Data("sidecar".utf8).write(to: sidecarURL)
        try await harness.downloadManager.completeDownload(
            download.objectID,
            filePath: fileURL.path,
            fileSize: 5,
            quality: "high"
        )
        _ = try await harness.targetRepository.upsertTarget(
            key: "library:\(sourceKey)",
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: sourceKey,
            displayName: "Library"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "library:\(sourceKey)",
            trackReferences: [
                OfflineTrackReference(trackRatingKey: trackRatingKey, trackSourceCompositeKey: sourceKey)
            ]
        )
        return fileURL
    }
}
