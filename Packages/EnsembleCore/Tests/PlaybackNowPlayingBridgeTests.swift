import EnsemblePersistence
import MediaPlayer
import XCTest
@testable import EnsembleCore

final class PlaybackNowPlayingBridgeTests: XCTestCase {
    func testMetadataBuilderIncludesSourceScopedIdentityAndQueueFields() {
        let track = makeTrack()
        let state = makeState(
            track: track,
            playbackState: .playing,
            currentTime: 42,
            duration: 180,
            queueIndex: 2,
            queueCount: 7
        )

        let info = PlaybackNowPlayingBridge.makeNowPlayingInfo(state: state, artwork: nil)

        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Track Name")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Track Artist")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Album Name")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTrackNumber] as? Int, 4)
        XCTAssertEqual(info[MPMediaItemPropertyDiscNumber] as? Int, 1)
        XCTAssertEqual(info[MPMediaItemPropertyGenre] as? String, "Electronic")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, 180)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, 42)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int, 2)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int, 7)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, "track||track-1||plex://server/library")
        XCTAssertEqual(info[MPNowPlayingInfoCollectionIdentifier] as? String, "album||album-1||plex://server/library")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyExternalUserProfileIdentifier] as? String, "plex://server/library")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyServiceIdentifier] as? String, "Ensemble")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
    }

    func testBridgeUpdatesCenterAndCommandState() {
        let nowPlayingCenter = FakeNowPlayingInfoCenter()
        let commandCenter = FakeRemoteCommandCenter()
        let bridge = PlaybackNowPlayingBridge(
            artworkLoader: MockArtworkLoader(),
            nowPlayingCenter: nowPlayingCenter,
            commandCenter: commandCenter
        )

        bridge.updateNowPlayingInfo(
            makeState(
                track: makeTrack(),
                playbackState: .paused,
                queueIndex: 0,
                queueCount: 1,
                isShuffleEnabled: true,
                repeatMode: .one,
                isLiked: true,
                canPlay: true,
                canPause: false,
                canSkipForward: false,
                canSkipBackward: true
            )
        )

        XCTAssertEqual(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track Name")
        XCTAssertEqual(nowPlayingCenter.playbackState, .paused)
        XCTAssertTrue(commandCenter.play.isEnabled)
        XCTAssertFalse(commandCenter.pause.isEnabled)
        XCTAssertTrue(commandCenter.previousTrack.isEnabled)
        XCTAssertFalse(commandCenter.nextTrack.isEnabled)
        XCTAssertTrue(commandCenter.like.isActive)
        XCTAssertFalse(commandCenter.dislike.isActive)
        XCTAssertEqual(commandCenter.changeShuffle.currentShuffleType, .items)
        XCTAssertEqual(commandCenter.changeRepeat.currentRepeatType, .one)
    }

    func testBridgeReplacesExistingArtworkWhenArtworkIdentityChanges() async throws {
        let artworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: artworkURL.deletingLastPathComponent()) }

        let artworkLoader = MockArtworkLoader(artworkURL: artworkURL)
        let nowPlayingCenter = FakeNowPlayingInfoCenter()
        let bridge = PlaybackNowPlayingBridge(
            artworkLoader: artworkLoader,
            nowPlayingCenter: nowPlayingCenter,
            commandCenter: FakeRemoteCommandCenter()
        )

        bridge.updateNowPlayingInfo(makeState(
            track: makeTrack(
                id: "track-1",
                title: "Track One",
                albumRatingKey: "album-1",
                thumbPath: nil,
                fallbackThumbPath: "/thumb/album-1",
                fallbackRatingKey: "album-1"
            )
        ))

        await waitUntil("first artwork load") {
            nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork
        }
        let firstArtwork = try XCTUnwrap(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)

        artworkLoader.artworkURL = nil
        bridge.updateNowPlayingInfo(makeState(
            track: makeTrack(
                id: "track-2",
                title: "Track Two",
                albumRatingKey: "album-2",
                thumbPath: nil,
                fallbackThumbPath: "/thumb/album-2",
                fallbackRatingKey: "album-2"
            )
        ))

        let secondArtwork = try XCTUnwrap(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track Two")
        XCTAssertFalse(firstArtwork === secondArtwork)
    }

    func testBridgeReusesArtworkWhenTracksShareArtworkIdentity() async throws {
        let artworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: artworkURL.deletingLastPathComponent()) }

        let artworkLoader = MockArtworkLoader(artworkURL: artworkURL)
        let nowPlayingCenter = FakeNowPlayingInfoCenter()
        let bridge = PlaybackNowPlayingBridge(
            artworkLoader: artworkLoader,
            nowPlayingCenter: nowPlayingCenter,
            commandCenter: FakeRemoteCommandCenter()
        )

        bridge.updateNowPlayingInfo(makeState(
            track: makeTrack(
                id: "track-1",
                title: "Track One",
                albumRatingKey: "album-1",
                thumbPath: nil,
                fallbackThumbPath: "/thumb/album-1",
                fallbackRatingKey: "album-1"
            )
        ))

        await waitUntil("first artwork load") {
            nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork
        }

        bridge.updateNowPlayingInfo(makeState(
            track: makeTrack(
                id: "track-2",
                title: "Track Two",
                albumRatingKey: "album-1",
                thumbPath: nil,
                fallbackThumbPath: "/thumb/album-1",
                fallbackRatingKey: "album-1"
            )
        ))

        XCTAssertEqual(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track Two")
        XCTAssertTrue(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        XCTAssertEqual(artworkLoader.requestCount, 1)
    }

    func testBridgeUsesFallbackArtworkWhenTrackHasNoArtworkPath() {
        let artworkLoader = MockArtworkLoader()
        let nowPlayingCenter = FakeNowPlayingInfoCenter()
        let bridge = PlaybackNowPlayingBridge(
            artworkLoader: artworkLoader,
            nowPlayingCenter: nowPlayingCenter,
            commandCenter: FakeRemoteCommandCenter()
        )

        bridge.updateNowPlayingInfo(makeState(
            track: makeTrack(
                thumbPath: nil,
                fallbackThumbPath: nil,
                fallbackRatingKey: nil
            )
        ))

        XCTAssertTrue(nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        XCTAssertEqual(artworkLoader.requestCount, 0)
    }

    func testInstallingRemoteCommandsRemovesPreviousHandlers() {
        let commandCenter = FakeRemoteCommandCenter()
        let bridge = PlaybackNowPlayingBridge(
            artworkLoader: MockArtworkLoader(),
            nowPlayingCenter: FakeNowPlayingInfoCenter(),
            commandCenter: commandCenter
        )

        bridge.installRemoteCommands(handlers: makeHandlers())
        XCTAssertEqual(commandCenter.play.handlerCount, 1)
        XCTAssertEqual(commandCenter.changeRepeat.handlerCount, 1)
        XCTAssertEqual(commandCenter.like.handlerCount, 1)

        bridge.installRemoteCommands(handlers: makeHandlers())

        XCTAssertEqual(commandCenter.play.handlerCount, 1)
        XCTAssertEqual(commandCenter.changeRepeat.handlerCount, 1)
        XCTAssertEqual(commandCenter.like.handlerCount, 1)
        XCTAssertEqual(commandCenter.play.removedTargetCount, 1)
        XCTAssertEqual(commandCenter.changeRepeat.removedTargetCount, 1)
        XCTAssertEqual(commandCenter.like.removedTargetCount, 1)
    }

    func testShuffleAndRepeatMappingUsesExactMediaPlayerModes() {
        XCTAssertEqual(PlaybackNowPlayingBridge.shuffleType(for: false), .off)
        XCTAssertEqual(PlaybackNowPlayingBridge.shuffleType(for: true), .items)
        XCTAssertFalse(PlaybackNowPlayingBridge.isShuffleEnabled(for: .off))
        XCTAssertTrue(PlaybackNowPlayingBridge.isShuffleEnabled(for: .items))
        XCTAssertTrue(PlaybackNowPlayingBridge.isShuffleEnabled(for: .collections))

        XCTAssertEqual(PlaybackNowPlayingBridge.repeatType(for: .off), .off)
        XCTAssertEqual(PlaybackNowPlayingBridge.repeatType(for: .all), .all)
        XCTAssertEqual(PlaybackNowPlayingBridge.repeatType(for: .one), .one)
        XCTAssertEqual(PlaybackNowPlayingBridge.repeatMode(for: .off), .off)
        XCTAssertEqual(PlaybackNowPlayingBridge.repeatMode(for: .all), .all)
        XCTAssertEqual(PlaybackNowPlayingBridge.repeatMode(for: .one), .one)
    }

    private func makeTrack(
        id: String = "track-1",
        title: String = "Track Name",
        albumRatingKey: String? = "album-1",
        thumbPath: String? = "/thumb/track",
        fallbackThumbPath: String? = "/thumb/album",
        fallbackRatingKey: String? = "album-1"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            artistName: "Track Artist",
            albumArtistName: "Album Artist",
            albumName: "Album Name",
            albumRatingKey: albumRatingKey,
            artistRatingKey: "artist-1",
            trackNumber: 4,
            discNumber: 1,
            duration: 180,
            thumbPath: thumbPath,
            fallbackThumbPath: fallbackThumbPath,
            fallbackRatingKey: fallbackRatingKey,
            genres: ["Electronic"],
            sourceCompositeKey: "plex://server/library"
        )
    }

    private func makeState(
        track: Track?,
        playbackState: PlaybackState = .playing,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 180,
        queueIndex: Int = 0,
        queueCount: Int = 1,
        isShuffleEnabled: Bool = false,
        repeatMode: RepeatMode = .off,
        isLiked: Bool = false,
        isDisliked: Bool = false,
        canPlay: Bool = false,
        canPause: Bool = true,
        canSkipForward: Bool = true,
        canSkipBackward: Bool = true,
        canSeek: Bool = true,
        canToggleShuffle: Bool = true,
        canCycleRepeatMode: Bool = true
    ) -> PlaybackNowPlayingState {
        PlaybackNowPlayingState(
            track: track,
            playbackState: playbackState,
            currentTime: currentTime,
            duration: duration,
            queueIndex: queueIndex,
            queueCount: queueCount,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            isLiked: isLiked,
            isDisliked: isDisliked,
            canPlay: canPlay,
            canPause: canPause,
            canSkipForward: canSkipForward,
            canSkipBackward: canSkipBackward,
            canSeek: canSeek,
            canToggleShuffle: canToggleShuffle,
            canCycleRepeatMode: canCycleRepeatMode
        )
    }

    private func makeHandlers() -> PlaybackNowPlayingCommandHandlers {
        PlaybackNowPlayingCommandHandlers(
            play: {},
            pause: {},
            toggle: {},
            next: {},
            previous: {},
            seek: { _ in },
            setRepeatMode: { _ in },
            setShuffleEnabled: { _ in },
            rateLike: { .success },
            rateDislike: { .success },
            currentTime: { 0 },
            trackAge: { 0 },
            shouldAcceptSkip: { true }
        )
    }

    private func makeTemporaryPNG() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("artwork.png")
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
        try data.write(to: url)
        return url
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class MockArtworkLoader: ArtworkLoaderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _artworkURL: URL?
    private var _requestCount = 0

    init(artworkURL: URL? = nil) {
        self._artworkURL = artworkURL
    }

    var artworkURL: URL? {
        get { locked { _artworkURL } }
        set { locked { _artworkURL = newValue } }
    }

    var requestCount: Int {
        locked { _requestCount }
    }

    func artworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        size: Int
    ) async -> URL? {
        locked {
            _requestCount += 1
            return _artworkURL
        }
    }

    func predownloadArtwork(for albums: [CDAlbum], sourceKey: String, size: Int) async throws -> Int {
        0
    }

    func predownloadArtwork(for artists: [CDArtist], sourceKey: String, size: Int) async throws -> Int {
        0
    }

    func predownloadArtwork(for playlists: [CDPlaylist], sourceKey: String, size: Int) async throws -> Int {
        0
    }

    func invalidateURLCache() async {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeNowPlayingInfoCenter: PlaybackNowPlayingInfoCenter {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}

private class FakeRemoteCommand: PlaybackRemoteCommand {
    var isEnabled = false
    private var nextToken = 0
    private var handlers: [Int: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus] = [:]
    private(set) var removedTargetCount = 0

    var handlerCount: Int {
        handlers.count
    }

    @discardableResult
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any {
        nextToken += 1
        handlers[nextToken] = handler
        return nextToken
    }

    func removeTarget(_ target: Any) {
        guard let token = target as? Int else { return }
        if handlers.removeValue(forKey: token) != nil {
            removedTargetCount += 1
        }
    }
}

private final class FakeFeedbackCommand: FakeRemoteCommand, PlaybackFeedbackCommand {
    var isActive = false
}

private final class FakeChangeShuffleModeCommand: FakeRemoteCommand, PlaybackChangeShuffleModeCommand {
    var currentShuffleType: MPShuffleType = .off
}

private final class FakeChangeRepeatModeCommand: FakeRemoteCommand, PlaybackChangeRepeatModeCommand {
    var currentRepeatType: MPRepeatType = .off
}

private final class FakeRemoteCommandCenter: PlaybackRemoteCommandCenter {
    let play = FakeRemoteCommand()
    let pause = FakeRemoteCommand()
    let togglePlayPause = FakeRemoteCommand()
    let nextTrack = FakeRemoteCommand()
    let previousTrack = FakeRemoteCommand()
    let changePlaybackPosition = FakeRemoteCommand()
    let changeRepeat = FakeChangeRepeatModeCommand()
    let changeShuffle = FakeChangeShuffleModeCommand()
    let like = FakeFeedbackCommand()
    let dislike = FakeFeedbackCommand()

    var playCommand: PlaybackRemoteCommand { play }
    var pauseCommand: PlaybackRemoteCommand { pause }
    var togglePlayPauseCommand: PlaybackRemoteCommand { togglePlayPause }
    var nextTrackCommand: PlaybackRemoteCommand { nextTrack }
    var previousTrackCommand: PlaybackRemoteCommand { previousTrack }
    var changePlaybackPositionCommand: PlaybackRemoteCommand { changePlaybackPosition }
    var changeRepeatModeCommand: PlaybackChangeRepeatModeCommand { changeRepeat }
    var changeShuffleModeCommand: PlaybackChangeShuffleModeCommand { changeShuffle }
    var likeCommand: PlaybackFeedbackCommand { like }
    var dislikeCommand: PlaybackFeedbackCommand { dislike }
}
