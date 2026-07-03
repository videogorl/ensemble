import Combine
import EnsembleAPI
@testable import EnsembleCore
import EnsemblePersistence
import XCTest

@MainActor
final class NowPlayingViewModelFavoriteTests: XCTestCase {

    private final class MockPlaybackService: PlaybackServiceProtocol {
        private let currentTrackSubject = CurrentValueSubject<Track?, Never>(nil)
        private let playbackStateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)
        private let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
        private let presentationTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
        private let bufferedProgressSubject = CurrentValueSubject<Double, Never>(0)
        private let queueSubject = CurrentValueSubject<[QueueItem], Never>([])
        private let queueIndexSubject = CurrentValueSubject<Int, Never>(-1)
        private let shuffleSubject = CurrentValueSubject<Bool, Never>(false)
        private let repeatModeSubject = CurrentValueSubject<RepeatMode, Never>(.off)
        private let waveformSubject = CurrentValueSubject<[Double], Never>([])
        private let autoplayEnabledSubject = CurrentValueSubject<Bool, Never>(false)
        private let smartMixEnabledSubject = CurrentValueSubject<Bool, Never>(false)
        private let autoplayTracksSubject = CurrentValueSubject<[Track], Never>([])
        private let autoplayActiveSubject = CurrentValueSubject<Bool, Never>(false)
        private let radioModeSubject = CurrentValueSubject<RadioMode, Never>(.off)
        private let recommendationsSubject = CurrentValueSubject<Bool, Never>(false)
        private let historySubject = CurrentValueSubject<[QueueItem], Never>([])
        private var mockedDuration: TimeInterval = 0
        private(set) var lastPlayedTrack: Track?
        private(set) var lastQueuedTracks: [Track] = []
        private(set) var lastQueuedStartIndex: Int?
        private(set) var lastShufflePlayTracks: [Track] = []
        private(set) var appliedRatings: [(trackIdentity: String, rating: Int)] = []

        init(initialTrack: Track? = nil) {
            currentTrackSubject.send(initialTrack)
        }

        var currentTrack: Track? {
            currentTrackSubject.value
        }

        var playbackState: PlaybackState {
            playbackStateSubject.value
        }

        var currentTime: TimeInterval {
            currentTimeSubject.value
        }

        var presentationTime: TimeInterval {
            presentationTimeSubject.value
        }

        var bufferedProgressValue: Double {
            bufferedProgressSubject.value
        }

        var bufferedProgressPublisher: AnyPublisher<Double, Never> {
            bufferedProgressSubject.eraseToAnyPublisher()
        }

        var duration: TimeInterval {
            mockedDuration > 0 ? mockedDuration : (currentTrack?.duration ?? 0)
        }

        var queue: [QueueItem] {
            queueSubject.value
        }

        var currentQueueIndex: Int {
            queueIndexSubject.value
        }

        var isShuffleEnabled: Bool {
            shuffleSubject.value
        }

        var repeatMode: RepeatMode {
            repeatModeSubject.value
        }

        var waveformHeights: [Double] {
            waveformSubject.value
        }

        var frequencyBands: [Double] {
            []
        }

        var isExternalPlaybackActive: Bool {
            false
        }

        var isAutoplayEnabled: Bool {
            autoplayEnabledSubject.value
        }

        var isSmartMixEnabled: Bool {
            smartMixEnabledSubject.value
        }

        var autoplayTracks: [Track] {
            autoplayTracksSubject.value
        }

        var isAutoplayActive: Bool {
            autoplayActiveSubject.value
        }

        var radioMode: RadioMode {
            radioModeSubject.value
        }

        var recommendationsExhausted: Bool {
            recommendationsSubject.value
        }

        var queueSections: QueueSections {
            .empty
        }

        var playbackHistory: [QueueItem] {
            historySubject.value
        }

        var currentTrackPublisher: AnyPublisher<Track?, Never> {
            currentTrackSubject.eraseToAnyPublisher()
        }

        var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
            playbackStateSubject.eraseToAnyPublisher()
        }

        var currentTimePublisher: AnyPublisher<TimeInterval, Never> {
            currentTimeSubject.eraseToAnyPublisher()
        }

        var currentTimeValue: TimeInterval {
            currentTimeSubject.value
        }

        var presentationTimePublisher: AnyPublisher<TimeInterval, Never> {
            presentationTimeSubject.eraseToAnyPublisher()
        }

        var presentationTimeValue: TimeInterval {
            presentationTimeSubject.value
        }

        var queuePublisher: AnyPublisher<[QueueItem], Never> {
            queueSubject.eraseToAnyPublisher()
        }

        var currentQueueIndexPublisher: AnyPublisher<Int, Never> {
            queueIndexSubject.eraseToAnyPublisher()
        }

        var shufflePublisher: AnyPublisher<Bool, Never> {
            shuffleSubject.eraseToAnyPublisher()
        }

        var repeatModePublisher: AnyPublisher<RepeatMode, Never> {
            repeatModeSubject.eraseToAnyPublisher()
        }

        var waveformPublisher: AnyPublisher<[Double], Never> {
            waveformSubject.eraseToAnyPublisher()
        }

        var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
            Just([]).eraseToAnyPublisher()
        }

        var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> {
            Just(false).eraseToAnyPublisher()
        }

        var autoplayEnabledPublisher: AnyPublisher<Bool, Never> {
            autoplayEnabledSubject.eraseToAnyPublisher()
        }

        var smartMixEnabledPublisher: AnyPublisher<Bool, Never> {
            smartMixEnabledSubject.eraseToAnyPublisher()
        }

        var autoplayTracksPublisher: AnyPublisher<[Track], Never> {
            autoplayTracksSubject.eraseToAnyPublisher()
        }

        var autoplayActivePublisher: AnyPublisher<Bool, Never> {
            autoplayActiveSubject.eraseToAnyPublisher()
        }

        var radioModePublisher: AnyPublisher<RadioMode, Never> {
            radioModeSubject.eraseToAnyPublisher()
        }

        var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> {
            recommendationsSubject.eraseToAnyPublisher()
        }

        var historyPublisher: AnyPublisher<[QueueItem], Never> {
            historySubject.eraseToAnyPublisher()
        }

        var isInstrumentalModeActive: Bool {
            false
        }

        var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> {
            Just(false).eraseToAnyPublisher()
        }

        func setInstrumentalMode(_: Bool) {}

        var isScreenMirroringActive: Bool = false

        func setCurrentTrack(_ track: Track?) {
            currentTrackSubject.send(track)
        }

        func setPlaybackState(_ state: PlaybackState) {
            playbackStateSubject.send(state)
        }

        func setQueue(_ queue: [QueueItem], currentIndex: Int) {
            queueSubject.send(queue)
            queueIndexSubject.send(currentIndex)
        }

        func setHistory(_ history: [QueueItem]) {
            historySubject.send(history)
        }

        func setSmartMixEnabled(_ isEnabled: Bool) {
            smartMixEnabledSubject.send(isEnabled)
        }

        func setCurrentTime(_ time: TimeInterval) {
            currentTimeSubject.send(time)
            presentationTimeSubject.send(time)
        }

        func setPresentationTime(_ time: TimeInterval) {
            presentationTimeSubject.send(time)
        }

        func setDuration(_ duration: TimeInterval) {
            mockedDuration = duration
        }

        func setBufferedProgress(_ progress: Double) {
            bufferedProgressSubject.send(progress)
        }

        func play(track: Track, context _: PlaybackStartContext) async {
            lastPlayedTrack = track
            lastQueuedTracks = [track]
            lastQueuedStartIndex = 0
        }

        func play(tracks: [Track], startingAt index: Int, context _: PlaybackStartContext) async {
            lastPlayedTrack = tracks.indices.contains(index) ? tracks[index] : nil
            lastQueuedTracks = tracks
            lastQueuedStartIndex = index
        }

        func shufflePlay(tracks: [Track], context _: PlaybackStartContext) async {
            lastShufflePlayTracks = tracks
        }

        func playQueueIndex(_: Int) async {}
        func pause() {}
        func resume() {}
        func stop() {}
        func retryCurrentTrack() async {}
        func next() {}
        func previous() {}
        func seek(to time: TimeInterval) {
            currentTimeSubject.send(time)
            presentationTimeSubject.send(time)
        }

        func startFastSeeking(forward _: Bool) {}
        func stopFastSeeking() {}
        func addToQueue(_: Track) {}
        func addToQueue(_: [Track]) {}
        func playNext(_: Track) {}
        func playNext(_: [Track]) {}
        func playLast(_: Track) {}
        func playLast(_: [Track]) {}
        func removeFromQueue(at _: Int) {}
        func clearQueue() {}
        func moveQueueItem(byId _: String, from _: Int, to _: Int) {}
        func toggleShuffle() {}
        func cycleRepeatMode() {}
        func toggleAutoplay() {}
        func toggleSmartMix() {
            smartMixEnabledSubject.send(!smartMixEnabledSubject.value)
        }
        func refreshAutoplayQueue() async {}
        func enableRadio(tracks _: [Track]) async {}
        func isTrackAutoGenerated(trackId _: String) -> Bool {
            false
        }

        func playFromHistory(at _: Int) async {}
        func applyRatingLocally(track: Track, rating: Int) async {
            appliedRatings.append((trackIdentity: track.sourceScopedID, rating: rating))
        }

        func updateVisualizerPosition(_: TimeInterval) {}
        func setVisualizationConsumer(_: VisualizationConsumer, isVisible _: Bool) {}
        func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) {
            (nil, nil)
        }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        private let coreDataStack = CoreDataStack.inMemory()
        var fetchedTrack: CDTrack?

        func setFetchedTrack(id: String, sourceCompositeKey: String, thumbPath: String) {
            let track = CDTrack(context: coreDataStack.viewContext)
            track.ratingKey = id
            track.key = "/library/metadata/\(id)"
            track.title = "2085"
            track.artistName = "AJR"
            track.albumName = "The Maybe Man"
            track.duration = 331_000
            track.thumbPath = thumbPath
            track.sourceCompositeKey = sourceCompositeKey
            fetchedTrack = track
        }

        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] {
            []
        }

        func fetchArtist(ratingKey _: String) async throws -> CDArtist? {
            nil
        }

        func upsertArtist(ratingKey _: String, key _: String, name _: String, summary _: String?, thumbPath _: String?, artPath _: String?, dateAdded _: Date?, dateModified _: Date?, sourceCompositeKey _: String?) async throws -> CDArtist {
            throw MockError.unimplemented
        }

        func fetchAlbums() async throws -> [CDAlbum] {
            []
        }

        func fetchAlbum(ratingKey _: String) async throws -> CDAlbum? {
            nil
        }

        func fetchAlbums(forArtist _: String) async throws -> [CDAlbum] {
            []
        }

        func upsertAlbum(ratingKey _: String, key _: String, title _: String, artistName _: String?, albumArtist _: String?, artistRatingKey _: String?, summary _: String?, thumbPath _: String?, artPath _: String?, year _: Int?, trackCount _: Int?, dateAdded _: Date?, dateModified _: Date?, rating _: Int?, genreNames _: String?, sourceCompositeKey _: String?) async throws -> CDAlbum {
            throw MockError.unimplemented
        }

        func fetchTracks() async throws -> [CDTrack] {
            []
        }

        func fetchTracks(forSource _: String) async throws -> [CDTrack] {
            []
        }

        func fetchSiriEligibleTracks() async throws -> [CDTrack] {
            []
        }

        func fetchTracks(forAlbum _: String) async throws -> [CDTrack] {
            []
        }

        func fetchTracks(forAlbum _: String, sourceCompositeKey _: String) async throws -> [CDTrack] {
            []
        }

        func fetchTracks(forArtist _: String) async throws -> [CDTrack] {
            []
        }

        func fetchTracks(forArtist _: String, sourceCompositeKey _: String) async throws -> [CDTrack] {
            []
        }

        func fetchFavoriteTracks() async throws -> [CDTrack] {
            []
        }

        func fetchTrack(ratingKey: String) async throws -> CDTrack? {
            guard let fetchedTrack, fetchedTrack.ratingKey == ratingKey else { return nil }
            return fetchedTrack
        }

        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? {
            guard let fetchedTrack, fetchedTrack.ratingKey == ratingKey else { return nil }
            if let sourceCompositeKey {
                return fetchedTrack.sourceCompositeKey == sourceCompositeKey ? fetchedTrack : nil
            }
            return fetchedTrack
        }

        func upsertTrack(ratingKey _: String, key _: String, title _: String, artistName _: String?, albumName _: String?, albumRatingKey _: String?, trackNumber _: Int?, discNumber _: Int?, duration _: Int?, thumbPath _: String?, streamKey _: String?, dateAdded _: Date?, dateModified _: Date?, lastPlayed _: Date?, lastRatedAt _: Date?, rating _: Int?, playCount _: Int?, genreNames _: String?, sourceCompositeKey _: String?) async throws -> CDTrack {
            throw MockError.unimplemented
        }

        func fetchGenres() async throws -> [CDGenre] {
            []
        }

        func upsertGenre(ratingKey _: String?, key _: String, title _: String, sourceCompositeKey _: String?) async throws -> CDGenre {
            throw MockError.unimplemented
        }

        func searchTracks(query _: String) async throws -> [CDTrack] {
            []
        }

        func searchArtists(query _: String) async throws -> [CDArtist] {
            []
        }

        func searchAlbums(query _: String) async throws -> [CDAlbum] {
            []
        }

        func findTracksByTitle(_: String, sourceCompositeKeys _: Set<String>?) async throws -> [CDTrack] {
            []
        }

        func findArtistsByName(_: String, sourceCompositeKeys _: Set<String>?) async throws -> [CDArtist] {
            []
        }

        func findAlbumsByTitle(_: String, sourceCompositeKeys _: Set<String>?) async throws -> [CDAlbum] {
            []
        }

        func fetchMusicSources() async throws -> [CDMusicSource] {
            []
        }

        func upsertMusicSource(compositeKey _: String, type _: String, accountId _: String, serverId _: String, libraryId _: String, displayName _: String?, accountName _: String?) async throws -> CDMusicSource {
            throw MockError.unimplemented
        }

        func updateMusicSourceSyncTimestamp(compositeKey _: String) async throws {}
        func deleteAllData(forSourceCompositeKey _: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn _: Set<String>, forSource _: String) async throws -> Int {
            0
        }

        func removeOrphanedAlbums(notIn _: Set<String>, forSource _: String) async throws -> Int {
            0
        }

        func removeOrphanedTracks(notIn _: Set<String>, forSource _: String) async throws -> Int {
            0
        }

        func removeOrphanedGenres(notIn _: Set<String>, forSource _: String) async throws -> Int {
            0
        }

        func fetchTrackRatings(forSource _: String) async throws -> [String: Int16] {
            [:]
        }

        func fetchArtistTimestamps(forSource _: String) async throws -> [String: Date] {
            [:]
        }

        func fetchAlbumTimestamps(forSource _: String) async throws -> [String: Date] {
            [:]
        }

        func fetchTrackTimestamps(forSource _: String) async throws -> [String: Date] {
            [:]
        }

        func batchUpsertArtists(_: [ArtistUpsertInput], sourceCompositeKey _: String) async throws {}
        func batchUpsertAlbums(_: [AlbumUpsertInput], sourceCompositeKey _: String) async throws {}
        func batchUpsertTracks(_: [TrackUpsertInput], sourceCompositeKey _: String) async throws {}
        func drainTrackReparentInfo() -> [TrackReparentInfo] {
            []
        }
    }

    private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] {
            []
        }

        func fetchPlaylists(sourceCompositeKey _: String?) async throws -> [CDPlaylist] {
            []
        }

        func fetchPlaylist(ratingKey _: String) async throws -> CDPlaylist? {
            nil
        }

        func fetchPlaylist(ratingKey _: String, sourceCompositeKey _: String?) async throws -> CDPlaylist? {
            nil
        }

        func searchPlaylists(query _: String) async throws -> [CDPlaylist] {
            []
        }

        func findPlaylistsByTitle(_: String, sourceCompositeKeys _: Set<String>?) async throws -> [CDPlaylist] {
            []
        }

        func upsertPlaylist(ratingKey _: String, key _: String, title _: String, summary _: String?, compositePath _: String?, isSmart _: Bool, duration _: Int?, trackCount _: Int?, dateAdded _: Date?, dateModified _: Date?, lastPlayed _: Date?, sourceCompositeKey _: String?) async throws -> CDPlaylist {
            throw MockError.unimplemented
        }

        func setPlaylistTracks(_: [String], forPlaylist _: String, sourceCompositeKey _: String?) async throws {}
        func deletePlaylist(ratingKey _: String) async throws {}
        func deletePlaylists(sourceCompositeKey _: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn _: Set<String>, forSource _: String) async throws -> Int {
            0
        }

        func fetchPlaylistTimestamps(forSource _: String) async throws -> [String: Date] {
            [:]
        }
    }

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func getLocalArtworkPath(for _: CDAlbum) async throws -> String? {
            nil
        }

        func getLocalArtworkPath(for _: CDArtist) async throws -> String? {
            nil
        }

        func getLocalArtworkPath(for _: CDPlaylist) async throws -> String? {
            nil
        }

        func downloadAndCacheArtwork(from _: URL, ratingKey _: String, type _: ArtworkType) async throws {}
        func deleteArtwork(ratingKey _: String, type _: ArtworkType) {}
        func deleteArtwork(forRatingKeys _: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 {
            0
        }
    }

    private final class MockPendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
        func fetchPendingMutations() async throws -> [CDPendingMutation] {
            []
        }

        func fetchAllMutations() async throws -> [CDPendingMutation] {
            []
        }

        func enqueueMutation(id _: String, type _: CDPendingMutation.MutationType, payload _: Data, sourceCompositeKey _: String?) async throws {}
        func incrementRetryCount(id _: String) async throws {}
        func markFailed(id _: String) async throws {}
        func resetToRetry(id _: String) async throws {}
        func deleteMutation(id _: String) async throws {}
        func deleteAllMutations() async throws {}
        func countPendingMutations() async throws -> Int {
            0
        }
    }

    private final class MockDownloadManager: DownloadManagerProtocol, @unchecked Sendable {
        func fetchDownloads() async throws -> [CDDownload] {
            []
        }

        func fetchPendingDownloads() async throws -> [CDDownload] {
            []
        }

        func fetchNextPendingDownload() async throws -> CDDownload? {
            nil
        }

        func fetchCompletedDownloads() async throws -> [CDDownload] {
            []
        }

        func fetchDownload(forTrackRatingKey _: String, sourceCompositeKey _: String?) async throws -> CDDownload? {
            nil
        }

        func fetchDownloadsBatch(forReferences _: [OfflineTrackReference]) async throws -> [String: CDDownload] {
            [:]
        }

        func fetchDownloads(forSourceCompositeKey _: String) async throws -> [CDDownload] {
            []
        }

        func createDownload(forTrackRatingKey _: String) async throws -> CDDownload {
            fatalError()
        }

        func createDownload(forTrackRatingKey _: String, sourceCompositeKey _: String?, quality _: String) async throws -> CDDownload {
            fatalError()
        }

        func batchCreateDownloads(references _: [OfflineTrackReference], quality _: String) async throws -> Int {
            0
        }

        func updateDownloadProgress(_: NSManagedObjectID, progress _: Float) async throws {}
        func updateDownloadStatus(_: NSManagedObjectID, status _: CDDownload.Status, quality _: String?) async throws {}
        func updateDownloads(withStatuses _: [CDDownload.Status], to _: CDDownload.Status) async throws {}
        func completeDownload(_: NSManagedObjectID, filePath _: String, fileSize _: Int64, quality _: String?) async throws {}
        func failDownload(_: NSManagedObjectID, error _: String) async throws {}
        func deleteDownload(forTrackRatingKey _: String) async throws {}
        func deleteDownload(forTrackRatingKey _: String, sourceCompositeKey _: String?) async throws {}
        func getLocalFilePath(forTrackRatingKey _: String) async throws -> String? {
            nil
        }

        func getLocalFilePath(forTrackRatingKey _: String, sourceCompositeKey _: String?) async throws -> String? {
            nil
        }

        func getTotalDownloadSize() async throws -> Int64 {
            0
        }

        func deleteDownloads(forSourceCompositeKey _: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private func makeViewModel(
        initialTrack: Track? = nil,
        configureLibraryRepository: ((MockLibraryRepository) -> Void)? = nil
    ) -> (
        viewModel: NowPlayingViewModel,
        playbackService: MockPlaybackService,
        libraryRepository: MockLibraryRepository,
        lyricsService: LyricsService
    ) {
        let libraryRepository = MockLibraryRepository()
        configureLibraryRepository?(libraryRepository)
        let playlistRepository = MockPlaylistRepository()
        let accountManager = AccountManager(keychain: TestKeychain())
        let playbackService = MockPlaybackService(initialTrack: initialTrack)
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

        let viewModel = NowPlayingViewModel(
            playbackService: playbackService,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            navigationCoordinator: NavigationCoordinator(),
            toastCenter: ToastCenter(),
            mutationCoordinator: mutationCoordinator,
            trackAvailabilityResolver: trackAvailabilityResolver,
            lyricsService: lyricsService
        )
        viewModel.isArtworkLoadingEnabledForTesting = false

        return (
            viewModel,
            playbackService,
            libraryRepository,
            lyricsService
        )
    }

    private func waitForProjectionPropagation() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 25_000_000)
        await Task.yield()
    }

    private func waitForCurrentTrackArtwork(
        _ viewModel: NowPlayingViewModel,
        expectedPath: String
    ) async {
        for _ in 0 ..< 20 {
            if viewModel.currentTrack?.thumbPath == expectedPath {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCurrentTrackMissingArtworkRefreshesFromLibraryCache() async {
        let viewModelTuple = makeViewModel()
        let sourceKey = "plex:account:server:1"
        let artworkPath = "/library/metadata/2/thumb/1779114439"
        viewModelTuple.libraryRepository.setFetchedTrack(
            id: "14",
            sourceCompositeKey: sourceKey,
            thumbPath: artworkPath
        )
        let restoredTrack = Track(
            id: "14",
            key: "/library/metadata/14",
            title: "2085",
            artistName: "AJR",
            albumName: "The Maybe Man",
            sourceCompositeKey: sourceKey
        )

        viewModelTuple.playbackService.setCurrentTrack(restoredTrack)
        await waitForCurrentTrackArtwork(viewModelTuple.viewModel, expectedPath: artworkPath)

        XCTAssertEqual(viewModelTuple.viewModel.currentTrack?.thumbPath, artworkPath)
        XCTAssertEqual(viewModelTuple.viewModel.artworkProjection.currentTrack?.thumbPath, artworkPath)
    }

    func testInitialCurrentTrackMissingArtworkRefreshesFromLibraryCache() async {
        let sourceKey = "plex:account:server:1"
        let artworkPath = "/library/metadata/2/thumb/1779114439"
        let restoredTrack = Track(
            id: "14",
            key: "/library/metadata/14",
            title: "2085",
            artistName: "AJR",
            albumName: "The Maybe Man",
            sourceCompositeKey: sourceKey
        )
        let viewModelTuple = makeViewModel(
            initialTrack: restoredTrack,
            configureLibraryRepository: { repository in
                repository.setFetchedTrack(
                    id: "14",
                    sourceCompositeKey: sourceKey,
                    thumbPath: artworkPath
                )
            }
        )

        await waitForCurrentTrackArtwork(viewModelTuple.viewModel, expectedPath: artworkPath)

        XCTAssertEqual(viewModelTuple.viewModel.currentTrack?.thumbPath, artworkPath)
        XCTAssertEqual(viewModelTuple.viewModel.artworkProjection.currentTrack?.thumbPath, artworkPath)
    }

    func testSetTrackFavoriteUsesLovedRating() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
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
        XCTAssertEqual(playback.appliedRatings.map(\.rating), [10])
    }

    func testSetTrackFavoriteUsesNilRatingWhenUnfavoriting() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
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
        XCTAssertEqual(playback.appliedRatings.map(\.rating), [0])
    }

    func testSetTrackFavoriteStopsWhenMutationFails() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
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
        XCTAssertEqual(playback.appliedRatings.map(\.rating), [10, 0])
    }

    func testPlayUsesOptimisticFavoriteRating() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", rating: 0)

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        await viewModel.setTrackFavorite(true, for: track)
        viewModel.play(track: track)
        await waitForProjectionPropagation()

        XCTAssertEqual(playback.lastPlayedTrack?.rating, 10)
    }

    func testPlayTracksPreservesStartIndexWhileApplyingOptimisticRatings() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let first = Track(id: "1", key: "/library/metadata/1", title: "First", rating: 0)
        let second = Track(id: "2", key: "/library/metadata/2", title: "Second", rating: 0)

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        await viewModel.setTrackFavorite(true, for: second)
        viewModel.play(tracks: [first, second], startingAt: 1)
        await waitForProjectionPropagation()

        XCTAssertEqual(playback.lastQueuedStartIndex, 1)
        XCTAssertEqual(playback.lastQueuedTracks.map(\.rating), [0, 10])
        XCTAssertEqual(playback.lastPlayedTrack?.id, "2")
    }

    func testFavoriteStateIsSourceScopedForDuplicateRatingKeys() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let subscriberTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            rating: 0,
            sourceCompositeKey: "plex:felicity:server:music"
        )
        let freeAccountTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            rating: 0,
            sourceCompositeKey: "plex:felicity-test:server:music"
        )
        var mutationRecords: [(trackIdentity: String, rating: Int?)] = []
        var storeRecords: [(trackIdentity: String, rating: Int)] = []

        viewModel.trackRatingMutationHandlerForTesting = { track, rating in
            mutationRecords.append((track.sourceScopedID, rating))
        }
        viewModel.trackRatingStoreHandlerForTesting = { track, rating in
            storeRecords.append((track.sourceScopedID, rating))
        }

        await viewModel.setTrackFavorite(true, for: freeAccountTrack)
        viewModel.play(tracks: [subscriberTrack, freeAccountTrack], startingAt: 0)
        await waitForProjectionPropagation()

        XCTAssertFalse(viewModel.isTrackFavorited(subscriberTrack))
        XCTAssertTrue(viewModel.isTrackFavorited(freeAccountTrack))
        XCTAssertEqual(mutationRecords.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(mutationRecords.map(\.rating), [10])
        XCTAssertEqual(storeRecords.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(playback.appliedRatings.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(playback.appliedRatings.map(\.rating), [10])
        XCTAssertEqual(playback.lastQueuedTracks.map(\.rating), [0, 10])
    }

    func testShufflePlayUsesOptimisticFavoriteRatings() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let first = Track(id: "1", key: "/library/metadata/1", title: "First", rating: 0)
        let second = Track(id: "2", key: "/library/metadata/2", title: "Second", rating: 0)

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        await viewModel.setTrackFavorite(true, for: second)
        viewModel.shufflePlay(tracks: [first, second])
        await waitForProjectionPropagation()

        XCTAssertEqual(playback.lastShufflePlayTracks.map(\.rating), [0, 10])
    }

    func testToggleRatingUpdatesFavoriteStateForCurrentTrack() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", rating: 10)

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        playback.setCurrentTrack(track)
        await waitForProjectionPropagation()
        viewModel.currentRating = .loved

        await viewModel.toggleRatingForTesting()

        XCTAssertFalse(viewModel.isTrackFavorited(track))
    }

    func testToggleRatingForCurrentTrackIsSourceScopedForDuplicateRatingKeys() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let subscriberTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            rating: 0,
            sourceCompositeKey: "plex:felicity:server:music"
        )
        let freeAccountTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            rating: 10,
            sourceCompositeKey: "plex:felicity-test:server:music"
        )
        var mutationRecords: [(trackIdentity: String, rating: Int?)] = []
        var storeRecords: [(trackIdentity: String, rating: Int)] = []

        viewModel.trackRatingMutationHandlerForTesting = { track, rating in
            mutationRecords.append((track.sourceScopedID, rating))
        }
        viewModel.trackRatingStoreHandlerForTesting = { track, rating in
            storeRecords.append((track.sourceScopedID, rating))
        }

        playback.setCurrentTrack(freeAccountTrack)
        await waitForProjectionPropagation()
        viewModel.currentRating = .loved

        await viewModel.toggleRatingForTesting()

        XCTAssertFalse(viewModel.isTrackFavorited(subscriberTrack))
        XCTAssertFalse(viewModel.isTrackFavorited(freeAccountTrack))
        XCTAssertEqual(mutationRecords.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(mutationRecords.map(\.rating), [2])
        XCTAssertEqual(storeRecords.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(playback.appliedRatings.map(\.trackIdentity), [freeAccountTrack.sourceScopedID])
        XCTAssertEqual(playback.appliedRatings.map(\.rating), [2])
    }

    func testLyricsUsePresentationTimeInsteadOfRawPlaybackTime() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let lyricsService = viewModelTuple.lyricsService
        let lyrics = ParsedLyrics(
            lines: [
                LyricsLine(timestamp: 10, text: "Line 1"),
                LyricsLine(timestamp: 19, text: "Line 2"),
            ],
            isTimed: true
        )

        playback.setDuration(100)
        playback.setPlaybackState(.playing)
        try? await Task.sleep(nanoseconds: 25_000_000)
        lyricsService.setLyricsStateForTesting(.available(lyrics))
        playback.setCurrentTime(20)
        playback.setPresentationTime(18.5)

        try? await Task.sleep(nanoseconds: 25_000_000)
        await waitForProjectionPropagation()

        XCTAssertEqual(viewModel.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(viewModel.currentLyricsLineIndex, 0)
    }

    func testProgressPinsAtCompleteWhenCurrentTimeReachesDuration() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 100)
        playback.setCurrentTrack(track)
        playback.setDuration(100)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(100)

        await waitForProjectionPropagation()

        // When currentTime == duration, progress pins at 1.0 and remaining shows -0:00
        XCTAssertEqual(viewModel.progress, 1.0, accuracy: 0.001)
        XCTAssertEqual(viewModel.scrubberDuration, 100, accuracy: 0.001)
    }

    func testScrubberDurationMatchesPlaybackDuration() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200)
        playback.setCurrentTrack(track)
        playback.setDuration(200)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(50)

        await waitForProjectionPropagation()

        // scrubberDuration should match the playback duration exactly
        XCTAssertEqual(viewModel.scrubberDuration, 200, accuracy: 0.001)
    }

    func testPlaybackProjectionTracksFocusedPlaybackState() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 120)
        var progressValues: [Double] = []

        let cancellable = viewModel.playbackProjection.progressPublisher
            .sink { progressValues.append($0) }

        playback.setCurrentTrack(track)
        playback.setDuration(120)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(30)

        await waitForProjectionPropagation()

        XCTAssertEqual(viewModel.playbackProjection.currentTrack, track)
        XCTAssertEqual(viewModel.playbackProjection.playbackState, .playing)
        XCTAssertTrue(viewModel.playbackProjection.isPlaying)
        XCTAssertEqual(viewModel.playbackProjection.duration, 120, accuracy: 0.001)
        XCTAssertEqual(viewModel.playbackProjection.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(progressValues.last ?? -1, 0.25, accuracy: 0.001)

        cancellable.cancel()
    }

    func testPlaybackProjectionTracksBufferedProgressWithoutTimeChange() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 120)
        var bufferedValues: [Double] = []

        let cancellable = viewModel.playbackProjection.bufferedProgressPublisher
            .sink { bufferedValues.append($0) }

        playback.setCurrentTrack(track)
        playback.setDuration(120)
        playback.setPlaybackState(.playing)
        playback.setCurrentTime(15)
        await waitForProjectionPropagation()

        playback.setBufferedProgress(0.6)
        await waitForProjectionPropagation()

        XCTAssertEqual(viewModel.playbackProjection.progress, 0.125, accuracy: 0.001)
        XCTAssertEqual(viewModel.playbackProjection.bufferedProgress, 0.6, accuracy: 0.001)
        XCTAssertEqual(bufferedValues.last ?? -1, 0.6, accuracy: 0.001)

        cancellable.cancel()
    }

    func testQueueProjectionTracksQueueAndHistory() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let first = Track(id: "1", key: "/library/metadata/1", title: "First")
        let second = Track(id: "2", key: "/library/metadata/2", title: "Second")
        let queue = [
            QueueItem(id: "queue-1", track: first),
            QueueItem(id: "queue-2", track: second),
        ]
        let history = [QueueItem(id: "history-1", track: first)]

        playback.setQueue(queue, currentIndex: 1)
        playback.setHistory(history)

        try? await Task.sleep(nanoseconds: 25_000_000)
        await waitForProjectionPropagation()

        XCTAssertEqual(viewModel.queueProjection.queue, queue)
        XCTAssertEqual(viewModel.queueProjection.currentQueueIndex, 1)
        XCTAssertEqual(viewModel.queueProjection.currentQueueItem?.id, "queue-2")
        XCTAssertEqual(viewModel.queueProjection.playbackHistory, history)
    }

    func testQueueProjectionTracksSmartMixControlState() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService

        XCTAssertFalse(viewModel.isSmartMixEnabled)
        XCTAssertFalse(viewModel.queueProjection.isSmartMixEnabled)

        playback.setSmartMixEnabled(true)
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.isSmartMixEnabled)
        XCTAssertTrue(viewModel.queueProjection.isSmartMixEnabled)

        viewModel.toggleSmartMix()
        await waitForProjectionPropagation()

        XCTAssertFalse(viewModel.isSmartMixEnabled)
        XCTAssertFalse(viewModel.queueProjection.isSmartMixEnabled)
    }

    func testRatingProjectionTracksOptimisticFavoriteState() async {
        let viewModel = makeViewModel().viewModel
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test")

        viewModel.trackRatingMutationHandlerForTesting = { _, _ in }
        viewModel.trackRatingStoreHandlerForTesting = { _, _ in }

        XCTAssertFalse(viewModel.ratingProjection.isTrackFavorited(track))
        XCTAssertEqual(viewModel.ratingProjection.displayRatingsRevision, 0)

        await viewModel.setTrackFavorite(true, for: track)
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.ratingProjection.isTrackFavorited(track))
        XCTAssertEqual(viewModel.ratingProjection.displayRatingsRevision, 1)
    }

    func testLyricsProjectionTracksCurrentLine() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let lyricsService = viewModelTuple.lyricsService
        let lyrics = ParsedLyrics(
            lines: [
                LyricsLine(timestamp: 10, text: "Line 1"),
                LyricsLine(timestamp: 20, text: "Line 2"),
            ],
            isTimed: true
        )

        playback.setDuration(100)
        try? await Task.sleep(nanoseconds: 25_000_000)
        lyricsService.setLyricsStateForTesting(.available(lyrics))
        playback.setPresentationTime(10.1)

        try? await Task.sleep(nanoseconds: 25_000_000)
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.lyricsProjection.lyricsState.isAvailable)
        XCTAssertEqual(viewModel.lyricsProjection.currentLyricsLineIndex, 0)
        XCTAssertEqual(viewModel.lyricsProjection.lyricsScrollTargetIndex, 0)
    }

    func testChordModeFallsBackAndResumesWhileQueueStateStaysEnabled() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let lyricsService = viewModelTuple.lyricsService
        playback.setCurrentTrack(Track(id: "1", key: "/library/metadata/1", title: "Chord Test"))
        await waitForProjectionPropagation()

        let normalLyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: 0, text: "Normal lyric"),
        ], isTimed: true)
        let chordLyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: 0, text: "Chord lyric", chords: [
                ParsedChord(symbol: "C", column: 10, offsetFromLyricStart: 0),
            ]),
        ], isTimed: true)

        lyricsService.setLyricsBundleForTesting(
            normal: .available(normalLyrics),
            chords: .available(chordLyrics)
        )
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.hasChordLyrics)
        XCTAssertFalse(viewModel.isChordModeEnabled)
        XCTAssertFalse(viewModel.isDisplayingChordLyrics)
        XCTAssertEqual(viewModel.lyricsState, .available(normalLyrics))

        viewModel.toggleChordMode()
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.isChordModeEnabled)
        XCTAssertTrue(viewModel.isDisplayingChordLyrics)
        XCTAssertEqual(viewModel.lyricsState, .available(chordLyrics))

        lyricsService.setLyricsBundleForTesting(
            normal: .available(normalLyrics),
            chords: .notAvailable,
            chordModeEnabled: true
        )
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.isChordModeEnabled)
        XCTAssertFalse(viewModel.isDisplayingChordLyrics)
        XCTAssertEqual(viewModel.lyricsState, .available(normalLyrics))

        lyricsService.setLyricsBundleForTesting(
            normal: .available(normalLyrics),
            chords: .available(chordLyrics),
            chordModeEnabled: true
        )
        await waitForProjectionPropagation()

        XCTAssertTrue(viewModel.isChordModeEnabled)
        XCTAssertTrue(viewModel.isDisplayingChordLyrics)
        XCTAssertEqual(viewModel.lyricsState, .available(chordLyrics))
    }

    func testChordModeResetsWhenQueueIdentitySequenceChanges() async {
        let viewModelTuple = makeViewModel()
        let viewModel = viewModelTuple.viewModel
        let playback = viewModelTuple.playbackService
        let lyricsService = viewModelTuple.lyricsService
        let first = Track(id: "1", key: "/library/metadata/1", title: "First")
        let second = Track(id: "2", key: "/library/metadata/2", title: "Second")
        let chordLyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: 0, text: "Chord lyric", chords: [
                ParsedChord(symbol: "C", column: 10, offsetFromLyricStart: 0),
            ]),
        ], isTimed: true)

        playback.setQueue([
            QueueItem(id: "queue-1", track: first),
            QueueItem(id: "queue-2", track: second),
        ], currentIndex: 0)
        lyricsService.setLyricsBundleForTesting(
            normal: .notAvailable,
            chords: .available(chordLyrics)
        )
        await waitForProjectionPropagation()

        viewModel.toggleChordMode()
        await waitForProjectionPropagation()
        XCTAssertTrue(viewModel.isChordModeEnabled)

        playback.setQueue([
            QueueItem(id: "queue-1", track: first),
            QueueItem(id: "queue-2", track: second),
        ], currentIndex: 1)
        await waitForProjectionPropagation()
        XCTAssertTrue(viewModel.isChordModeEnabled)

        playback.setQueue([
            QueueItem(id: "queue-3", track: first),
            QueueItem(id: "queue-4", track: second),
        ], currentIndex: 0)
        await waitForProjectionPropagation()

        XCTAssertFalse(viewModel.isChordModeEnabled)
        XCTAssertFalse(viewModel.isDisplayingChordLyrics)
    }
}
