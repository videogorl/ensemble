import Foundation
import MediaPlayer
import Nuke

struct PlaybackNowPlayingCommandHandlers {
    let play: () -> Void
    let pause: () -> Void
    let toggle: () -> Void
    let next: () -> Void
    let previous: () -> Void
    let seek: (TimeInterval) -> Void
    let cycleRepeatMode: () -> Void
    let toggleShuffle: () -> Void
    let rateLike: () -> MPRemoteCommandHandlerStatus
    let rateDislike: () -> MPRemoteCommandHandlerStatus
    let currentPlaybackState: () -> PlaybackState
    let currentTime: () -> TimeInterval
    let trackAge: () -> CFTimeInterval
    let shouldAcceptSkip: () -> Bool
}

struct PlaybackNowPlayingState {
    let track: Track?
    let playbackState: PlaybackState
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLiked: Bool
    let isDisliked: Bool
    let canPlay: Bool
    let canPause: Bool
    let canSkipForward: Bool
    let canSkipBackward: Bool
    let canSeek: Bool
    let canToggleShuffle: Bool
    let canCycleRepeatMode: Bool
}

/// Owns lock-screen metadata plus remote command registration.
final class PlaybackNowPlayingBridge {
    private let artworkLoader: ArtworkLoaderProtocol
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestKey: String?
    private var artworkTrackID: String?
    private var artwork: MPMediaItemArtwork?

    init(artworkLoader: ArtworkLoaderProtocol) {
        self.artworkLoader = artworkLoader
    }

    func installRemoteCommands(handlers: PlaybackNowPlayingCommandHandlers) {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { _ in
            EnsembleLogger.debug("[Handoff] remote play command received")
            handlers.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { _ in
            EnsembleLogger.debug("[Handoff] remote pause command received")
            handlers.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { _ in
            EnsembleLogger.debug("[Handoff] remote toggle command received")
            handlers.toggle()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { _ in
            guard handlers.shouldAcceptSkip() else { return .success }
            handlers.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { _ in
            guard handlers.shouldAcceptSkip() else { return .success }
            handlers.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            let position = event.positionTime
            let trackAge = handlers.trackAge()
            let currentTime = handlers.currentTime()

            if trackAge < 5.0 && trackAge > 0 {
                let delta = abs(position - currentTime)
                if delta > 30.0 {
                    EnsembleLogger.debug("[RemoteSeek] Rejected stale position command: target=\(String(format: "%.1f", position))s current=\(String(format: "%.1f", currentTime))s trackAge=\(String(format: "%.1f", trackAge))s")
                    return .success
                }
            }

            EnsembleLogger.debug("[RemoteSeek] Accepted: \(String(format: "%.1f", position))s (current=\(String(format: "%.1f", currentTime))s, trackAge=\(String(format: "%.1f", trackAge))s)")
            handlers.seek(position)
            return .success
        }

        commandCenter.changeRepeatModeCommand.addTarget { _ in
            handlers.cycleRepeatMode()
            return .success
        }

        commandCenter.changeShuffleModeCommand.addTarget { _ in
            handlers.toggleShuffle()
            return .success
        }

        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.addTarget { _ in
            handlers.rateLike()
        }

        commandCenter.dislikeCommand.isEnabled = true
        commandCenter.dislikeCommand.addTarget { _ in
            handlers.rateDislike()
        }
    }

    func updateNowPlayingInfo(_ state: PlaybackNowPlayingState) {
        guard let track = state.track else {
            cancelArtworkLoad(clearArtwork: true)
            updateFeedbackCommandState(isLiked: false, isDisliked: false)
            updateCommandAvailability(state)
            return
        }

        let artworkIdentity = track.thumbPath ?? track.fallbackThumbPath ?? track.id
        let artworkSourceKey = track.thumbPath != nil ? track.id : (track.fallbackRatingKey ?? track.id)
        let nextArtworkRequestKey = "\(artworkSourceKey)|\(artworkIdentity)|\(track.sourceCompositeKey ?? "")"
        let rate: Double = state.playbackState == .playing ? 1.0 : 0.0
        let effectiveDuration = state.playbackState == .loading ? track.duration : state.duration

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if effectiveDuration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(max(state.currentTime / effectiveDuration, 0), 1)
        }

        if let artist = track.artistName {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        if artworkTrackID == track.id, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncNowPlayingPlaybackState(state.playbackState)
        updateFeedbackCommandState(isLiked: state.isLiked, isDisliked: state.isDisliked)
        updateCommandAvailability(state)

        EnsembleLogger.debug("[NowPlaying] Updated: '\(track.title)' rate=\(rate) elapsed=\(String(format: "%.1f", state.currentTime))s duration=\(String(format: "%.1f", effectiveDuration))s state=\(state.playbackState)")

        guard artworkRequestKey != nextArtworkRequestKey else { return }
        cancelArtworkLoad(clearArtwork: false)
        artworkRequestKey = nextArtworkRequestKey

        artworkTask = Task { [weak self] in
            guard let self else { return }

            guard let url = await self.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600
            ) else {
                return
            }

            if Task.isCancelled { return }

            let request = ImageRequest(url: url)
            guard let image = try? await ImagePipeline.shared.image(for: request) else {
                return
            }

            if Task.isCancelled { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }

            await MainActor.run {
                self.applyArtwork(artwork, to: track.id, playbackState: state.playbackState)
            }
        }
    }

    func updateNowPlayingProgress(
        currentTime: TimeInterval,
        duration: TimeInterval,
        playbackState: PlaybackState
    ) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackState == .playing ? 1.0 : 0.0
        if duration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(max(currentTime / duration, 0), 1)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncNowPlayingPlaybackState(playbackState)
    }

    func pushNowPlayingForSkipTransition(_ state: PlaybackNowPlayingState) {
        updateNowPlayingInfo(state)
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }
    }

    func cancelArtworkLoad(clearArtwork: Bool) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestKey = nil
        if clearArtwork {
            artworkTrackID = nil
            artwork = nil
        }
    }

    func updateFeedbackCommandState(isLiked: Bool, isDisliked: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.likeCommand.isActive = isLiked
        commandCenter.dislikeCommand.isActive = isDisliked
    }

    func updateCommandAvailability(_ state: PlaybackNowPlayingState) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = state.canPlay
        commandCenter.pauseCommand.isEnabled = state.canPause
        commandCenter.togglePlayPauseCommand.isEnabled = state.canPlay || state.canPause
        commandCenter.nextTrackCommand.isEnabled = state.canSkipForward
        commandCenter.previousTrackCommand.isEnabled = state.canSkipBackward
        commandCenter.changePlaybackPositionCommand.isEnabled = state.canSeek
        commandCenter.changeShuffleModeCommand.isEnabled = state.canToggleShuffle
        commandCenter.changeRepeatModeCommand.isEnabled = state.canCycleRepeatMode
        commandCenter.likeCommand.isEnabled = state.track != nil
        commandCenter.dislikeCommand.isEnabled = state.track != nil
    }

    private func applyArtwork(
        _ artwork: MPMediaItemArtwork,
        to trackID: String,
        playbackState: PlaybackState
    ) {
        self.artwork = artwork
        artworkTrackID = trackID
        var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        currentInfo[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        syncNowPlayingPlaybackState(playbackState)
    }

    private func syncNowPlayingPlaybackState(_ playbackState: PlaybackState) {
        let mpState: MPNowPlayingPlaybackState
        switch playbackState {
        case .playing:
            mpState = .playing
        case .paused:
            mpState = .paused
        case .stopped, .failed:
            mpState = .stopped
        case .loading, .buffering:
            return
        }

        MPNowPlayingInfoCenter.default().playbackState = mpState
        EnsembleLogger.debug("[NowPlaying] Synced playbackState → \(mpState.rawValue) (app=\(playbackState))")
    }
}
