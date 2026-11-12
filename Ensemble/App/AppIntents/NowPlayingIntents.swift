import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation

// Each intent calls the service method the app's own control calls.

// MARK: - Shared actions

/// The view model the interactive UI uses for favorites and playlist adds. A process started only for an
/// intent has no scene, so it gets its own, as the Mac Dock menu does.
@MainActor
private func nowPlayingViewModel(for container: DependencyContainer) -> NowPlayingViewModel {
    container.activeNowPlayingViewModel ?? NowPlayingViewModel(dependencies: container)
}

@MainActor
func setCurrentSongFavorite(_ favorite: Bool) async throws -> IntentDialog {
    let container = try await readyContainer()
    let track = try await currentTrackOrThrow()
    if track.isAppleMusic {
        guard favorite else { throw EnsembleIntentError.appleMusicUnfavorite }
        if container.syncCoordinator.isOffline { throw EnsembleIntentError.offline }
    }
    guard await nowPlayingViewModel(for: container).setTrackFavorite(favorite, for: track) else {
        throw EnsembleIntentError.favoriteFailed
    }
    return favorite
        ? IntentDialog("Favorited \(track.title).")
        : IntentDialog("Removed \(track.title) from your favorites.")
}

@MainActor
func add(_ tracks: [Track], to playlist: EnsemblePlaylistEntity) async throws -> IntentDialog {
    let container = try await readyContainer()
    return try await reportingFailures {
        guard let stored = try await container.playlistRepository.fetchPlaylist(
            ratingKey: playlist.item.id,
            sourceCompositeKey: playlist.item.sourceCompositeKey
        ) else {
            throw EnsembleIntentError.playlistNotFound
        }
        // A merged group takes the song on its own server, as the Add to Playlist sheet does.
        guard let target = try await container.siriPlaybackCoordinator.addTarget(for: Playlist(from: stored), tracks: tracks) else {
            throw EnsembleIntentError.differentSources
        }
        // Playlists take only tracks from their own server, so name that cause rather than "no compatible tracks".
        if !tracks.isEmpty,
           PlaylistActionService().tracks(tracks, compatibleWithServerSourceKey: target.sourceCompositeKey).isEmpty {
            throw EnsembleIntentError.differentSources
        }
        let outcome = try await nowPlayingViewModel(for: container)
            .addTracksOptimistically(tracks, to: target)
        // The optimistic path filters incompatible and duplicate tracks and reports only the outcome, so the
        // dialog does not claim a count.
        return outcome == .queued
            ? IntentDialog("Will be added to \(playlist.title) when you're back online.")
            : IntentDialog("Added to \(playlist.title).")
    }
}

/// Applies a playback mode, then reports the mode the player holds afterwards rather than the one requested.
@MainActor
func setShuffle(_ enabled: Bool) async -> IntentDialog {
    let playback = intentContainer.playbackService
    playback.setShuffleEnabled(enabled)
    await Task.yield()
    return playback.isShuffleEnabled ? IntentDialog("Shuffle is on.") : IntentDialog("Shuffle is off.")
}

@MainActor
func setRepeat(_ setting: EnsembleRepeatSetting) async -> IntentDialog {
    let playback = intentContainer.playbackService
    playback.setRepeatMode(setting.mode)
    await Task.yield()
    let actual = EnsembleRepeatSetting(playback.repeatMode)
    if actual != setting {
        AppIntentsLog.logger.error(
            "SIRI_SHORTCUT: repeat requested=\(setting.rawValue, privacy: .public) actual=\(actual.rawValue, privacy: .public)"
        )
    }
    return IntentDialog("Repeat is set to \(actual.rawValue).")
}

@MainActor
func setAutoplay(_ enabled: Bool) async throws -> IntentDialog {
    let playback = intentContainer.playbackService
    if playback.isAutoplayEnabled != enabled {
        // Turning Autoplay on requests recommendations from a provider; turning it off only edits the queue.
        if enabled { _ = try await readyContainer() }
        playback.toggleAutoplay()
    }
    await Task.yield()
    return playback.isAutoplayEnabled ? IntentDialog("Autoplay is on.") : IntentDialog("Autoplay is off.")
}

@MainActor
func setSmartMix(_ enabled: Bool) async throws -> IntentDialog {
    let playback = intentContainer.playbackService
    // A change re-prefetches the next item, which can resolve a stream.
    if playback.isSmartMixEnabled != enabled { _ = try await readyContainer() }
    playback.setSmartMixEnabled(enabled)
    await Task.yield()
    return playback.isSmartMixEnabled ? IntentDialog("SmartMix is on.") : IntentDialog("SmartMix is off.")
}

/// "playing" or "paused", as the player reports it now.
@MainActor
private var playbackStatus: String {
    switch intentContainer.playbackService.playbackState {
    case .playing, .buffering, .loading: return "playing"
    case .paused, .stopped: return "paused"
    case .failed: return "stopped after an error"
    }
}

/// Polls briefly for the player to reach a state, so a dialog can report the outcome rather than the request.
@MainActor
private func playbackReaches(_ condition: () -> Bool, within timeout: Duration = .seconds(1)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return condition() }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

// MARK: - What is playing

struct GetCurrentEnsembleSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Song in Ensemble"
    static var description = IntentDescription("Returns the song Ensemble is playing, for use in other actions.")
    static var parameterSummary: some ParameterSummary { Summary("Get the current Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EnsembleTrackEntity> & ProvidesDialog {
        let song = EnsembleTrackEntity(item: SiriMediaIndexItem(track: try await currentTrackOrThrow()))
        return .result(value: song, dialog: IntentDialog("\(song.title) is current. Ensemble is \(playbackStatus)."))
    }
}

struct FavoriteCurrentEnsembleSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Favorite Current Song in Ensemble"
    static var description = IntentDescription("Favorites or unfavorites the song Ensemble is playing.")
    static var parameterSummary: some ParameterSummary { Summary("Set the current Ensemble song as favorite: \(\.$favorite)") }

    @Parameter(title: "Favorite", default: true)
    var favorite: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await setCurrentSongFavorite(favorite))
    }
}

struct AddCurrentSongToEnsemblePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Current Song to Playlist in Ensemble"
    static var description = IntentDescription("Adds the song Ensemble is playing to a playlist.")
    static var parameterSummary: some ParameterSummary { Summary("Add the current Ensemble song to \(\.$playlist)") }

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await add([try await currentTrackOrThrow()], to: playlist))
    }
}

struct AddToEnsemblePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Playlist in Ensemble"
    static var description = IntentDescription("Adds a song, album or other library item to a playlist.")
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$media) to \(\.$playlist) in Ensemble") }

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinator = try await readyContainer().siriPlaybackCoordinator
        let tracks = try await reportingFailures {
            try await coordinator.resolveTracks(kind: media.item.kind, request: media.playbackRequest())
        }
        return .result(dialog: try await add(tracks, to: playlist))
    }
}

// MARK: - Queue

extension EnsembleMediaEntity {
    @MainActor
    func enqueue(playNext: Bool) async throws -> IntentDialog {
        let coordinator = try await readyContainer().siriPlaybackCoordinator
        _ = try await reportingFailures {
            try await coordinator.enqueue(kind: item.kind, request: playbackRequest(), playNext: playNext)
        }
        return playNext
            ? IntentDialog("\(title) will play next.")
            : IntentDialog("Added \(title) to the end of the queue.")
    }
}

struct PlayEnsembleMediaNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Next in Ensemble"
    static var description = IntentDescription("Adds a song, album, artist or playlist right after the current song.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$media) next in Ensemble") }

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await media.enqueue(playNext: true))
    }
}

struct PlayEnsembleMediaLastIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Last in Ensemble"
    static var description = IntentDescription("Adds a song, album, artist or playlist to the end of the queue.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$media) last in Ensemble") }

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await media.enqueue(playNext: false))
    }
}

// MARK: - Playback modes

enum EnsembleRepeatSetting: String, AppEnum {
    case off
    case all
    case one

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repeat")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .all: "All",
        .one: "One"
    ]

    init(_ mode: RepeatMode) {
        switch mode {
        case .off: self = .off
        case .all: self = .all
        case .one: self = .one
        }
    }

    var mode: RepeatMode {
        switch self {
        case .off: return .off
        case .all: return .all
        case .one: return .one
        }
    }
}

struct SetEnsembleShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Shuffle in Ensemble"
    static var description = IntentDescription("Turns shuffle on or off for the current queue.")
    static var parameterSummary: some ParameterSummary { Summary("Set Ensemble shuffle to \(\.$enabled)") }

    @Parameter(title: "Shuffle", default: true)
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await setShuffle(enabled))
    }
}

struct SetEnsembleRepeatIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Repeat in Ensemble"
    static var description = IntentDescription("Sets repeat to off, all or one.")
    static var parameterSummary: some ParameterSummary { Summary("Set Ensemble repeat to \(\.$setting)") }

    @Parameter(title: "Repeat", default: .off)
    var setting: EnsembleRepeatSetting

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: await setRepeat(setting))
    }
}

struct SetEnsembleAutoplayIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Autoplay in Ensemble"
    static var description = IntentDescription("Turns Autoplay on or off. Autoplay adds similar tracks when the queue ends.")
    static var parameterSummary: some ParameterSummary { Summary("Set Ensemble autoplay to \(\.$enabled)") }

    @Parameter(title: "Autoplay", default: true)
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await setAutoplay(enabled))
    }
}

struct SetEnsembleSmartMixIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set SmartMix in Ensemble"
    static var description = IntentDescription("Turns SmartMix on or off. SmartMix blends the end of a song into the next.")
    static var parameterSummary: some ParameterSummary { Summary("Set Ensemble SmartMix to \(\.$enabled)") }

    @Parameter(title: "SmartMix", default: true)
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await setSmartMix(enabled))
    }
}

// MARK: - Transport

struct TogglePlayPauseEnsembleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause Ensemble"
    static var description = IntentDescription("Pauses Ensemble when it is playing and resumes it when it is not.")
    static var parameterSummary: some ParameterSummary { Summary("Play or pause Ensemble") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = intentContainer.playbackService
        _ = try await currentTrackOrThrow()
        switch playback.playbackState {
        case .playing, .buffering, .loading:
            playback.pause()
            return .result(dialog: playback.playbackState == .paused
                ? IntentDialog("Paused.")
                : IntentDialog("Asked Ensemble to pause."))
        case .failed:
            _ = try await readyContainer()
            await playback.retryCurrentTrack()
        case .paused, .stopped:
            _ = try await readyContainer()
            playback.resume()
        }
        let started = await playbackReaches {
            switch playback.playbackState {
            case .playing, .buffering, .loading: return true
            default: return false
            }
        }
        if case let .failed(message) = playback.playbackState { throw EnsembleIntentError.failed(message) }
        return .result(dialog: started ? IntentDialog("Playing.") : IntentDialog("Asked Ensemble to resume."))
    }
}

struct NextEnsembleSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Song in Ensemble"
    static var description = IntentDescription("Skips to the next song in the queue.")
    static var parameterSummary: some ParameterSummary { Summary("Skip to the next Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await currentTrackOrThrow()
        _ = try await readyContainer()
        let playback = intentContainer.playbackService
        let before = QueuePosition(playback)
        let titleBefore = playback.currentTrack?.title ?? "this song"
        playback.next()
        let moved = await playbackReaches { QueuePosition(playback).item != before.item || QueuePosition(playback).index != before.index }
        if moved, let now = playback.currentTrack { return .result(dialog: IntentDialog("Skipped to \(now.title).")) }
        // Only the queue's shape can say there is nothing next; a slow transition says nothing.
        if before.isLast, playback.repeatMode == .off, !playback.isAutoplayEnabled {
            return .result(dialog: IntentDialog("There is no next song, so Ensemble stayed on \(titleBefore)."))
        }
        return .result(dialog: IntentDialog("Asked Ensemble to skip."))
    }
}

/// Where the queue is: the entry (not the track, which can repeat), its index and the playback position.
@MainActor
private struct QueuePosition {
    let item: String?
    let index: Int
    let isLast: Bool
    let time: TimeInterval

    init(_ playback: PlaybackService) {
        let queue = playback.queue
        index = playback.currentQueueIndex
        item = queue.indices.contains(index) ? queue[index].id : nil
        isLast = index >= queue.count - 1
        time = playback.currentTimeValue
    }
}

struct PreviousEnsembleSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Song in Ensemble"
    static var description = IntentDescription("Returns to the start of the song, or to the previous song.")
    static var parameterSummary: some ParameterSummary { Summary("Go back to the previous Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await currentTrackOrThrow()
        _ = try await readyContainer()
        let playback = intentContainer.playbackService
        let before = QueuePosition(playback)
        let titleBefore = playback.currentTrack?.title ?? "this song"
        playback.previous()
        // Previous restarts the song when it has played a while, so an unchanged entry can be a valid outcome.
        let changed = await playbackReaches {
            let now = QueuePosition(playback)
            return now.item != before.item || now.index != before.index || now.time < before.time
        }
        guard changed, let now = playback.currentTrack else {
            return .result(dialog: IntentDialog("Asked Ensemble to go back."))
        }
        let after = QueuePosition(playback)
        if after.item == before.item, after.index == before.index {
            return .result(dialog: IntentDialog("Went back to the start of \(titleBefore)."))
        }
        return .result(dialog: IntentDialog("Went back to \(now.title)."))
    }
}
