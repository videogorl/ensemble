import Combine
import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared

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
        var radioMode: RadioMode { radioModeSubject.value }
        var recommendationsExhausted: Bool { recommendationsSubject.value }
        var playbackHistory: [QueueItem] { historySubject.value }
        var snapshot: PlaybackSnapshot {
            PlaybackSnapshot(
                currentTrack: currentTrack,
                playbackState: playbackState,
                queue: queue,
                currentQueueIndex: currentQueueIndex,
                history: playbackHistory,
                isShuffleEnabled: isShuffleEnabled,
                repeatMode: repeatMode,
                isAutoplayEnabled: isAutoplayEnabled,
                autoplayTracks: autoplayTracks,
                radioMode: radioMode,
                recommendationsExhausted: recommendationsExhausted,
                isSmartMixEnabled: isSmartMixEnabled,
                isSmartMixDisabledForAlbums: isSmartMixDisabledForAlbums,
                isSmartMixTransitionActive: isSmartMixTransitionActive,
                isInstrumentalModeActive: isInstrumentalModeActive,
                isExternalPlaybackActive: isExternalPlaybackActive
            )
        }

        func snapshots() -> AsyncStream<PlaybackSnapshot> {
            AsyncStream { continuation in
                let subscription = snapshotPublisher.sink { continuation.yield($0) }
                continuation.onTermination = { _ in subscription.cancel() }
            }
        }

        /// Re-emits the snapshot whenever any field subject changes.
        private var snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never> {
            let changes: [AnyPublisher<Void, Never>] = [
                currentTrackSubject.map { _ in () }.eraseToAnyPublisher(),
                playbackStateSubject.map { _ in () }.eraseToAnyPublisher(),
                queueSubject.map { _ in () }.eraseToAnyPublisher(),
                queueIndexSubject.map { _ in () }.eraseToAnyPublisher(),
                historySubject.map { _ in () }.eraseToAnyPublisher(),
                shuffleSubject.map { _ in () }.eraseToAnyPublisher(),
                repeatModeSubject.map { _ in () }.eraseToAnyPublisher(),
                autoplayEnabledSubject.map { _ in () }.eraseToAnyPublisher(),
                autoplayTracksSubject.map { _ in () }.eraseToAnyPublisher(),
                radioModeSubject.map { _ in () }.eraseToAnyPublisher(),
                recommendationsSubject.map { _ in () }.eraseToAnyPublisher(),
                smartMixEnabledSubject.map { _ in () }.eraseToAnyPublisher(),
                smartMixDisabledForAlbumsSubject.map { _ in () }.eraseToAnyPublisher(),
                smartMixTransitionActiveSubject.map { _ in () }.eraseToAnyPublisher()
            ]
            return Publishers.MergeMany(changes)
                .map { [unowned self] in self.snapshot }
                .eraseToAnyPublisher()
        }

        var isScreenMirroringActive: Bool = false

        var currentTimePublisher: AnyPublisher<TimeInterval, Never> { currentTimeSubject.eraseToAnyPublisher() }
        var currentTimeValue: TimeInterval { currentTimeSubject.value }
        var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { presentationTimeSubject.eraseToAnyPublisher() }
        var presentationTimeValue: TimeInterval { presentationTimeSubject.value }
        var bufferedProgressValue: Double { bufferedProgressSubject.value }
        var bufferedProgressPublisher: AnyPublisher<Double, Never> { bufferedProgressSubject.eraseToAnyPublisher() }
        var waveformPublisher: AnyPublisher<[Double], Never> { waveformSubject.eraseToAnyPublisher() }
        var frequencyBandsPublisher: AnyPublisher<[Double], Never> { Just([]).eraseToAnyPublisher() }

        var isInstrumentalModeActive: Bool { false }
        func setInstrumentalMode(_ enabled: Bool) {}

        /// When set, a start leaves the service in `.failed`, as `PlaybackService` does offline.
        var failStartMessage: String?

        func play(track: Track, context: PlaybackStartContext) async {
            if let failStartMessage { playbackStateSubject.send(.failed(failStartMessage)); return }
            lastPlayedTrack = track
            lastQueuedTracks = [track]
            lastQueuedStartIndex = 0
            currentTrackSubject.send(track)
        }

        func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async {
            if let failStartMessage { playbackStateSubject.send(.failed(failStartMessage)); return }
            lastPlayedTrack = tracks.indices.contains(index) ? tracks[index] : nil
            lastQueuedTracks = tracks
            lastQueuedStartIndex = index
            currentTrackSubject.send(lastPlayedTrack)
        }

        func shufflePlay(tracks: [Track], context: PlaybackStartContext) async {
            if let failStartMessage { playbackStateSubject.send(.failed(failStartMessage)); return }
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
        func addToQueue(_ track: Track) {}
        func addToQueue(_ tracks: [Track]) {}
        private(set) var insertedNext: [Track] = []
        private(set) var insertedLast: [Track] = []

        func playNext(_ track: Track) { insertedNext += [track] }
        func playNext(_ tracks: [Track]) { insertedNext += tracks }
        func playLast(_ track: Track) { insertedLast += [track] }
        func playLast(_ tracks: [Track]) { insertedLast += tracks }
        func removeFromQueue(at index: Int) {}
        func clearQueue() {}
        func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int, destinationSource: QueueItemSource?) {}
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
        func currentPlaybackFileInfo() -> PlaybackFileInfo? { nil }
    }

    private struct Fixture {
        let coordinator: SiriPlaybackCoordinator
        let playbackService: RecordingPlaybackService
        let librarySourceKey: String
        let serverSourceKey: String
        let libraryRepository: LibraryRepository
        let otherLibrarySourceKey: String
        let playlistRepository: PlaylistRepository
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

    func testEnqueueAddsResolvedTracksNextOrLastWithoutReplacingTheQueue() async throws {
        let fixture = try await makeFixture()
        let album = SiriPlaybackRequest(
            entityID: "album-1",
            sourceCompositeKey: fixture.librarySourceKey,
            displayName: "Album One"
        )

        let nextCount = try await fixture.coordinator.enqueue(kind: .album, request: album, playNext: true)
        let lastCount = try await fixture.coordinator.enqueue(kind: .album, request: album, playNext: false)

        XCTAssertGreaterThan(nextCount, 0)
        XCTAssertEqual(nextCount, lastCount)
        XCTAssertEqual(fixture.playbackService.insertedNext.count, nextCount)
        XCTAssertEqual(fixture.playbackService.insertedLast.map(\.id), fixture.playbackService.insertedNext.map(\.id))
        XCTAssertTrue(fixture.playbackService.lastQueuedTracks.isEmpty)
    }

    func testAStartThatLeavesPlaybackFailedThrowsInsteadOfSucceeding() async throws {
        let fixture = try await makeFixture()
        fixture.playbackService.failStartMessage = "Offline"
        let album = SiriPlaybackRequest(
            entityID: "album-1",
            sourceCompositeKey: fixture.librarySourceKey,
            displayName: "Album One"
        )

        do {
            try await fixture.coordinator.executePlayAlbum(request: album)
            XCTFail("A failed start must not report success")
        } catch {
            XCTAssertEqual(error as? SiriPlaybackCoordinatorError, .playbackFailed("Offline"))
        }
        do {
            try await fixture.coordinator.playLibrary(shuffle: true)
            XCTFail("A failed start must not report success")
        } catch {
            XCTAssertEqual(error as? SiriPlaybackCoordinatorError, .playbackFailed("Offline"))
        }
    }

    func testPlayLibraryQueuesTracksOfEnabledSourcesOnly() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.playLibrary(shuffle: false)

        XCTAssertFalse(fixture.playbackService.lastQueuedTracks.isEmpty)
        XCTAssertTrue(fixture.playbackService.lastQueuedTracks.allSatisfy { $0.sourceCompositeKey?.hasPrefix("plex:account-1:server-") == true })
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

    /// Siri hears "&" as "and"; a never-played track with punctuation in its title must still be found by name.
    func testTrackNameMatchesAcrossAmpersandAndAnd() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayTrack(
            request: SiriPlaybackRequest(entityID: "kim and jessie", sourceCompositeKey: nil, displayName: "kim and jessie")
        )

        XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, "track-amp")
    }

    /// A same-named playlist on another server plays as part of one only when the playlist screen would show them as one.
    func testSameNamedPlaylistsPlayTogetherOnlyWhenTheScreenMergesThem() async throws {
        let hidden = HiddenMediaStore(defaults: UserDefaults(suiteName: "siri-merge-\(UUID().uuidString)")!)
        hidden.setHidden(true, identity: .init(kind: .playlist, itemID: "focus-b", sourceCompositeKey: "plex:account-1:server-2"))

        let hiddenNamed = HiddenMediaStore(defaults: UserDefaults(suiteName: "siri-merge-\(UUID().uuidString)")!)
        hiddenNamed.setHidden(true, identity: .init(kind: .playlist, itemID: "focus-a", sourceCompositeKey: "plex:account-1:server-1"))

        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        let cases: [(name: String, preferences: EnsembleMergingPreferences, hidden: HiddenMediaStore?, expected: [String])] = [
            ("merged, whitespace variant, smart one apart", .default, nil, ["track-1", "other-1"]),
            ("merge setting off: a shortcut saved against the merged row quietly plays that row's own copy", off, nil, ["track-1"]),
            ("hidden sibling", .default, hidden, ["track-1"]),
            ("named copy hidden: plays what the screen shows for the group", .default, hiddenNamed, ["other-1"])
        ]
        for testCase in cases {
            let fixture = try await makeFixture(mergingPreferences: testCase.preferences, hiddenMediaStore: testCase.hidden)
            try await fixture.coordinator.executePlayPlaylist(request: SiriPlaybackRequest(
                entityID: "focus-a", sourceCompositeKey: fixture.serverSourceKey, displayName: "Focus Mix"
            ))
            XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id).sorted(), testCase.expected.sorted(), testCase.name)
        }
    }

    /// A name-only Voice Add the extension deferred resolves by the shared rules: one regular destination, or nothing.
    /// The fixture's "Focus Mix" also exists as a smart playlist, so the plain name is not writable.
    func testNameOnlyVoiceAddResolvesOneEditableDestinationOrNone() async throws {
        let fixture = try await makeFixture()
        let cases: [(spoken: String, expectedID: String?)] = [
            ("Focus Mix", nil),            // a smart playlist shares the title: ambiguous, never written
            ("Focus Mix (Music)", nil),    // not an offered name
            ("Playlist One", "playlist-1"),
            ("playlist  one", "playlist-1"),
            ("Quarterly Polka", nil)
        ]
        try await assertVoiceAdd(cases, fixture: fixture)
    }

    /// With merging off, a label the extension offered for one server's "Focus Mix" resolves to that playlist and
    /// never to a playlist literally titled like another label: the app builds the same server names the index holds.
    func testDeferredServerLabelsResolveExactlyOneDestination() async throws {
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        let fixture = try await makeFixture(mergingPreferences: off)
        _ = try await fixture.playlistRepository.upsertPlaylist(
            ratingKey: "focus-literal", key: "/playlists/focus-literal", title: "Focus Mix (Server)", summary: nil,
            compositePath: nil, isSmart: false, duration: 0, trackCount: 0, dateAdded: nil, dateModified: nil,
            lastPlayed: nil, sourceCompositeKey: fixture.serverSourceKey
        )
        try await assertVoiceAdd([
            ("Focus Mix (Server)", "focus-literal"),
            ("Focus Mix (Server) 2", "focus-a"),
            ("Focus Mix (Server Two)", "focus-b"),
            ("Focus Mix", nil)
        ], fixture: fixture)
    }

    private func assertVoiceAdd(_ cases: [(spoken: String, expectedID: String?)], fixture: Fixture) async throws {
        for testCase in cases {
            let resolved = try await fixture.coordinator.visiblePlaylist(named: testCase.spoken)
            XCTAssertEqual(resolved?.ratingKey, testCase.expectedID, testCase.spoken)
        }
    }

    /// When every copy is hidden, nothing plays: a hidden original is never the fallback.
    func testPlaylistWithOnlyHiddenCopiesIsNotFoundWhetherMergingOrNot() async throws {
        let hidden = HiddenMediaStore(defaults: UserDefaults(suiteName: "siri-merge-\(UUID().uuidString)")!)
        for (key, server) in [("focus-a", "plex:account-1:server-1"), ("focus-b", "plex:account-1:server-2")] {
            hidden.setHidden(true, identity: .init(kind: .playlist, itemID: key, sourceCompositeKey: server))
        }
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        for preferences in [EnsembleMergingPreferences.default, off] {
            let fixture = try await makeFixture(mergingPreferences: preferences, hiddenMediaStore: hidden)
            do {
                try await fixture.coordinator.executePlayPlaylist(request: SiriPlaybackRequest(
                    entityID: "focus-a", sourceCompositeKey: fixture.serverSourceKey, displayName: "Focus Mix"
                ))
                XCTFail("a hidden playlist must not play")
            } catch SiriPlaybackCoordinatorError.mediaNotFound {}
        }
    }

    /// A playlist resolved by name (the entity id is not a stored key), shuffled or not, plays the merged set when
    /// merging is on and one copy when off.
    func testPlaylistRequestedByNamePlaysMergedSetOnlyWhenMerging() async throws {
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        for (preferences, expected) in [(EnsembleMergingPreferences.default, ["track-1", "other-1"]), (off, ["track-1"])] {
            for shuffle in [false, true] {
                let fixture = try await makeFixture(mergingPreferences: preferences)
                try await fixture.coordinator.executePlayPlaylist(
                    request: SiriPlaybackRequest(
                        entityID: "Focus Mix", sourceCompositeKey: fixture.serverSourceKey, displayName: "Focus Mix", shuffle: shuffle
                    )
                )
                XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id).sorted(), expected.sorted(),
                               "merging \(preferences.mergePlaylists), shuffle \(shuffle)")
            }
        }
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

    func testSourceLessRequestsResolveByNameWithinEnabledSources() async throws {
        let fixture = try await makeFixture()

        try await fixture.coordinator.executePlayTrack(
            request: SiriPlaybackRequest(
                entityID: "unknown-track-id",
                displayName: "Track One"
            )
        )
        XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, "track-1")

        try await fixture.coordinator.executePlayAlbum(
            request: SiriPlaybackRequest(
                entityID: "unknown-album-id",
                displayName: "Album One"
            )
        )
        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])

        try await fixture.coordinator.executePlayArtist(
            request: SiriPlaybackRequest(
                entityID: "unknown-artist-id",
                displayName: "Artist One"
            )
        )
        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-1", "track-2"])

        try await fixture.coordinator.executePlayPlaylist(
            request: SiriPlaybackRequest(
                entityID: "unknown-playlist-id",
                displayName: "Playlist One"
            )
        )
        XCTAssertEqual(fixture.playbackService.lastQueuedTracks.map(\.id), ["track-2", "track-1"])
    }

    func testSourceLessRequestDoesNotResolveByDirectIDAlone() async throws {
        let fixture = try await makeFixture()

        do {
            try await fixture.coordinator.executePlayTrack(
                request: SiriPlaybackRequest(entityID: "track-1")
            )
            XCTFail("Expected source-less direct ID lookup to fail closed")
        } catch let error as SiriPlaybackCoordinatorError {
            XCTAssertEqual(error, .mediaNotFound(.track))
        }
    }

    func testExplicitUnknownOrMalformedSourceDoesNotFallbackByName() async throws {
        let fixture = try await makeFixture()

        for sourceKey in [
            "plex:other-account:other-server:other-library",
            "appleMusic:device:system",
            "malformed-source"
        ] {
            do {
                try await fixture.coordinator.executePlayTrack(
                    request: SiriPlaybackRequest(
                        entityID: "unknown-track-id",
                        sourceCompositeKey: sourceKey,
                        displayName: "Track One"
                    )
                )
                XCTFail("Expected explicit source \(sourceKey) to fail closed")
            } catch let error as SiriPlaybackCoordinatorError {
                XCTAssertEqual(error, .mediaNotFound(.track))
            }
        }

        XCTAssertNil(fixture.playbackService.lastPlayedTrack)
    }

    /// The Shortcuts picker adds these to the index's own candidates: songs, albums and artists, never hidden items or
    /// items of sources that are not enabled and visible, found by every word of the query, and bounded.
    func testLibraryCandidatesFindNamesOutsideTheIndexWithinVisibilityAndBounds() async throws {
        let hidden = HiddenMediaStore(defaults: UserDefaults(suiteName: "siri-search-\(UUID().uuidString)")!)
        hidden.setHidden(true, identity: .init(kind: .track, itemID: "track-2", sourceCompositeKey: "plex:account-1:server-1:library-1"))
        let otherLibrary = "plex:account-1:server-2:library-2"
        let fixture = try await makeFixture(hiddenMediaStore: hidden, hiddenSourceKeys: [otherLibrary])
        let repository = fixture.libraryRepository
        let key = fixture.librarySourceKey

        // Normalized names the raw title lookup misses, and 12 hidden albums ahead of the visible exact "Home".
        try await repository.batchUpsertArtists([
            ArtistUpsertInput(ratingKey: "ewf", key: "/a/ewf", name: "Earth, Wind & Fire", summary: nil, thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: nil),
            ArtistUpsertInput(ratingKey: "acdc", key: "/a/acdc", name: "AC/DC", summary: nil, thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: nil)
        ], sourceCompositeKey: key)
        func album(_ id: String, _ title: String) -> AlbumUpsertInput {
            AlbumUpsertInput(
                ratingKey: id, key: "/a/\(id)", title: title, artistName: "Artist One", albumArtist: "Artist One", artistRatingKey: nil,
                summary: nil, thumbPath: nil, artPath: nil, year: 2000, trackCount: 1, dateAdded: nil, dateModified: nil, rating: nil
            )
        }
        _ = try await repository.upsertTrack(
            ratingKey: "rock-n-roll", key: "/library/metadata/rock-n-roll", title: "Rock'n'Roll", artistName: nil,
            albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
            streamKey: "/library/parts/rock-n-roll.mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: key
        )
        _ = try await repository.upsertTrack(
            ratingKey: "kim-live", key: "/library/metadata/kim-live", title: "Kim and Jessie Live", artistName: nil,
            albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
            streamKey: "/library/parts/kim-live.mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: key
        )
        let hiddenHome = (1...12).map { "home-hidden-\($0)" }
        try await repository.batchUpsertAlbums(
            [album("acdc-live", "AC/DC Live"), album("truth", "Don't Believe the Truth")] + hiddenHome.map { album($0, "Home") } + [album("home-visible", "Home")],
            sourceCompositeKey: key
        )
        for id in hiddenHome { hidden.setHidden(true, identity: .init(kind: .album, itemID: id, sourceCompositeKey: key)) }

        let cases: [(kind: SiriMediaKind?, query: String, limit: Int, expected: Set<String>)] = [
            (.track, "Track One", 10, ["track-1"]),
            (.track, "Track Two", 10, []),                       // hidden media
            (.track, "Ghost Track", 10, []),                     // source not enabled
            (.track, "Other One", 10, []),                       // source hidden by the visibility profile
            (.track, "kim and jessie", 10, ["track-amp"]),       // punctuation; the raw partial match "Kim and Jessie Live" does not hide it
            (.album, "Album One", 10, ["album-1"]),
            (.artist, "Artist One", 10, ["artist-1"]),
            (.artist, "ac dc", 10, ["acdc"]),                    // normalized match
            (.artist, "earth wind and fire", 10, ["ewf"]),       // "&" and punctuation
            (.track, "rocknroll", 10, ["rock-n-roll"]),          // apostrophes: found by scoring titles
            (.album, "ac dc", 10, ["acdc-live"]),
            (.album, "Home", 1, ["home-visible"]),               // hidden rows do not use up the cap of 10
            (nil, "O", 10, []),                                  // too short to search the store
            (.playlist, "Playlist One", 10, []),                 // playlists are not capped
            (.track, "Cap", 1, ["cap-exact"])                    // 40 other matches exceed the 10-row cap; the exact title is read first
        ]
        for testCase in cases {
            let items = try await fixture.coordinator.libraryCandidates(kind: testCase.kind, matching: testCase.query, limit: testCase.limit)
            if testCase.expected.isEmpty {
                XCTAssertTrue(items.isEmpty, "\(testCase.query): \(items.map(\.id))")
            } else {
                XCTAssertTrue(testCase.expected.isSubset(of: Set(items.map(\.id))), "\(testCase.query): \(items.map(\.id))")
            }
        }
        let stored = try await fixture.coordinator.storedItem(kind: .track, id: "track-1", sourceCompositeKey: key)
        XCTAssertEqual(stored?.displayName, "Track One")
        for (id, source) in [("track-2", key), ("ghost-1", "plex:account-1:server-3:library-3"), ("other-1", otherLibrary)] {
            let missing = try await fixture.coordinator.storedItem(kind: .track, id: id, sourceCompositeKey: source)
            XCTAssertNil(missing, id)
        }
    }

    private func upsert(_ repository: LibraryRepository, _ id: String, _ title: String, artist: String?, album: String?, source: String) async throws {
        _ = try await repository.upsertTrack(
            ratingKey: id, key: "/library/metadata/\(id)", title: title, artistName: artist,
            albumName: album, albumRatingKey: nil, trackNumber: 3, discNumber: 1, duration: 200_000, thumbPath: nil,
            streamKey: "/library/parts/\(id).mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: source
        )
    }

    /// A pinned song in a hidden library stands in only for the visible song with the same merge identity (title,
    /// artist, album, track and disc number, duration); a same-titled song by another artist, or a pinned song without
    /// the metadata to tell, is not found.
    func testPinnedHiddenSongIsRemappedOnlyByMergeIdentity() async throws {
        let hiddenKey = "plex:account-1:server-2:library-2"
        let fixture = try await makeFixture(hiddenSourceKeys: [hiddenKey])
        let repository = fixture.libraryRepository
        let visible = fixture.librarySourceKey
        try await upsert(repository, "pin-hidden", "Shared Song", artist: "Band", album: "Shared Album", source: hiddenKey)
        try await upsert(repository, "decoy", "Shared Song", artist: "Other Band", album: "Other Album", source: visible)
        try await upsert(repository, "pin-visible", "Shared Song", artist: "Band", album: "Shared Album", source: visible)
        try await upsert(repository, "no-metadata", "Plain Song", artist: nil, album: nil, source: hiddenKey)
        try await upsert(repository, "plain-visible", "Plain Song", artist: nil, album: nil, source: visible)

        let cases: [(id: String, title: String, expected: String?)] = [
            ("pin-hidden", "Shared Song", "pin-visible"),
            ("no-metadata", "Plain Song", nil)
        ]
        for testCase in cases {
            do {
                try await fixture.coordinator.executePlayTrack(
                    request: SiriPlaybackRequest(entityID: testCase.id, sourceCompositeKey: hiddenKey, displayName: testCase.title)
                )
                XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, testCase.expected, testCase.id)
            } catch {
                XCTAssertNil(testCase.expected, "\(testCase.id): \(error)")
            }
        }
    }

    /// An artist hint wins over the title ranking when it matches and is ignored when it matches nothing; a normalized-exact title outranks a raw partial match.
    func testNameResolutionPrefersTheArtistHintAndPrefersNormalizedExactTitles() async throws {
        let fixture = try await makeFixture()
        try await upsert(fixture.libraryRepository, "song-exact", "Song", artist: "Band", album: "A", source: fixture.librarySourceKey)
        try await upsert(fixture.libraryRepository, "song-extended", "Song Extended", artist: "Fan", album: "B", source: fixture.librarySourceKey)
        try await upsert(fixture.libraryRepository, "kim-live", "Kim and Jessie Live", artist: "Band", album: "Live", source: fixture.librarySourceKey)

        let cases: [(title: String, hint: String?, expected: String?)] = [
            ("Other One", "Other Artist", "other-1"),
            ("Other One", "Nobody", "other-1"),                   // the hint matches nothing: the title decides
            ("Song", "Fan", "song-extended"),                     // the hint wins over a better-ranked title
            ("Song", "Nobody", "song-exact"),                    // ...and is ignored when it matches nothing
            ("Kim and Jessie", nil, "track-amp")
        ]
        for testCase in cases {
            do {
                try await fixture.coordinator.executePlayTrack(
                    request: SiriPlaybackRequest(entityID: "unpinned", displayName: testCase.title, artistHint: testCase.hint)
                )
                XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, testCase.expected, testCase.title)
            } catch {
                XCTAssertNil(testCase.expected, "\(testCase.title): \(error)")
            }
        }
    }

    /// A song in a library the profile hides is not played, even when asked for by its exact identity.
    func testPlaybackExcludesHiddenSources() async throws {
        let fixture = try await makeFixture(hiddenSourceKeys: ["plex:account-1:server-2:library-2"])
        do {
            try await fixture.coordinator.executePlayTrack(
                request: SiriPlaybackRequest(entityID: "other-1", sourceCompositeKey: fixture.otherLibrarySourceKey, displayName: "Other One")
            )
            XCTFail("A hidden source's song must not play")
        } catch {
            XCTAssertNil(fixture.playbackService.lastPlayedTrack)
        }
        try await fixture.coordinator.executePlayTrack(
            request: SiriPlaybackRequest(entityID: "track-1", sourceCompositeKey: fixture.librarySourceKey, displayName: "Track One")
        )
        XCTAssertEqual(fixture.playbackService.lastPlayedTrack?.id, "track-1")
    }

    private func makeFixture(
        mergingPreferences: EnsembleMergingPreferences = .default,
        hiddenMediaStore: HiddenMediaStore? = nil,
        hiddenSourceKeys: Set<String> = []
    ) async throws -> Fixture {
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

        _ = try await libraryRepository.upsertTrack(
            ratingKey: "track-amp",
            key: "/library/metadata/track-amp",
            title: "Kim & Jessie",
            artistName: "Other Artist",
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-amp.mp3",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: 0,
            sourceCompositeKey: librarySourceKey
        )

        // More rows containing "Cap" than the picker's fetch cap, plus the exact title.
        for number in 1...40 {
            _ = try await libraryRepository.upsertTrack(
                ratingKey: "cap-\(number)", key: "/library/metadata/cap-\(number)", title: "A Cap Song \(number)", artistName: nil,
                albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
                streamKey: "/library/parts/cap-\(number).mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
                playCount: 0, sourceCompositeKey: librarySourceKey
            )
        }
        _ = try await libraryRepository.upsertTrack(
            ratingKey: "cap-exact", key: "/library/metadata/cap-exact", title: "Cap", artistName: nil,
            albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
            streamKey: "/library/parts/cap-exact.mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: librarySourceKey
        )

        // A track in a source no account has enabled.
        _ = try await libraryRepository.upsertTrack(
            ratingKey: "ghost-1", key: "/library/metadata/ghost-1", title: "Ghost Track", artistName: nil,
            albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
            streamKey: "/library/parts/ghost-1.mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: "plex:\(accountID):server-3:library-3"
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

        // A second server whose "Focus  Mix" (extra space) is the same playlist as the first server's "Focus Mix".
        let otherServerKey = "plex:\(accountID):server-2"
        let otherLibraryKey = "\(otherServerKey):library-2"
        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: otherLibraryKey, type: "plex", accountId: accountID, serverId: "server-2",
            libraryId: "library-2", displayName: "Music", accountName: "Test Account"
        )
        _ = try await libraryRepository.upsertTrack(
            ratingKey: "other-1", key: "/library/metadata/other-1", title: "Other One", artistName: "Other Artist",
            albumName: nil, albumRatingKey: nil, trackNumber: 1, discNumber: 1, duration: 180_000, thumbPath: nil,
            streamKey: "/library/parts/other-1.mp3", dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil,
            playCount: 0, sourceCompositeKey: otherLibraryKey
        )
        for (key, title, isSmart, server, member) in [
            ("focus-a", "Focus Mix", false, serverSourceKey, "track-1"),
            ("focus-b", "Focus  Mix", false, otherServerKey, "other-1"),
            ("focus-smart", "Focus Mix", true, otherServerKey, "other-1")
        ] {
            _ = try await playlistRepository.upsertPlaylist(
                ratingKey: key, key: "/playlists/\(key)", title: title, summary: nil, compositePath: nil,
                isSmart: isSmart, duration: 0, trackCount: 1, dateAdded: nil, dateModified: nil, lastPlayed: nil,
                sourceCompositeKey: server
            )
            try await playlistRepository.setPlaylistTracks([member], forPlaylist: key, sourceCompositeKey: server)
        }

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
                    ),
                    PlexServerConfig(
                        id: "server-2",
                        name: "Server Two",
                        url: "https://example.org",
                        token: "token",
                        libraries: [PlexLibraryConfig(id: "library-2", key: "library-2", title: "Music", isEnabled: true)]
                    )
                ]
            )
        )

        let visibilityStore = LibraryVisibilityStore(userDefaults: UserDefaults(suiteName: "siri-visibility-\(UUID().uuidString)")!)
        visibilityStore.setHiddenSourceCompositeKeys(hiddenSourceKeys)
        let playbackService = RecordingPlaybackService()
        let coordinator = SiriPlaybackCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            playbackService: playbackService,
            hiddenMediaStore: hiddenMediaStore,
            visibilityStore: visibilityStore,
            mergingPreferences: { mergingPreferences }
        )

        return Fixture(
            coordinator: coordinator,
            playbackService: playbackService,
            librarySourceKey: librarySourceKey,
            serverSourceKey: serverSourceKey,
            libraryRepository: libraryRepository,
            otherLibrarySourceKey: otherLibraryKey,
            playlistRepository: playlistRepository
        )
    }
}
