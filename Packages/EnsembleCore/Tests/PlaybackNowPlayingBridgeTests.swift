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

    private func makeTrack() -> Track {
        Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track Name",
            artistName: "Track Artist",
            albumArtistName: "Album Artist",
            albumName: "Album Name",
            albumRatingKey: "album-1",
            artistRatingKey: "artist-1",
            trackNumber: 4,
            discNumber: 1,
            duration: 180,
            thumbPath: "/thumb/track",
            fallbackThumbPath: "/thumb/album",
            fallbackRatingKey: "album-1",
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
}

private struct MockArtworkLoader: ArtworkLoaderProtocol {
    func artworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        size: Int
    ) async -> URL? {
        nil
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
