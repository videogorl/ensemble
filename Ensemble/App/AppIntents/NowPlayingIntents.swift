import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation

// Each intent calls the service method the app's own control calls.

// MARK: - What is playing

struct GetCurrentEnsembleSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Song in Ensemble"
    static var description = IntentDescription("Returns the song Ensemble is playing, for use in other actions.")
    static var parameterSummary: some ParameterSummary { Summary("Get the current Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EnsembleTrackEntity> & ProvidesDialog {
        let song = EnsembleTrackEntity(item: SiriMediaIndexItem(track: try currentTrackOrThrow()))
        return .result(value: song, dialog: IntentDialog("Ensemble is playing \(song.title)."))
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
        let track = try currentTrackOrThrow()
        try await intentContainer.siriAffinityCoordinator.execute(
            payload: SiriAffinityRequestPayload(affinityType: favorite ? .love : .remove)
        )
        return .result(dialog: favorite
            ? IntentDialog("Favorited \(track.title).")
            : IntentDialog("Removed \(track.title) from your favorites."))
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
        let track = try currentTrackOrThrow()
        try await intentContainer.siriAddToPlaylistCoordinator.execute(payload: SiriAddToPlaylistRequestPayload(
            playlistRatingKey: playlist.item.id,
            sourceCompositeKey: playlist.item.sourceCompositeKey,
            playlistDisplayName: playlist.title
        ))
        return .result(dialog: IntentDialog("Adding \(track.title) to \(playlist.title)."))
    }
}

// MARK: - Queue

extension EnsembleMediaEntity {
    @MainActor
    func enqueue(playNext: Bool) async throws -> IntentDialog {
        try await intentContainer.siriPlaybackCoordinator.enqueue(
            kind: item.kind,
            request: playbackRequest(),
            playNext: playNext
        )
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
        intentContainer.playbackService.setShuffleEnabled(enabled)
        return .result(dialog: enabled ? IntentDialog("Shuffle is on.") : IntentDialog("Shuffle is off."))
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
        intentContainer.playbackService.setRepeatMode(setting.mode)
        return .result(dialog: IntentDialog("Repeat is set to \(setting.rawValue)."))
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
        let playback = intentContainer.playbackService
        if playback.isAutoplayEnabled != enabled {
            playback.toggleAutoplay()
        }
        return .result(dialog: enabled ? IntentDialog("Autoplay is on.") : IntentDialog("Autoplay is off."))
    }
}

// MARK: - Transport

struct TogglePlayPauseEnsembleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause Ensemble"
    static var description = IntentDescription("Pauses Ensemble when it is playing and resumes it when it is not.")
    static var parameterSummary: some ParameterSummary { Summary("Play or pause Ensemble") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let playback = intentContainer.playbackService
        _ = try currentTrackOrThrow()
        switch playback.playbackState {
        case .playing, .buffering, .loading:
            playback.pause()
        case .failed:
            await playback.retryCurrentTrack()
        case .paused, .stopped:
            playback.resume()
        }
        return .result()
    }
}

struct NextEnsembleSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Song in Ensemble"
    static var description = IntentDescription("Skips to the next song in the queue.")
    static var parameterSummary: some ParameterSummary { Summary("Skip to the next Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try currentTrackOrThrow()
        intentContainer.playbackService.next()
        return .result()
    }
}

struct PreviousEnsembleSongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Song in Ensemble"
    static var description = IntentDescription("Returns to the start of the song, or to the previous song.")
    static var parameterSummary: some ParameterSummary { Summary("Go back to the previous Ensemble song") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try currentTrackOrThrow()
        intentContainer.playbackService.previous()
        return .result()
    }
}
