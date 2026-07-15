import Combine
import Foundation
import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class OfflineDownloadServicePolicyTests: XCTestCase {

    private enum MockError: Error {
        case unimplemented
    }

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
        func fetchTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchSiriEligibleTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchFavoriteTracks() async throws -> [CDTrack] { [] }
        func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? { nil }
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDTrack { throw MockError.unimplemented }
        func fetchGenres() async throws -> [CDGenre] { [] }
        func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { throw MockError.unimplemented }
        func searchTracks(query: String) async throws -> [CDTrack] { [] }
        func searchArtists(query: String) async throws -> [CDArtist] { [] }
        func searchAlbums(query: String) async throws -> [CDAlbum] { [] }
        func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] { [] }
        func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] { [] }
        func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] { [] }
        func fetchMusicSources() async throws -> [CDMusicSource] { [] }
        func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { throw MockError.unimplemented }
        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
        func deleteAllData(forSourceCompositeKey: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] { [:] }
        func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {}
        func drainTrackReparentInfo() -> [TrackReparentInfo] { [] }
    }

    private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw MockError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    }

    private final class MockDownloadManager: DownloadManagerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _statusUpdates: [([CDDownload.Status], CDDownload.Status)] = []
        private var _fetchDownloadsCount = 0
        private var _fetchCompletedDownloadsCount = 0
        private var _deletedReferences: [OfflineTrackReference] = []

        var statusUpdates: [([CDDownload.Status], CDDownload.Status)] {
            lock.withLock { _statusUpdates }
        }

        var fetchDownloadsCount: Int {
            lock.withLock { _fetchDownloadsCount }
        }

        var fetchCompletedDownloadsCount: Int {
            lock.withLock { _fetchCompletedDownloadsCount }
        }

        var deletedReferences: [OfflineTrackReference] {
            lock.withLock { _deletedReferences }
        }

        func resetStatusUpdates() {
            lock.withLock {
                _statusUpdates.removeAll()
            }
        }

        func fetchDownloads() async throws -> [CDDownload] {
            lock.withLock { _fetchDownloadsCount += 1 }
            return []
        }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] {
            lock.withLock { _fetchCompletedDownloadsCount += 1 }
            return []
        }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload { throw MockError.unimplemented }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?, quality: String) async throws -> CDDownload { throw MockError.unimplemented }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {
            lock.withLock {
                _statusUpdates.append((statuses, status))
            }
        }
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {}
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws {
            guard let sourceCompositeKey else { return }
            lock.withLock {
                _deletedReferences.append(
                    OfflineTrackReference(
                        trackRatingKey: trackRatingKey,
                        trackSourceCompositeKey: sourceCompositeKey
                    )
                )
            }
        }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String? { nil }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private final class MockTargetRepository: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        var referencesByTarget: [String: [OfflineTrackReference]] = [:]
        var membershipCounts: [OfflineTrackReference: Int] = [:]
        var deletedTargetKeys: [String] = []

        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { [] }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { nil }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget { throw MockError.unimplemented }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {}
        func deleteTarget(key: String) async throws { deletedTargetKeys.append(key) }
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws {}
        func deleteAllTargets() async throws {}
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] {
            referencesByTarget[targetKey] ?? []
        }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {}
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { false }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int {
            membershipCounts[reference] ?? 0
        }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { [] }
        func totalTrackDurationMs() async throws -> Int64 { 0 }
    }

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class MockBackgroundExecutionCoordinator: OfflineDownloadBackgroundCoordinating {
        var onExecutionRequested: (() -> Void)?
        var onExpiration: (() -> Void)?
        var onBackgroundURLSessionEvents: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)?
        var onSystemWillSleep: (() -> Void)?
        var onSystemDidWake: (() -> Void)?
        var continuedProcessingRequests: [Int] = []

        func register() {}
        func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {
            continuedProcessingRequests.append(pendingTrackCount)
        }
        func setProgress(completedUnitCount: Int, totalUnitCount: Int) {}
        func finishCurrentTask(success: Bool) {}
        func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
            onBackgroundURLSessionEvents?(identifier, completionHandler)
        }
        func completeBackgroundURLSessionEvents(identifier: String) {}
        func handleSystemWillSleep() {
            onSystemWillSleep?()
        }
        func handleSystemDidWake() {
            onSystemDidWake?()
        }
    }

    private func makeService(
        downloadManager: MockDownloadManager = MockDownloadManager(),
        targetRepository: MockTargetRepository = MockTargetRepository(),
        backgroundCoordinator: OfflineDownloadBackgroundCoordinating? = nil,
        networkMonitor suppliedNetworkMonitor: NetworkMonitor? = nil,
        launchRecoveryStartedAt: Date = Date()
    ) async -> OfflineDownloadService {
        let accountManager = AccountManager(keychain: TestKeychain())
        let libraryRepository = MockLibraryRepository()
        let playlistRepository = MockPlaylistRepository()
        let networkMonitor = suppliedNetworkMonitor ?? NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )

        let service = OfflineDownloadService(
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            backgroundExecutionCoordinator: backgroundCoordinator ?? MockBackgroundExecutionCoordinator(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            toastCenter: ToastCenter(),
            lyricsService: LyricsService(syncCoordinator: syncCoordinator),
            launchRecoveryStartedAt: launchRecoveryStartedAt
        )

        await Task.yield()
        return service
    }

    func testLowDataModePausesActiveDownloads() async {
        let downloadManager = MockDownloadManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 0,
            monitorQueue: DispatchQueue(label: "test.network.low-data"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        let service = await makeService(
            downloadManager: downloadManager,
            networkMonitor: networkMonitor
        )
        downloadManager.resetStatusUpdates()

        networkMonitor.injectNetworkStateForTesting(
            .online(.wifi),
            isConstrained: true,
            debounced: false
        )
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(service.queueStatusReason, .lowDataMode)
        XCTAssertTrue(downloadManager.statusUpdates.contains { statuses, status in
            statuses == [.downloading] && status == .paused
        })
    }

    func testRemovingTargetClearsLyricsOnlyForLastReferencedDownload() async throws {
        let sourceKey = "plex:test-account:test-server:test-library"
        let orphaned = OfflineTrackReference(
            trackRatingKey: "orphaned-\(UUID().uuidString)",
            trackSourceCompositeKey: sourceKey
        )
        let shared = OfflineTrackReference(
            trackRatingKey: "shared-\(UUID().uuidString)",
            trackSourceCompositeKey: sourceKey
        )
        let targetKey = "offline:test-target"
        let targetRepository = MockTargetRepository()
        targetRepository.referencesByTarget[targetKey] = [orphaned, shared]
        targetRepository.membershipCounts[orphaned] = 1
        targetRepository.membershipCounts[shared] = 2

        let cacheDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Ensemble/LyricsCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let orphanedCacheURL = cacheDirectory.appendingPathComponent(
            lyricsCacheFilenamePrefix(for: orphaned) + "lyrics_test.json"
        )
        let sharedCacheURL = cacheDirectory.appendingPathComponent(
            lyricsCacheFilenamePrefix(for: shared) + "lyrics_test.json"
        )
        try Data([0x01]).write(to: orphanedCacheURL)
        try Data([0x02]).write(to: sharedCacheURL)
        defer {
            try? FileManager.default.removeItem(at: orphanedCacheURL)
            try? FileManager.default.removeItem(at: sharedCacheURL)
        }

        let downloadManager = MockDownloadManager()
        let service = await makeService(
            downloadManager: downloadManager,
            targetRepository: targetRepository
        )

        await service.removeTarget(key: targetKey)

        XCTAssertEqual(targetRepository.deletedTargetKeys, [targetKey])
        XCTAssertEqual(downloadManager.deletedReferences, [orphaned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedCacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedCacheURL.path))
    }

    private func lyricsCacheFilenamePrefix(for reference: OfflineTrackReference) -> String {
        "\(reference.trackRatingKey):\(reference.trackSourceCompositeKey):"
            .replacingOccurrences(
                of: "[^a-zA-Z0-9_-]",
                with: "_",
                options: .regularExpression
            )
    }

    func testPlaybackStateSwitchesWorkMode() async {
        let service = await makeService()
        let trackPublisher = CurrentValueSubject<Track?, Never>(nil)
        let playbackStatePublisher = CurrentValueSubject<PlaybackState, Never>(.stopped)

        service.observePlayback(
            trackPublisher: trackPublisher.eraseToAnyPublisher(),
            playbackStatePublisher: playbackStatePublisher.eraseToAnyPublisher()
        )

        XCTAssertEqual(service.currentDownloadWorkMode, .foregroundIdle)

        playbackStatePublisher.send(.playing)
        await Task.yield()
        XCTAssertEqual(service.currentDownloadWorkMode, .interactivePlayback)

        playbackStatePublisher.send(.paused)
        await Task.yield()
        XCTAssertEqual(service.currentDownloadWorkMode, .foregroundIdle)
    }

    func testLaunchRecoveryDoesNotRunHeavyDownloadHealingBeforeFirstInteraction() async {
        let downloadManager = MockDownloadManager()
        let service = await makeService(downloadManager: downloadManager)

        await Task.yield()
        await service.handleAppWillEnterForeground()
        await Task.yield()

        XCTAssertEqual(downloadManager.fetchDownloadsCount, 0)
        XCTAssertEqual(downloadManager.fetchCompletedDownloadsCount, 0)
        XCTAssertTrue(
            downloadManager.statusUpdates.contains { $0.0 == [.downloading] },
            "Launch should still recover interrupted .downloading records without scanning every completed file."
        )
    }

    func testForegroundRecoveryDefersHeavyDownloadHealingAfterLaunchGrace() async {
        let downloadManager = MockDownloadManager()
        let service = await makeService(
            downloadManager: downloadManager,
            launchRecoveryStartedAt: Date().addingTimeInterval(-60)
        )

        await Task.yield()
        await service.handleAppWillEnterForeground()
        await Task.yield()

        XCTAssertEqual(downloadManager.fetchDownloadsCount, 0)
        XCTAssertEqual(downloadManager.fetchCompletedDownloadsCount, 0)
        XCTAssertTrue(
            downloadManager.statusUpdates.contains { $0.0 == [.downloading] },
            "Foreground recovery should repair interrupted .downloading records without scanning every completed file."
        )
    }

    func testBackgroundLifecycleOverridesPlaybackWorkMode() async {
        let service = await makeService()
        let trackPublisher = CurrentValueSubject<Track?, Never>(nil)
        let playbackStatePublisher = CurrentValueSubject<PlaybackState, Never>(.playing)

        service.observePlayback(
            trackPublisher: trackPublisher.eraseToAnyPublisher(),
            playbackStatePublisher: playbackStatePublisher.eraseToAnyPublisher()
        )
        await Task.yield()
        XCTAssertEqual(service.currentDownloadWorkMode, .interactivePlayback)

        await service.handleAppDidEnterBackground()
        XCTAssertEqual(service.currentDownloadWorkMode, .background)

        await service.handleAppWillEnterForeground()
        XCTAssertEqual(service.currentDownloadWorkMode, .interactivePlayback)
    }

    func testBackgroundLifecycleDoesNotPauseDownloadingRecordsImmediately() async {
        let downloadManager = MockDownloadManager()
        let backgroundCoordinator = MockBackgroundExecutionCoordinator()
        let service = await makeService(
            downloadManager: downloadManager,
            backgroundCoordinator: backgroundCoordinator
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        downloadManager.resetStatusUpdates()

        await service.handleAppDidEnterBackground()

        XCTAssertEqual(service.currentDownloadWorkMode, .background)
        XCTAssertFalse(
            downloadManager.statusUpdates.contains { $0.0 == [.downloading] && $0.1 == .paused },
            "Backgrounding should request an execution window and leave active downloads running until expiration."
        )
        XCTAssertEqual(backgroundCoordinator.continuedProcessingRequests.count, 1)
    }

    func testSystemSleepMarksDownloadingRecordsPaused() async {
        let downloadManager = MockDownloadManager()
        let service = await makeService(downloadManager: downloadManager)
        try? await Task.sleep(nanoseconds: 30_000_000)
        downloadManager.resetStatusUpdates()

        await service.handleSystemWillSleep()

        XCTAssertTrue(
            downloadManager.statusUpdates.contains { $0.0 == [.downloading] && $0.1 == .paused }
        )
    }

    func testBackgroundURLSessionWakeRunsRecoveryBeforeCompletion() async {
        let downloadManager = MockDownloadManager()
        let backgroundCoordinator = OfflineBackgroundExecutionCoordinator()
        let service = await makeService(
            downloadManager: downloadManager,
            backgroundCoordinator: backgroundCoordinator
        )
        _ = service
        try? await Task.sleep(nanoseconds: 30_000_000)
        downloadManager.resetStatusUpdates()
        var didComplete = false

        backgroundCoordinator.handleBackgroundURLSessionEvents(identifier: "com.test.downloads") {
            didComplete = true
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(didComplete)
        XCTAssertTrue(
            downloadManager.statusUpdates.contains { $0.0 == [.downloading] }
        )
    }
}
