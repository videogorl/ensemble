import EnsembleSiriShared
import Foundation
import MediaPlayer

#if canImport(UIKit)
import UIKit
private typealias PlatformArtworkImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformArtworkImage = NSImage
#endif

protocol PlaybackNowPlayingInfoCenter: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: PlaybackNowPlayingInfoCenter {}

protocol PlaybackRemoteCommand: AnyObject {
    var isEnabled: Bool { get set }

    @discardableResult
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any
    func removeTarget(_ target: Any)
}

protocol PlaybackFeedbackCommand: PlaybackRemoteCommand {
    var isActive: Bool { get set }
}

protocol PlaybackChangeShuffleModeCommand: PlaybackRemoteCommand {
    var currentShuffleType: MPShuffleType { get set }
}

protocol PlaybackChangeRepeatModeCommand: PlaybackRemoteCommand {
    var currentRepeatType: MPRepeatType { get set }
}

protocol PlaybackRemoteCommandCenter: AnyObject {
    var playCommand: PlaybackRemoteCommand { get }
    var pauseCommand: PlaybackRemoteCommand { get }
    var togglePlayPauseCommand: PlaybackRemoteCommand { get }
    var nextTrackCommand: PlaybackRemoteCommand { get }
    var previousTrackCommand: PlaybackRemoteCommand { get }
    var changePlaybackPositionCommand: PlaybackRemoteCommand { get }
    var changeRepeatModeCommand: PlaybackChangeRepeatModeCommand { get }
    var changeShuffleModeCommand: PlaybackChangeShuffleModeCommand { get }
    var likeCommand: PlaybackFeedbackCommand { get }
    var dislikeCommand: PlaybackFeedbackCommand { get }
}

private class LivePlaybackRemoteCommandAdapter<Command: MPRemoteCommand>: PlaybackRemoteCommand {
    let command: Command

    init(_ command: Command) {
        self.command = command
    }

    var isEnabled: Bool {
        get { command.isEnabled }
        set { command.isEnabled = newValue }
    }

    @discardableResult
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any {
        command.addTarget(handler: handler)
    }

    func removeTarget(_ target: Any) {
        command.removeTarget(target)
    }
}

private final class LivePlaybackFeedbackCommand: LivePlaybackRemoteCommandAdapter<MPFeedbackCommand>, PlaybackFeedbackCommand {
    var isActive: Bool {
        get { command.isActive }
        set { command.isActive = newValue }
    }
}

private final class LivePlaybackChangeShuffleModeCommand:
    LivePlaybackRemoteCommandAdapter<MPChangeShuffleModeCommand>,
    PlaybackChangeShuffleModeCommand
{
    var currentShuffleType: MPShuffleType {
        get { command.currentShuffleType }
        set { command.currentShuffleType = newValue }
    }
}

private final class LivePlaybackChangeRepeatModeCommand:
    LivePlaybackRemoteCommandAdapter<MPChangeRepeatModeCommand>,
    PlaybackChangeRepeatModeCommand
{
    var currentRepeatType: MPRepeatType {
        get { command.currentRepeatType }
        set { command.currentRepeatType = newValue }
    }
}

private final class LivePlaybackRemoteCommandCenter: PlaybackRemoteCommandCenter {
    let playCommand: PlaybackRemoteCommand
    let pauseCommand: PlaybackRemoteCommand
    let togglePlayPauseCommand: PlaybackRemoteCommand
    let nextTrackCommand: PlaybackRemoteCommand
    let previousTrackCommand: PlaybackRemoteCommand
    let changePlaybackPositionCommand: PlaybackRemoteCommand
    let changeRepeatModeCommand: PlaybackChangeRepeatModeCommand
    let changeShuffleModeCommand: PlaybackChangeShuffleModeCommand
    let likeCommand: PlaybackFeedbackCommand
    let dislikeCommand: PlaybackFeedbackCommand

    init(center: MPRemoteCommandCenter = .shared()) {
        self.playCommand = LivePlaybackRemoteCommandAdapter(center.playCommand)
        self.pauseCommand = LivePlaybackRemoteCommandAdapter(center.pauseCommand)
        self.togglePlayPauseCommand = LivePlaybackRemoteCommandAdapter(center.togglePlayPauseCommand)
        self.nextTrackCommand = LivePlaybackRemoteCommandAdapter(center.nextTrackCommand)
        self.previousTrackCommand = LivePlaybackRemoteCommandAdapter(center.previousTrackCommand)
        self.changePlaybackPositionCommand = LivePlaybackRemoteCommandAdapter(center.changePlaybackPositionCommand)
        self.changeRepeatModeCommand = LivePlaybackChangeRepeatModeCommand(center.changeRepeatModeCommand)
        self.changeShuffleModeCommand = LivePlaybackChangeShuffleModeCommand(center.changeShuffleModeCommand)
        self.likeCommand = LivePlaybackFeedbackCommand(center.likeCommand)
        self.dislikeCommand = LivePlaybackFeedbackCommand(center.dislikeCommand)
    }
}

struct PlaybackNowPlayingCommandHandlers {
    let play: () -> Void
    let pause: () -> Void
    let toggle: () -> Void
    let next: () -> Void
    let previous: () -> Void
    let seek: (TimeInterval) -> Void
    let setRepeatMode: (RepeatMode) -> Void
    let setShuffleEnabled: (Bool) -> Void
    let rateLike: () -> MPRemoteCommandHandlerStatus
    let rateDislike: () -> MPRemoteCommandHandlerStatus
    let currentTime: () -> TimeInterval
    let trackAge: () -> CFTimeInterval
    let shouldAcceptSkip: () -> Bool
}

struct PlaybackNowPlayingState {
    let track: Track?
    let playbackState: PlaybackState
    let currentTime: TimeInterval
    let duration: TimeInterval
    let queueIndex: Int
    let queueCount: Int
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let isLiked: Bool
    let isDisliked: Bool
    let canLike: Bool
    let canDislike: Bool
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
    private struct RemoteCommandHandlerToken {
        let command: PlaybackRemoteCommand
        let token: Any
    }

    private let artworkLoader: ArtworkLoaderProtocol
    private let nowPlayingCenter: PlaybackNowPlayingInfoCenter?
    private let commandCenter: PlaybackRemoteCommandCenter?
    private var commandHandlerTokens: [RemoteCommandHandlerToken] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestKey: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkRecoveryObserver: NSObjectProtocol?
    private var latestPlaybackState: PlaybackState = .stopped

    init(
        artworkLoader: ArtworkLoaderProtocol,
        nowPlayingCenter: PlaybackNowPlayingInfoCenter? = nil,
        commandCenter: PlaybackRemoteCommandCenter? = nil
    ) {
        self.artworkLoader = artworkLoader
        self.nowPlayingCenter = nowPlayingCenter ?? MPNowPlayingInfoCenter.default()
        self.commandCenter = commandCenter ?? LivePlaybackRemoteCommandCenter()
        self.artworkRecoveryObserver = NotificationCenter.default.addObserver(
            forName: ArtworkLoader.serversBecameAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareArtworkRetry()
        }
    }

    deinit {
        if let artworkRecoveryObserver {
            NotificationCenter.default.removeObserver(artworkRecoveryObserver)
        }
        removeRemoteCommandHandlers()
        cancelArtworkLoad(clearArtwork: true)
    }

    func installRemoteCommands(handlers: PlaybackNowPlayingCommandHandlers) {
        guard let commandCenter else { return }
        removeRemoteCommandHandlers()

        register(commandCenter.playCommand) { _ in
            EnsembleLogger.debug("[Handoff] remote play command received")
            handlers.play()
            return .success
        }

        register(commandCenter.pauseCommand) { _ in
            EnsembleLogger.debug("[Handoff] remote pause command received")
            handlers.pause()
            return .success
        }

        register(commandCenter.togglePlayPauseCommand) { _ in
            EnsembleLogger.debug("[Handoff] remote toggle command received")
            handlers.toggle()
            return .success
        }

        register(commandCenter.nextTrackCommand) { _ in
            guard handlers.shouldAcceptSkip() else { return .success }
            handlers.next()
            return .success
        }

        register(commandCenter.previousTrackCommand) { _ in
            guard handlers.shouldAcceptSkip() else { return .success }
            handlers.previous()
            return .success
        }

        register(commandCenter.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            let position = event.positionTime
            let trackAge = handlers.trackAge()
            let currentTime = handlers.currentTime()
            let nowTimestamp = ProcessInfo.processInfo.systemUptime

            if Self.shouldRejectRemoteSeekAsStale(
                targetPosition: position,
                currentTime: currentTime,
                trackAge: trackAge,
                eventTimestamp: event.timestamp,
                nowTimestamp: nowTimestamp
            ) {
                let eventAge = max(0, nowTimestamp - event.timestamp)
                EnsembleLogger.debug(
                    "[RemoteSeek] Rejected stale position command:"
                    + " target=\(String(format: "%.1f", position))s"
                    + " current=\(String(format: "%.1f", currentTime))s"
                    + " trackAge=\(String(format: "%.1f", trackAge))s"
                    + " eventAge=\(String(format: "%.1f", eventAge))s"
                )
                return .success
            }

            EnsembleLogger.debug("[RemoteSeek] Accepted: \(String(format: "%.1f", position))s (current=\(String(format: "%.1f", currentTime))s, trackAge=\(String(format: "%.1f", trackAge))s)")
            handlers.seek(position)
            return .success
        }

        register(commandCenter.changeRepeatModeCommand) { event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }

            handlers.setRepeatMode(Self.repeatMode(for: event.repeatType))
            return .success
        }

        register(commandCenter.changeShuffleModeCommand) { event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }

            handlers.setShuffleEnabled(Self.isShuffleEnabled(for: event.shuffleType))
            return .success
        }

        commandCenter.likeCommand.isEnabled = false
        register(commandCenter.likeCommand) { _ in
            handlers.rateLike()
        }

        commandCenter.dislikeCommand.isEnabled = false
        register(commandCenter.dislikeCommand) { _ in
            handlers.rateDislike()
        }
    }

    func updateNowPlayingInfo(
        _ state: PlaybackNowPlayingState,
        systemPlaybackState: PlaybackState? = nil
    ) {
        let publishedPlaybackState: PlaybackState
        switch (systemPlaybackState, latestPlaybackState, state.playbackState) {
        case let (.some(systemPlaybackState), _, _):
            publishedPlaybackState = systemPlaybackState
        case (nil, .playing, .loading), (nil, .playing, .buffering):
            publishedPlaybackState = .playing
        default:
            publishedPlaybackState = state.playbackState
        }
        latestPlaybackState = publishedPlaybackState
        guard let track = state.track else {
            clearNowPlayingInfo()
            updateCommandAvailability(state)
            return
        }

        guard let nowPlayingCenter else { return }

        let nextArtworkRequestKey = Self.artworkRequestKey(for: track)
        let hasArtworkPath = Self.hasArtworkPath(for: track)
        let artworkForMetadata: MPMediaItemArtwork?
        if hasArtworkPath,
           artworkRequestKey == nextArtworkRequestKey,
           let artwork {
            artworkForMetadata = artwork
        } else if hasArtworkPath,
                  let artwork {
            artworkForMetadata = artwork
        } else if hasArtworkPath {
            artworkForMetadata = nil
        } else {
            artworkForMetadata = Self.fallbackArtwork(for: track)
            artwork = artworkForMetadata
        }

        nowPlayingCenter.nowPlayingInfo = Self.makeNowPlayingInfo(
            state: state,
            artwork: artworkForMetadata,
            systemPlaybackState: publishedPlaybackState
        )
        syncNowPlayingPlaybackState(publishedPlaybackState)
        updateCommandAvailability(state)
        updateFeedbackCommandState(isLiked: state.isLiked, isDisliked: state.isDisliked)

        let rate = publishedPlaybackState == .playing ? 1.0 : 0.0
        let effectiveDuration = state.playbackState == .loading ? track.duration : state.duration
        EnsembleLogger.debug("[NowPlaying] Updated: '\(track.title)' rate=\(rate) elapsed=\(String(format: "%.1f", state.currentTime))s duration=\(String(format: "%.1f", effectiveDuration))s state=\(state.playbackState)")

        guard artworkRequestKey != nextArtworkRequestKey else { return }
        cancelArtworkLoad(clearArtwork: false)
        artworkRequestKey = nextArtworkRequestKey

        guard hasArtworkPath else { return }

        artworkTask = Task { [weak self] in
            guard let self else { return }

            guard let image = await self.resolvedArtworkImage(for: track) else {
                EnsembleLogger.debug("[NowPlaying] Artwork unavailable for '\(track.title)'; applying generated fallback")
                await MainActor.run {
                    self.applyFallbackArtwork(for: track, requestKey: nextArtworkRequestKey)
                }
                return
            }

            if Task.isCancelled { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }

            await MainActor.run {
                self.applyArtwork(artwork, for: nextArtworkRequestKey)
            }
        }
    }

    private func resolvedArtworkImage(for track: Track) async -> PlatformArtworkImage? {
        let descriptor = ArtworkResolutionDescriptor(
            track: track,
            size: 600,
            priority: .high
        )

        if let cached = await ArtworkImageResolver.locallyCachedImage(
            for: descriptor,
            artworkLoader: artworkLoader
        ) {
            EnsembleLogger.debug("[NowPlaying] Using cached artwork for '\(track.title)'")
            return cached.image
        }

        guard case .resolved(let resolved) = await ArtworkImageResolver.resolveImage(
            for: descriptor,
            artworkLoader: artworkLoader
        ) else {
            return nil
        }

        return resolved.image
    }

    func pushNowPlayingForSkipTransition(_ state: PlaybackNowPlayingState) {
        updateNowPlayingInfo(state, systemPlaybackState: .playing)
    }

    func clearNowPlayingInfo() {
        cancelArtworkLoad(clearArtwork: true)
        latestPlaybackState = .stopped
        guard let nowPlayingCenter else { return }
        nowPlayingCenter.nowPlayingInfo = nil
        nowPlayingCenter.playbackState = .stopped
        updateFeedbackCommandState(isLiked: false, isDisliked: false)
    }

    func cancelArtworkLoad(clearArtwork: Bool) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestKey = nil
        if clearArtwork {
            artwork = nil
        }
    }

    private func prepareArtworkRetry() {
        guard artworkRequestKey != nil else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestKey = nil
    }

    func updateFeedbackCommandState(isLiked: Bool, isDisliked: Bool) {
        guard let commandCenter else { return }
        commandCenter.likeCommand.isActive = isLiked
        commandCenter.dislikeCommand.isActive = isDisliked
    }

    func updateCommandAvailability(_ state: PlaybackNowPlayingState) {
        guard let commandCenter else { return }
        commandCenter.playCommand.isEnabled = state.canPlay
        commandCenter.pauseCommand.isEnabled = state.canPause
        commandCenter.togglePlayPauseCommand.isEnabled = state.canPlay || state.canPause
        commandCenter.nextTrackCommand.isEnabled = state.canSkipForward
        commandCenter.previousTrackCommand.isEnabled = state.canSkipBackward
        commandCenter.changePlaybackPositionCommand.isEnabled = state.canSeek
        commandCenter.changeShuffleModeCommand.isEnabled = state.canToggleShuffle
        commandCenter.changeRepeatModeCommand.isEnabled = state.canCycleRepeatMode
        commandCenter.likeCommand.isEnabled = state.canLike
        commandCenter.dislikeCommand.isEnabled = state.canDislike
        commandCenter.changeShuffleModeCommand.currentShuffleType = Self.shuffleType(for: state.isShuffleEnabled)
        commandCenter.changeRepeatModeCommand.currentRepeatType = Self.repeatType(for: state.repeatMode)
    }

    static func makeNowPlayingInfo(
        state: PlaybackNowPlayingState,
        artwork: MPMediaItemArtwork?,
        systemPlaybackState: PlaybackState? = nil
    ) -> [String: Any] {
        guard let track = state.track else { return [:] }

        let effectiveDuration = state.playbackState == .loading ? track.duration : state.duration
        let playbackRate = (systemPlaybackState ?? state.playbackState) == .playing ? 1.0 : 0.0
        let sourceScopedTrackID = sourceScopedTrackIdentifier(for: track)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: sourceScopedTrackID,
            MPNowPlayingInfoPropertyServiceIdentifier: "Ensemble"
        ]

        if state.queueCount > 0, state.queueIndex >= 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = state.queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = state.queueCount
        }

        if let artist = track.artistName {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        if track.trackNumber > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = track.trackNumber
        }

        if track.discNumber > 0 {
            info[MPMediaItemPropertyDiscNumber] = track.discNumber
        }

        if let genre = track.genres.first {
            info[MPMediaItemPropertyGenre] = genre
        }

        if let albumRatingKey = track.albumRatingKey {
            info[MPNowPlayingInfoCollectionIdentifier] = SystemMediaReference.sourceScopedIdentifier(
                kind: .album,
                id: albumRatingKey,
                sourceCompositeKey: track.sourceCompositeKey
            )
        }

        if let sourceCompositeKey = track.sourceCompositeKey {
            info[MPNowPlayingInfoPropertyExternalUserProfileIdentifier] = sourceCompositeKey
        }

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        return info
    }

    static func shuffleType(for isEnabled: Bool) -> MPShuffleType {
        isEnabled ? .items : .off
    }

    static func isShuffleEnabled(for shuffleType: MPShuffleType) -> Bool {
        switch shuffleType {
        case .off:
            return false
        case .items, .collections:
            return true
        @unknown default:
            return false
        }
    }

    static func repeatType(for repeatMode: RepeatMode) -> MPRepeatType {
        switch repeatMode {
        case .off:
            return .off
        case .all:
            return .all
        case .one:
            return .one
        }
    }

    static func repeatMode(for repeatType: MPRepeatType) -> RepeatMode {
        switch repeatType {
        case .off:
            return .off
        case .all:
            return .all
        case .one:
            return .one
        @unknown default:
            return .off
        }
    }

    static func shouldRejectRemoteSeekAsStale(
        targetPosition: TimeInterval,
        currentTime: TimeInterval,
        trackAge: TimeInterval,
        eventTimestamp: TimeInterval,
        nowTimestamp: TimeInterval
    ) -> Bool {
        guard trackAge > 0, trackAge < 5 else { return false }
        guard abs(targetPosition - currentTime) > 30 else { return false }
        guard eventTimestamp > 0, nowTimestamp >= eventTimestamp else { return false }

        let eventAge = nowTimestamp - eventTimestamp
        return eventAge > trackAge + 0.25
    }

    private func register(
        _ command: PlaybackRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        commandHandlerTokens.append(RemoteCommandHandlerToken(command: command, token: token))
    }

    private func removeRemoteCommandHandlers() {
        for handlerToken in commandHandlerTokens {
            handlerToken.command.removeTarget(handlerToken.token)
        }
        commandHandlerTokens.removeAll()
    }

    private static func sourceScopedTrackIdentifier(for track: Track) -> String {
        SystemMediaReference.sourceScopedIdentifier(
            kind: .track,
            id: track.id,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }

    private static func artworkRequestKey(for track: Track) -> String {
        let source = track.sourceCompositeKey ?? ""
        if let thumbPath = track.thumbPath, !thumbPath.isEmpty {
            return "\(source)|\(thumbPath)|\(track.fallbackThumbPath ?? "")"
        }
        if let fallbackThumbPath = track.fallbackThumbPath, !fallbackThumbPath.isEmpty {
            return "\(source)|\(fallbackThumbPath)"
        }
        return "\(source)|generated|\(track.id)"
    }

    private static func hasArtworkPath(for track: Track) -> Bool {
        if let thumbPath = track.thumbPath, !thumbPath.isEmpty {
            return true
        }
        if let fallbackThumbPath = track.fallbackThumbPath, !fallbackThumbPath.isEmpty {
            return true
        }
        return false
    }

    private static func fallbackArtwork(for track: Track) -> MPMediaItemArtwork {
        let image = fallbackArtworkImage(for: track)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in
            image
        }
    }

    private static func fallbackArtworkImage(for track: Track) -> PlatformArtworkImage {
        let size = CGSize(width: 600, height: 600)
        let initial = fallbackArtworkInitial(for: track)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            drawFallbackArtworkBackground(in: context.cgContext, size: size)

            let font = UIFont.systemFont(ofSize: 176, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.94),
                .paragraphStyle: paragraph
            ]
            let textSize = initial.size(withAttributes: attributes)
            let rect = CGRect(
                x: 0,
                y: (size.height - textSize.height) / 2 - 12,
                width: size.width,
                height: textSize.height
            )
            initial.draw(in: rect, withAttributes: attributes)
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            drawFallbackArtworkBackground(in: context, size: size)
        }

        let font = NSFont.systemFont(ofSize: 176, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph
        ]
        let textSize = initial.size(withAttributes: attributes)
        let rect = CGRect(
            x: 0,
            y: (size.height - textSize.height) / 2,
            width: size.width,
            height: textSize.height
        )
        initial.draw(in: rect, withAttributes: attributes)
        image.unlockFocus()
        return image
        #endif
    }

    private static func drawFallbackArtworkBackground(in context: CGContext, size: CGSize) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0),
            CGColor(red: 0.23, green: 0.29, blue: 0.38, alpha: 1.0),
            CGColor(red: 0.37, green: 0.20, blue: 0.30, alpha: 1.0)
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.58, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            context.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1.0))
            context.fill(CGRect(origin: .zero, size: size))
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size.width, y: size.height),
            options: []
        )
    }

    private static func fallbackArtworkInitial(for track: Track) -> String {
        let candidates = [track.albumName, track.title]
        for candidate in candidates.compactMap({ $0 }) {
            if let scalar = candidate.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) }) {
                return String(scalar).uppercased()
            }
        }
        return "E"
    }

    private func applyArtwork(
        _ artwork: MPMediaItemArtwork,
        for requestKey: String
    ) {
        guard let nowPlayingCenter,
              var currentInfo = nowPlayingCenter.nowPlayingInfo,
              artworkRequestKey == requestKey else {
            return
        }

        self.artwork = artwork
        currentInfo[MPMediaItemPropertyArtwork] = artwork
        nowPlayingCenter.nowPlayingInfo = currentInfo
        syncNowPlayingPlaybackState(latestPlaybackState)
    }

    private func applyFallbackArtwork(
        for track: Track,
        requestKey: String
    ) {
        guard let nowPlayingCenter,
              var currentInfo = nowPlayingCenter.nowPlayingInfo,
              artworkRequestKey == requestKey else {
            return
        }

        let fallbackArtwork = Self.fallbackArtwork(for: track)
        artwork = fallbackArtwork
        currentInfo[MPMediaItemPropertyArtwork] = fallbackArtwork
        nowPlayingCenter.nowPlayingInfo = currentInfo
        syncNowPlayingPlaybackState(latestPlaybackState)
    }

    private func syncNowPlayingPlaybackState(_ playbackState: PlaybackState) {
        guard let nowPlayingCenter else { return }
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

        nowPlayingCenter.playbackState = mpState
        EnsembleLogger.debug("[NowPlaying] Synced playbackState -> \(mpState.rawValue) (app=\(playbackState))")
    }
}
