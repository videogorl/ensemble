import Combine
import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SiriPlaybackCoordinatorTests: XCTestCase {
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

    private final class RecordingPlaybackService: PlaybackServiceProtocol {
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

        private(set) var lastPlayedTrack: Track?
        private(set) var lastQueuedTracks: [Track] = []
        private(set) var lastQueuedStartIndex: Int?

        var currentTrack: Track? { currentTrackSubject.value }
        var playbackState: PlaybackState { playbackStateSubject.value }
        var currentTime: TimeInterval { currentTimeSubject.value }
        var duration: TimeInterval { currentTrack?.duration ?? 0 }
        var queue: [QueueItem] { queueSubject.value }
        var currentQueueIndex: Int { queueIndexSubject.value }
        var isShuffleEnabled: Bool { shuffleSubject.value }
        var repeatMode: RepeatMode { repeatModeSubject.value }
        var waveformHeights: [Double] { waveformSubject.value }
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
        var bufferedProgressValue: Double { 0 }
        var queuePublisher: AnyPublisher<[QueueItem], Never> { queueSubject.eraseToAnyPublisher() }
        var currentQueueIndexPublisher: AnyPublisher<Int, Never> { queueIndexSubject.eraseToAnyPublisher() }
        var shufflePublisher: AnyPublisher<Bool, Never> { shuffleSubject.eraseToAnyPublisher() }
        var repeatModePublisher: AnyPublisher<RepeatMode, Never> { repeatModeSubject.eraseToAnyPublisher() }
        var waveformPublisher: AnyPublisher<[Double], Never> { waveformSubject.eraseToAnyPublisher() }
        var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { autoplayEnabledSubject.eraseToAnyPublisher() }
        var autoplayTracksPublisher: AnyPublisher<[Track], Never> { autoplayTracksSubject.eraseToAnyPublisher() }
        var autoplayActivePublisher: AnyPublisher<Bool, Never> { autoplayActiveSubject.eraseToAnyPublisher() }
        var radioModePublisher: AnyPublisher<RadioMode, Never> { radioModeSubject.eraseToAnyPublisher() }
        var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { recommendationsSubject.eraseToAnyPublisher() }
        var historyPublisher: AnyPublisher<[QueueItem], Never> { historySubject.eraseToAnyPublisher() }

        func play(track: Track) async {
            lastPlayedTrack = track
            lastQueuedTracks = [track]
            lastQueuedStartIndex = 0
            currentTrackSubject.send(track)
        }

        func play(tracks: [Track], startingAt index: Int) async {
            lastPlayedTrack = tracks.indices.contains(index) ? tracks[index] : nil
            lastQueuedTracks = tracks
            lastQueuedStartIndex = index
            currentTrackSubject.send(lastPlayedTrack)
        }

        func shufflePlay(tracks: [Track]) async {}
        func playQueueIndex(_ index: Int) async {}
        func pause() {}
        func resume() {}
        func stop() {}
        func retryCurrentTrack() async {}
        func next() {}
        func previous() {}
        func seek(to time: TimeInterval) {}
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

        _ = try await libraryRepository.upsertArtist(
            ratingKey: "artist-1",
            key: "/library/metadata/artist-1",
            name: "Artist One",
            summary: nil,
            thumbPath: nil,
            artPath: nil,
            dateAdded: nil,
            dateModified: nil,
            sourceCompositeKey: librarySourceKey
        )

        _ = try await libraryRepository.upsertAlbum(
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
            rating: nil,
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
