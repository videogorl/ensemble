import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation

// MARK: - Shared support

enum EnsembleIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying: return "Nothing is playing in Ensemble."
        }
    }
}

/// The app's dependency container, with accounts loaded for an intent that runs before any scene has.
@MainActor
var intentContainer: DependencyContainer {
    let container = AppRoot.container
    if container.accountManager.credentialLoadState == .loading, container.accountManager.plexAccounts.isEmpty {
        container.accountManager.loadAccounts()
    }
    return container
}

@MainActor
func currentTrackOrThrow() throws -> Track {
    guard let track = intentContainer.playbackService.currentTrack else {
        throw EnsembleIntentError.nothingPlaying
    }
    return track
}

extension IndexItemEntity {
    /// Plays this item, or shuffles it, through the same coordinator Siri uses.
    @MainActor
    func play(shuffle: Bool) async throws -> IntentDialog {
        AppIntentsLog.logger.info(
            "SIRI_SHORTCUT: perform \(item.kind.rawValue, privacy: .public) shuffle=\(shuffle, privacy: .public) title='\(item.displayName, privacy: .private)' id='\(id, privacy: .private)'"
        )
        let request = playbackRequest(shuffle: shuffle)
        try await intentContainer.siriPlaybackCoordinator.execute(payload: SiriPlaybackRequestPayload(
            kind: item.kind,
            entityID: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey,
            displayName: request.displayName,
            shuffle: shuffle
        ))
        return shuffle
            ? IntentDialog("Shuffling \(title) in Ensemble.")
            : IntentDialog("Playing \(title) in Ensemble.")
    }
}

// MARK: - Play a library item

/// AppIntent fallback for track playback when SiriKit media-domain routing misses the app.
struct PlayEnsembleTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Track in Ensemble"
    static var description = IntentDescription("Plays a specific track from your Ensemble library.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$track)") }

    @Parameter(title: "Track")
    var track: EnsembleTrackEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await track.play(shuffle: false))
    }
}

struct PlayEnsembleAlbumIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Album in Ensemble"
    static var description = IntentDescription("Plays a specific album from your Ensemble library, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$album)") { \.$shuffle } }

    @Parameter(title: "Album")
    var album: EnsembleAlbumEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await album.play(shuffle: shuffle))
    }
}

struct PlayEnsembleArtistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Artist in Ensemble"
    static var description = IntentDescription("Plays music by a specific artist from your Ensemble library, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$artist)") { \.$shuffle } }

    @Parameter(title: "Artist")
    var artist: EnsembleArtistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await artist.play(shuffle: shuffle))
    }
}

struct PlayEnsemblePlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Playlist in Ensemble"
    static var description = IntentDescription("Plays a specific playlist from your Ensemble library, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") { \.$shuffle } }

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await playlist.play(shuffle: shuffle))
    }
}

// MARK: - Retired Shuffle intents

// Shortcuts saved before Shuffle became an option on Play still run these. They are hidden from the editor.

struct ShuffleEnsembleArtistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Artist in Ensemble"
    static var description = IntentDescription("Shuffles music by a specific artist from your Ensemble library.")
    static var isDiscoverable: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Shuffle the artist \(\.$artistName)") }

    @Parameter(title: "Artist")
    var artistName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = SiriIndexLookup.findItems(kind: .artist, matching: artistName, limit: 3).first else {
            return .result(dialog: IntentDialog("I couldn't find \(artistName) in Ensemble."))
        }
        return .result(dialog: try await EnsembleArtistEntity(item: item).play(shuffle: true))
    }
}

struct ShuffleEnsemblePlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Playlist in Ensemble"
    static var description = IntentDescription("Shuffles a specific playlist from your Ensemble library.")
    static var isDiscoverable: Bool = false
    static var parameterSummary: some ParameterSummary { Summary("Shuffle \(\.$playlist)") }

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await playlist.play(shuffle: true))
    }
}

// MARK: - Library-wide playback

struct ShuffleEnsembleLibraryIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Library in Ensemble"
    static var description = IntentDescription("Shuffles every song in your enabled Ensemble libraries.")
    static var parameterSummary: some ParameterSummary { Summary("Shuffle my Ensemble library") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await intentContainer.siriPlaybackCoordinator.playLibrary(shuffle: true)
        return .result(dialog: IntentDialog("Shuffling your Ensemble library."))
    }
}

struct PlayEnsembleFavoritesIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Favorites in Ensemble"
    static var description = IntentDescription("Plays the songs you have favorited in Ensemble, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play my Ensemble favorites") { \.$shuffle } }

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await intentContainer.siriPlaybackCoordinator.playFavorites(shuffle: shuffle)
        return .result(dialog: IntentDialog(shuffle ? "Shuffling your favorites." : "Playing your favorites."))
    }
}

struct StartEnsembleTrackRadioIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start Track Radio in Ensemble"
    static var description = IntentDescription(
        "Plays a song and keeps adding similar tracks. Without a song, turns Autoplay on for what is playing."
    )
    static var parameterSummary: some ParameterSummary { Summary("Start a radio from \(\.$song)") }

    @Parameter(title: "Song")
    var song: EnsembleTrackEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = intentContainer
        if let song {
            try await container.siriPlaybackCoordinator.startTrackRadio(request: song.playbackRequest())
            return .result(dialog: IntentDialog("Starting a radio from \(song.title)."))
        }
        let track = try currentTrackOrThrow()
        if !container.playbackService.isAutoplayEnabled {
            container.playbackService.toggleAutoplay()
        }
        return .result(dialog: IntentDialog("Starting a radio from \(track.title)."))
    }
}
