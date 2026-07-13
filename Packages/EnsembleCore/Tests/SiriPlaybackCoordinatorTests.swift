import Combine
import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SiriPlaybackCoordinatorTests: XCTestCase {

    private final class RecordingPlaybackService: PlaybackServiceProtocol {
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
        private let smartMixDisabledForAlbumsSubject = CurrentValueSubject<Bool, Never>(true)
        private let smartMixTransitionActiveSubject = CurrentValueSubject<Bool, Never>(false)
        private let autoplayTracksSubject = CurrentValueSubject<[Track], Never>([])
        private let autoplayActiveSubject = CurrentValueSubject<Bool, Never>(false)
        private let radioModeSubject = CurrentValueSubject<RadioMode, Never>(.off)
        private let recommendationsSubject = CurrentValueSubject<Bool, Never>(false)
        private let historySubject = CurrentValueSubject<[QueueItem], Never>([])

        private(set) var lastPlayedTrack: Track?
        private(set) var lastQueuedTracks: [Track] = []
        private(set) var lastQueuedStartIndex: Int?
        private(set) var lastShufflePlayRequested = false

        var currentTrack: Track? { currentTrackSubject.value }
        var playbackState: PlaybackState { playbackStateSubject.value }
        var currentTime: TimeInterval { currentTimeSubject.value }
        var presentationTime: TimeInterval { presentationTimeSubject.value }
        var duration: TimeInterval { currentTrack?.duration ?? 0 }
        var queue: [QueueItem] { queueSubject.value }
        var currentQueueIndex: Int { queueIndexSubject.value }
        var isShuffleEnabled: Bool { shuffleSubject.value }
        var repeatMode: RepeatMode { repeatModeSubject.value }
        var waveformHeights: [Double] { waveformSubject.value }
        var frequencyBands: [Double] { [] }
        var isExternalPlaybackActive: Bool { false }
        var isAutoplayEnabled: Bool { autoplayEnabledSubject.value }
        var isSmartMixEnabled: Bool { smartMixEnabledSubject.value }
        var isSmartMixDisabledForAlbums: Bool { smartMixDisabledForAlbumsSubject.value }
        var isSmartMixTransitionActive: Bool { smartMixTransitionActiveSubject.value }
        var autoplayTracks: [Track] { autoplayTracksSubject.value }
        var isAutoplayActive: Bool { autoplayActiveSubject.value }
        var radioMode: RadioMode { radioModeSubject.value }
        var recommendationsExhausted: Bool { recommendationsSubject.value }
        var queueSections: QueueSections { .empty }
        var playbackHistory: [QueueItem] { historySubject.value }
        var isScreenMirroringActive: Bool = false

        var currentTrackPublisher: AnyPublisher<Track?, Never> { currentTrackSubject.eraseToAnyPublisher() }
        var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { playbackStateSubject.eraseToAnyPublisher() }
        var currentTimePublisher: AnyPublisher<TimeInterval, Never> { currentTimeSubject.eraseToAnyPublisher() }
        var currentTimeValue: TimeInterval { currentTimeSubject.value }
        var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { presentationTimeSubject.eraseToAnyPublisher() }
        var presentationTimeValue: TimeInterval { presentationTimeSubject.value }
        var bufferedProgressValue: Double { bufferedProgressSubject.value }
        var bufferedProgressPublisher: AnyPublisher<Double, Never> { bufferedProgressSubject.eraseToAnyPublisher() }
        var queuePublisher: AnyPublisher<[QueueItem], Never> { queueSubject.eraseToAnyPublisher() }
        var currentQueueIndexPublisher: AnyPublisher<Int, Never> { queueIndexSubject.eraseToAnyPublisher() }
        var shufflePublisher: AnyPublisher<Bool, Never> { shuffleSubject.eraseToAnyPublisher() }
        var repeatModePublisher: AnyPublisher<RepeatMode, Never> { repeatModeSubject.eraseToAnyPublisher() }
        var waveformPublisher: AnyPublisher<[Double], Never> { waveformSubject.eraseToAnyPublisher() }
        var frequencyBandsPublisher: AnyPublisher<[Double], Never> { Just([]).eraseToAnyPublisher() }
        var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { autoplayEnabledSubject.eraseToAnyPublisher() }
        var smartMixEnabledPublisher: AnyPublisher<Bool, Never> { smartMixEnabledSubject.eraseToAnyPublisher() }
        var smartMixDisabledForAlbumsPublisher: AnyPublisher<Bool, Never> { smartMixDisabledForAlbumsSubject.eraseToAnyPublisher() }
        var smartMixTransitionActivePublisher: AnyPublisher<Bool, Never> { smartMixTransitionActiveSubject.eraseToAnyPublisher() }
        var autoplayTracksPublisher: AnyPublisher<[Track], Never> { autoplayTracksSubject.eraseToAnyPublisher() }
        var autoplayActivePublisher: AnyPublisher<Bool, Never> { autoplayActiveSubject.eraseToAnyPublisher() }
        var radioModePublisher: AnyPublisher<RadioMode, Never> { radioModeSubject.eraseToAnyPublisher() }
        var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { recommendationsSubject.eraseToAnyPublisher() }
        var historyPublisher: AnyPublisher<[QueueItem], Never> { historySubject.eraseToAnyPublisher() }

        var isInstrumentalModeActive: Bool { false }
        var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        func setInstrumentalMode(_ enabled: Bool) {}

        func play(track: Track, context: PlaybackStartContext) async {
            lastPlayedTrack = track
            lastQueuedTracks = [track]
            lastQueuedStartIndex = 0
            currentTrackSubject.send(track)
        }

        func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async {
            lastPlayedTrack = tracks.indices.contains(index) ? tracks[index] : nil
            lastQueuedTracks = tracks
            lastQueuedStartIndex = index
            currentTrackSubject.send(lastPlayedTrack)
        }

        func shufflePlay(tracks: [Track], context: PlaybackStartContext) async {
            lastShufflePlayRequested = true
            lastQueuedTracks = tracks
            lastQueuedStartIndex = 0
            lastPlayedTrack = tracks.first
            currentTrackSubject.send(lastPlayedTrack)
        }
        func playQueueIndex(_ index: Int) async {}
        func pause() {}
        func resume() {}
        func stop() {}
        func retryCurrentTrack() async {}
        func next() {}
        func previous() {}
        func seek(to time: TimeInterval) {}
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
        func toggleShuffle() {}
        func cycleRepeatMode() {}
        func toggleAutoplay() {}
        func toggleSmartMix() {}
        func setSmartMixEnabled(_ enabled: Bool) { smartMixEnabledSubject.send(enabled) }
        func setSmartMixDisabledForAlbums(_ disabled: Bool) { smartMixDisabledForAlbumsSubject.send(disabled) }
        func refreshAutoplayQueue() async {}
        func enableRadio(tracks: [Track]) async {}
        func isTrackAutoGenerated(trackId: String) -> Bool { false }
        func playFromHistory(at historyIndex: Int) async {}
        func applyRatingLocally(track: Track, rating: Int) async {}
        func updateVisualizerPosition(_ time: TimeInterval) {}
        func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool) {}
        func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) { (nil, nil) }
    }

    private struct Fixture {
        let coordinator: SiriPlaybackCoordinator
        let playbackService: RecordingPlaybackService
        let librarySourceKey: String
        let serverSourceKey: String
    }

    func testExecutePlayTrackPlaysRequestedTrack() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayTrack(
            request: SiriPlaybackRequest(
                entityID: "track-1",
                sourceCompositeKey: fixture.librarySourceKey,
                displayName: "Track One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, "track-1")
        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1"])
    }

    func testExecutePlayAlbumQueuesAlbumTracksFromFirstTrack() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayAlbum(
            request: SiriPlaybackRequest(
                entityID: "album-1",
                sourceCompositeKey: fixture.librarySourceKey,
                displayName: "Album One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayAlbumFallsBackToFuzzyDisplayNameMatch() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayAlbum(
            request: SiriPlaybackRequest(
                entityID: "unknown-album-id",
                sourceCompositeKey: fixture.librarySourceKey,
                displayName: "Albom One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayArtistQueuesArtistTracks() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayArtist(
            request: SiriPlaybackRequest(
                entityID: "artist-1",
                sourceCompositeKey: fixture.librarySourceKey,
                displayName: "Artist One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayArtistFallsBackToDisplayNameWhenEntityIDMissing() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayArtist(
            request: SiriPlaybackRequest(
                entityID: "unknown-artist-id",
                sourceCompositeKey: fixture.librarySourceKey,
                displayName: "Artist One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayPlaylistUsesSavedPlaylistOrder() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayPlaylist(
            request: SiriPlaybackRequest(
                entityID: "playlist-1",
                sourceCompositeKey: fixture.serverSourceKey,
                displayName: "Playlist One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-2", "track-1"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
        XCTAssertFalse(fixture.playbackService.lastShufflePlayRequested)
    }

    func testExecutePlayPlaylistHonorsShuffleRequest() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayPlaylist(
            request: SiriPlaybackRequest(
                entityID: "playlist-1",
                sourceCompositeKey: fixture.serverSourceKey,
                displayName: "Playlist One",
                shuffle: true
            )
        )

        XCTAssertTrue(fixture.playbackService.lastShufflePlayRequested)
        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-2", "track-1"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayPlaylistFallsBackToDisplayNameWhenEntityIDMissing() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayPlaylist(
            request: SiriPlaybackRequest(
                entityID: "unknown-playlist-id",
                sourceCompositeKey: fixture.serverSourceKey,
                displayName: "Playlist One"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-2", "track-1"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    func testExecutePlayPlaylistStripsAppNameSuffixFromDisplayName() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayPlaylist(
            request: SiriPlaybackRequest(
                entityID: "unknown-playlist-id",
                sourceCompositeKey: fixture.serverSourceKey,
                displayName: "Playlist One on Ensemble"
            )
        )

        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-2", "track-1"])
        XCTAssertEqual(fixture.playbackService.lastQueuedStartIndex, 0)
    }

    private func makeFixture() async throws -> Fixture {
        let accountID = "account-1"
        let serverID = "server-1"
        let libraryID = "library-1"
        let librarySourceKey = "plex:\(accountID):\(serverID):\(libraryID)"
        let serverSourceKey = "plex:\(accountID):\(serverID)"

        let coreDataStack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: coreDataStack)
        let playlistRepository = PlaylistRepository(coreDataStack: coreDataStack)

        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: librarySourceKey,
            type: "plex",
            accountId: accountID,
            serverId: serverID,
            libraryId: libraryID,
            displayName: "Music",
            accountName: "Test Account"
        )

        try await libraryRepository.batchUpsertArtists(
            [
                ArtistUpsertInput(
                    ratingKey: "artist-1",
                    key: "/library/metadata/artist-1",
                    name: "Artist One",
                    summary: nil,
                    thumbPath: nil,
                    artPath: nil,
                    dateAdded: nil,
                    dateModified: nil
                )
            ],
            sourceCompositeKey: librarySourceKey
        )

        try await libraryRepository.batchUpsertAlbums(
            [
                AlbumUpsertInput(
                    ratingKey: "album-1",
                    key: "/library/metadata/album-1",
                    title: "Album One",
                    artistName: "Artist One",
                    albumArtist: "Artist One",
                    artistRatingKey: "artist-1",
                    summary: nil,
                    thumbPath: nil,
                    artPath: nil,
                    year: 2024,
                    trackCount: 2,
                    dateAdded: nil,
                    dateModified: nil,
                    rating: nil
                )
            ],
            sourceCompositeKey: librarySourceKey
        )

        _ = try await libraryRepository.upsertTrack(
            ratingKey: "track-1",
            key: "/library/metadata/track-1",
            title: "Track One",
            artistName: "Artist One",
            albumName: "Album One",
            albumRatingKey: "album-1",
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-1.mp3",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: 0,
            sourceCompositeKey: librarySourceKey
        )

        _ = try await libraryRepository.upsertTrack(
            ratingKey: "track-2",
            key: "/library/metadata/track-2",
            title: "Track Two",
            artistName: "Artist One",
            albumName: "Album One",
            albumRatingKey: "album-1",
            trackNumber: 2,
            discNumber: 1,
            duration: 200_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-2.mp3",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: 0,
            sourceCompositeKey: librarySourceKey
        )

        _ = try await playlistRepository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: 0,
            trackCount: 2,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: serverSourceKey
        )

        try await playlistRepository.setPlaylistTracks(
            ["track-2", "track-1"],
            forPlaylist: "playlist-1",
            sourceCompositeKey: serverSourceKey
        )

        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: accountID,
                email: "test@example.com",
                authToken: "token",
                servers: [
                    PlexServerConfig(
                        id: serverID,
                        name: "Server",
                        url: "https://example.com",
                        token: "token",
                        libraries: [
                            PlexLibraryConfig(
                                id: libraryID,
                                key: libraryID,
                                title: "Music",
                                isEnabled: true
                            )
                        ]
                    )
                ]
            )
        )

        let playbackService = RecordingPlaybackService()
        let coordinator = SiriPlaybackCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            playbackService: playbackService
        )

        return Fixture(
            coordinator: coordinator,
            playbackService: playbackService,
            librarySourceKey: librarySourceKey,
            serverSourceKey: serverSourceKey
        )
    }
}
