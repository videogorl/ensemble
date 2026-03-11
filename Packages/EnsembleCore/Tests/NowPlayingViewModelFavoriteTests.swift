import Combine
import XCTest
@testable import EnsembleCore
import EnsemblePersistence
import EnsembleAPI

@MainActor
final class NowPlayingViewModelFavoriteTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

    private final class MockPlaybackService: PlaybackServiceProtocol {
        private let currentTrackSubject = CurrentValueSubject<Track?, Never>(nil)
        private let playbackStateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)
        private let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
        private let queueSubject = CurrentValueSubject<[QueueItem], Never>([])
        private let queueIndexSubject = CurrentValueSubject<Int, Never>(-1)
        private let shuffleSubject = CurrentValueSubject<Bool, Never>(false)
        private let repeatModeSubject = CurrentValueSubject<RepeatMode, Never>(.off)
        private let waveformSubject = CurrentValueSubject<[Double], Never>([])
        private let autoplayEnabledSubject = CurrentValueSubject<Bool, Never>(false)
        private let autoplayTracksSubject = CurrentValueSubject<[Track], Never>([])
        private let autoplayActiveSubject = CurrentValueSubject<Bool, Never>(false)
        private let radioModeSubject = CurrentValueSubject<RadioMode, Never>(.off)
        private let recommendationsSubject = CurrentValueSubject<Bool, Never>(false)
        private let historySubject = CurrentValueSubject<[QueueItem], Never>([])
        private var mockedDuration: TimeInterval = 0

        var currentTrack: Track? { currentTrackSubject.value }
        var playbackState: PlaybackState { playbackStateSubject.value }
        var currentTime: TimeInterval { currentTimeSubject.value }
        var bufferedProgressValue: Double { 0 }
        var duration: TimeInterval { mockedDuration > 0 ? mockedDuration : (currentTrack?.duration ?? 0) }
        var queue: [QueueItem] { queueSubject.value }
        var currentQueueIndex: Int { queueIndexSubject.value }
        var isShuffleEnabled: Bool { shuffleSubject.value }
        var repeatMode: RepeatMode { repeatModeSubject.value }
        var waveformHeights: [Double] { waveformSubject.value }
        var frequencyBands: [Double] { [] }
        var isExternalPlaybackActive: Bool { false }
        var isAutoplayEnabled: Bool { autoplayEnabledSubject.value }
        var autoplayTracks: [Track] { autoplayTracksSubject.value }
        var isAutoplayActive: Bool { autoplayActiveSubject.value }
        var radioMode: RadioMode { radioModeSubject.value }
        var recommendationsExhausted: Bool { recommendationsSubject.value }
        var queueSections: QueueSections { .empty }
        var playbackHistory: [QueueItem] { historySubject.value }

        var currentTrackPublisher: AnyPublisher<Track?, Never> { currentTrackSubject.eraseToAnyPublisher() }
        var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { playbackStateSubject.eraseToAnyPublisher() }
        var currentTimePublisher: AnyPublisher<TimeInterval, Never> { currentTimeSubject.eraseToAnyPublisher() }
        var currentTimeValue: TimeInterval { currentTimeSubject.value }
        var queuePublisher: AnyPublisher<[QueueItem], Never> { queueSubject.eraseToAnyPublisher() }
        var currentQueueIndexPublisher: AnyPublisher<Int, Never> { queueIndexSubject.eraseToAnyPublisher() }
        var shufflePublisher: AnyPublisher<Bool, Never> { shuffleSubject.eraseToAnyPublisher() }
        var repeatModePublisher: AnyPublisher<RepeatMode, Never> { repeatModeSubject.eraseToAnyPublisher() }
        var waveformPublisher: AnyPublisher<[Double], Never> { waveformSubject.eraseToAnyPublisher() }
        var frequencyBandsPublisher: AnyPublisher<[Double], Never> { Just([]).eraseToAnyPublisher() }
        var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { autoplayEnabledSubject.eraseToAnyPublisher() }
        var autoplayTracksPublisher: AnyPublisher<[Track], Never> { autoplayTracksSubject.eraseToAnyPublisher() }
        var autoplayActivePublisher: AnyPublisher<Bool, Never> { autoplayActiveSubject.eraseToAnyPublisher() }
        var radioModePublisher: AnyPublisher<RadioMode, Never> { radioModeSubject.eraseToAnyPublisher() }
        var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { recommendationsSubject.eraseToAnyPublisher() }
        var historyPublisher: AnyPublisher<[QueueItem], Never> { historySubject.eraseToAnyPublisher() }

        func setCurrentTrack(_ track: Track?) {
            currentTrackSubject.send(track)
        }

        func setPlaybackState(_ state: PlaybackState) {
            playbackStateSubject.send(state)
        }

        func setCurrentTime(_ time: TimeInterval) {
            currentTimeSubject.send(time)
        }

        func setDuration(_ duration: TimeInterval) {
            mockedDuration = duration
        }

        func play(track: Track) async {}
        func play(tracks: [Track], startingAt index: Int) async {}
        func shufflePlay(tracks: [Track]) async {}
        func playQueueIndex(_ index: Int) async {}
        func pause() {}
        func resume() {}
        func stop() {}
        func retryCurrentTrack() async {}
        func next() {}
        func previous() {}
        func seek(to time: TimeInterval) {
            currentTimeSubject.send(time)
        }
        func startFastSeeking(forward: Bool) {}
        func stopFastSeeking() {}
        func addToQueue(_ track: Track) {}
        func addToQueue(_ tracks: [Track]) {}
        func playNext(_ track: Track) {}
        func playNext(_ tracks: [Track]) {}
        func playLast(_ track: Track) {}
        func playLast(_ tracks: [Track]) {}
        func removeFromQueue(at index: Int) {}
        func clearQueue() {}
        func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int) {}
        func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {}
        func toggleShuffle() {}
        func cycleRepeatMode() {}
        func toggleAutoplay() {}
        func refreshAutoplayQueue() async {}
        func enableRadio(tracks: [Track]) async {}
        func playArtistRadio(for artist: Artist) async {}
        func playAlbumRadio(for album: Album) async {}
        func isTrackAutoGenerated(trackId: String) -> Bool { false }
        func playFromHistory(at historyIndex: Int) async {}
        func updateVisualizerPosition(_ time: TimeInterval) {}
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
        func upsertAlbum(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, sourceCompositeKey: String?) async throws -> CDAlbum { throw MockError.unimplemented }
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
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, sourceCompositeKey: String?) async throws -> CDTrack { throw MockError.unimplemented }
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

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int { 0 }
        func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int { 0 }
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class MockPendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
        func fetchPendingMutations() async throws -> [CDPendingMutation] { [] }
        func fetchAllMutations() async throws -> [CDPendingMutation] { [] }
        func enqueueMutation(id: String, type: CDPendingMutation.MutationType, payload: Data, sourceCompositeKey: String?) async throws {}
        func incrementRetryCount(id: String) async throws {}
        func markFailed(id: String) async throws {}
        func resetToRetry(id: String) async throws {}
        func deleteMutation(id: String) async throws {}
        func deleteAllMutations() async throws {}
        func countPendingMutations() async throws -> Int { 0 }
    }

    private final class MockDownloadManager: DownloadManagerProtocol, @unchecked Sendable {
        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload? { nil }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload { fatalError() }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?, quality: String) async throws -> CDDownload { fatalError() }
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
        func deleteAllDownloads() async throws {}
    }

    private func makeViewModel() -> (viewModel: NowPlayingViewModel, playbackService: MockPlaybackService) {
        let libraryRepository = MockLibraryRepository()
        let playlistRepository = MockPlaylistRepository()
        let accountManager = AccountManager(keychain: TestKeychain())
        let playbackService = MockPlaybackService()
        let networkMonitor = NetworkMonitor()
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let mutationCoordinator = MutationCoordinator(
            repository: MockPendingMutationRepository(),
            networkMonitor: networkMonitor,
            syncCoordinator: syncCoordinator
        )
        let trackAvailabilityResolver = TrackAvailabilityResolver(
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker,
            downloadManager: MockDownloadManager()
        )

        let lyricsService = LyricsService(
            syncCoordinator: syncCoordinator
        )

        return (NowPlayingViewModel(
            playbackService: playbackService,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            navigationCoordinator: NavigationCoordinator(),
            toastCenter: ToastCenter(),
            mutationCoordinator: mutationCoordinator,
            trackAvailabilityResolver: trackAvailabilityResolver,
            lyricsService: lyricsService
        ), playbackService)
    }

    func testSetTrackFavoriteUsesLovedRating() async {
        let viewModel = makeViewModel().viewModel
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test")
        var recordedRating: Int?
        var storedRating: Int?

        viewModel.trackRatingMutationHandlerForTesting = { _, rating in
            recordedRating = rating
        }
        viewModel.trackRatingStoreHandlerForTesting = { _, rating in
            storedRating = rating
        }

        await viewModel.setTrackFavorite(true, for: track)

        XCTAssertEqual(recordedRating, 10)
        XCTAssertEqual(storedRating, 10)
    }

    func testSetTrackFavoriteUsesNilRatingWhenUnfavoriting() async {
        let viewModel = makeViewModel().viewModel
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", rating: 10)
        var recordedRating: Int?
        var storedRating: Int?

        viewModel.trackRatingMutationHandlerForTesting = { _, rating in
            recordedRating = rating
        }
        viewModel.trackRatingStoreHandlerForTesting = { _, rating in
            storedRating = rating
        }

        await viewModel.setTrackFavorite(false, for: track)

        XCTAssertNil(recordedRating)
        XCTAssertEqual(storedRating, 0)
    }

    func testSetTrackFavoriteStopsWhenMutationFails() async {
        let viewModel = makeViewModel().viewModel
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test")
        var storedRatings: [Int] = []

        struct TestError: Error {}

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in
            throw TestError()
        }
        viewModel.trackRatingStoreHandlerForTesting = { _, rating in
            storedRatings.append(rating)
        }

        await viewModel.setTrackFavorite(true, for: track)

        XCTAssertEqual(storedRatings, [10, 0])
    }

    func testToggleRatingUpdatesFavoriteStateForCurrentTrack() async {
        let (viewModel, playback) = makeViewModel()
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", rating: 10)

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        playback.setCurrentTrack(track)
        await Task.yield()
        viewModel.currentRating = .loved

        viewModel.toggleRating()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.isTrackFavorited(track))
    }

    func testProgressPinsAtCompleteWhenCurrentTimeReachesDuration() async {
        let (viewModel, playback) = makeViewModel()
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 100)
        playback.setCurrentTrack(track)
        playback.setDuration(100)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(100)

        await Task.yield()

        // When currentTime == duration, progress pins at 1.0 and remaining shows -0:00
        XCTAssertEqual(viewModel.progress, 1.0, accuracy: 0.001)
        XCTAssertEqual(viewModel.scrubberDuration, 100, accuracy: 0.001)
    }

    func testScrubberDurationMatchesPlaybackDuration() async {
        let (viewModel, playback) = makeViewModel()
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200)
        playback.setCurrentTrack(track)
        playback.setDuration(200)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(50)

        await Task.yield()

        // scrubberDuration should match the playback duration exactly
        XCTAssertEqual(viewModel.scrubberDuration, 200, accuracy: 0.001)
    }
}
