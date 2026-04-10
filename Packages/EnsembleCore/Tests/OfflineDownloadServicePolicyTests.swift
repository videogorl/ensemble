import Combine
import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class OfflineDownloadServicePolicyTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        func save(_ value: String, forKey key: String) throws {}
        func get(_ key: String) throws -> String? { nil }
        func delete(_ key: String) throws {}
    }

    private enum MockError: Error {
        case unimplemented
    }

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func upsertArtist(ratingKey: String, key: String, name: String, summary: String?, thumbPath: String?, artPath: String?, dateAdded: Date?, dateModified: Date?, sourceCompositeKey: String?) async throws -> CDArtist { throw MockError.unimplemented }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
        func upsertAlbum(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDAlbum { throw MockError.unimplemented }
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
        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload { throw MockError.unimplemented }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?, quality: String) async throws -> CDDownload { throw MockError.unimplemented }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {}
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws {}
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String? { nil }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private final class MockTargetRepository: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { [] }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { nil }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget { throw MockError.unimplemented }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {}
        func deleteTarget(key: String) async throws {}
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws {}
        func deleteAllTargets() async throws {}
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] { [] }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {}
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { false }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int { 0 }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { [] }
        func totalTrackDurationMs() async throws -> Int64 { 0 }
    }

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int { 0 }
        func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int { 0 }
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class MockBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating {
        var onExecutionRequested: (() -> Void)?
        var onExpiration: (() -> Void)?

        func register() {}
        func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {}
        func setProgress(completedUnitCount: Int, totalUnitCount: Int) {}
        func finishCurrentTask(success: Bool) {}
    }

    private func makeService() async -> OfflineDownloadService {
        let accountManager = AccountManager(keychain: TestKeychain())
        let libraryRepository = MockLibraryRepository()
        let playlistRepository = MockPlaylistRepository()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
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
            downloadManager: MockDownloadManager(),
            targetRepository: MockTargetRepository(),
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            backgroundExecutionCoordinator: MockBackgroundExecutionCoordinator(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            toastCenter: ToastCenter(),
            lyricsService: LyricsService(syncCoordinator: syncCoordinator)
        )

        await Task.yield()
        return service
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
}
