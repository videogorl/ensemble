import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation

// MARK: - Shared support

/// Expected failures, with messages Shortcuts can show.
enum EnsembleIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingPlaying
    case playlistNotFound
    case readOnlyPlaylist
    case incompatibleSource
    case differentSources
    case appleMusicUnfavorite
    case offline
    case favoriteFailed
    case credentialsUnavailable
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingPlaying: return "Nothing is playing in Ensemble."
        case .playlistNotFound: return "That playlist could not be found."
        case .readOnlyPlaylist: return "That playlist can't be changed. Smart playlists are read-only."
        case .differentSources: return "The song and the playlist are on different music sources, so it can't be added. Pick a playlist on the same server as the song."
        case .incompatibleSource: return "That song and playlist come from music sources that can't be combined."
        case .appleMusicUnfavorite: return "Apple Music favorites can't be removed from Ensemble."
        case .offline: return "That isn't available while you're offline."
        case .favoriteFailed: return "Ensemble couldn't update the favorite."
        case .credentialsUnavailable: return "Ensemble couldn't read your accounts. Open Ensemble and try again."
        case let .failed(message): return "\(message)"
        }
    }

    init(_ error: Error) {
        switch error {
        case let error as EnsembleIntentError:
            self = error
        case let error as PlaylistMutationError:
            switch error {
            case .playlistNotFound: self = .playlistNotFound
            case .smartPlaylistReadOnly: self = .readOnlyPlaylist
            case .invalidSource, .incompletePlaylistContents: self = .incompatibleSource
            default: self = .failed(error.localizedDescription)
            }
        case is MusicSourceRoutingError:
            self = .incompatibleSource
        case is MutationError:
            self = .offline
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost:
            self = .offline
        default:
            self = .failed(error.localizedDescription)
        }
    }
}

/// Runs an action and reports any failure as an `EnsembleIntentError`.
func reportingFailures<Result>(_ action: () async throws -> Result) async throws -> Result {
    do {
        return try await action()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw EnsembleIntentError(error)
    }
}

/// The container for an intent that only changes playback state that already exists.
@MainActor
var intentContainer: DependencyContainer { AppRoot.container }

/// The container for an intent that starts playback or reaches a music source. A process started only for the
/// intent has no scene to warm it up, so this awaits what a launched scene would have prepared.
@MainActor
func readyContainer() async throws -> DependencyContainer {
    try await prepareForBackgroundPlayback(origin: "intent")
    return AppRoot.container
}

/// The current song. A cold-started intent process may not have read the saved queue yet, so this waits for that first.
@MainActor
func currentTrackOrThrow() async throws -> Track {
    let playback = intentContainer.playbackService
    if playback.currentTrack == nil {
        // Restoring resolves the saved track through its source, which needs the accounts.
        if intentContainer.accountManager.credentialLoadState != .loaded {
            await intentContainer.accountManager.loadAccountsAsync()
        }
        try await playback.waitForStartupRestoration(timeout: .seconds(5))
    }
    guard let track = playback.currentTrack else {
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
        let coordinator = try await readyContainer().siriPlaybackCoordinator
        try await reportingFailures {
            try await coordinator.execute(payload: SiriPlaybackRequestPayload(
                kind: item.kind,
                entityID: request.entityID,
                sourceCompositeKey: request.sourceCompositeKey,
                displayName: request.displayName,
                shuffle: shuffle
            ))
        }
        return shuffle
            ? IntentDialog("Shuffling \(title) in Ensemble.")
            : IntentDialog("Playing \(title) in Ensemble.")
    }
}

// MARK: - Library collections

@MainActor
func playFavorites(shuffle: Bool) async throws -> IntentDialog {
    let coordinator = try await readyContainer().siriPlaybackCoordinator
    try await reportingFailures { try await coordinator.playFavorites(shuffle: shuffle) }
    return IntentDialog(shuffle ? "Shuffling your favorites." : "Playing your favorites.")
}

@MainActor
func shuffleLibrary() async throws -> IntentDialog {
    let coordinator = try await readyContainer().siriPlaybackCoordinator
    try await reportingFailures { try await coordinator.playLibrary(shuffle: true) }
    return IntentDialog("Shuffling your Ensemble library.")
}

@MainActor
func playRecentlyAdded(shuffle: Bool) async throws -> IntentDialog {
    let container = try await readyContainer()
    try await reportingFailures {
        let tracks = try await container.libraryCollectionTracks.recentlyAddedTracks()
        try await container.siriPlaybackCoordinator.playCollection(tracks, name: "Recently Added", shuffle: shuffle)
    }
    return IntentDialog(shuffle ? "Shuffling what you added recently." : "Playing what you added recently.")
}

@MainActor
func startRadio(from song: EnsembleTrackEntity?) async throws -> IntentDialog {
    let container = try await readyContainer()
    if let song {
        try await reportingFailures {
            try await container.siriPlaybackCoordinator.startTrackRadio(request: song.playbackRequest())
        }
        return IntentDialog("Starting a radio from \(song.title).")
    }
    let track = try await currentTrackOrThrow()
    if !container.playbackService.isAutoplayEnabled {
        container.playbackService.toggleAutoplay()
    }
    return IntentDialog("Starting a radio from \(track.title).")
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
        guard let item = await SiriIndexLookup.findItems(kind: .artist, matching: artistName, limit: 3).first else {
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
    // Replaced by Play Collection; kept so saved shortcuts still run.
    static var isDiscoverable: Bool = false
    static var description = IntentDescription("Shuffles every song in your enabled Ensemble libraries.")
    static var parameterSummary: some ParameterSummary { Summary("Shuffle my Ensemble library") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await shuffleLibrary())
    }
}

struct PlayEnsembleFavoritesIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Favorites in Ensemble"
    // Replaced by Play Collection; kept so saved shortcuts still run.
    static var isDiscoverable: Bool = false
    static var description = IntentDescription("Plays the songs you have favorited in Ensemble, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play my Ensemble favorites") { \.$shuffle } }

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await playFavorites(shuffle: shuffle))
    }
}

struct PlayEnsembleRecentlyAddedIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Recently Added in Ensemble"
    static var description = IntentDescription("Plays the albums most recently added to your Ensemble libraries.")
    static var parameterSummary: some ParameterSummary { Summary("Play what I added recently to Ensemble") { \.$shuffle } }

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: try await playRecentlyAdded(shuffle: shuffle))
    }
}

struct PlayEnsembleMoodIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Mood in Ensemble"
    static var description = IntentDescription("Plays the songs your Plex libraries list under a mood, in order or shuffled.")
    static var parameterSummary: some ParameterSummary { Summary("Play the mood \(\.$mood)") { \.$shuffle } }

    @Parameter(title: "Mood")
    var mood: EnsembleMoodEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try await readyContainer()
        try await reportingFailures {
            let tracks = await container.libraryCollectionTracks.tracks(for: mood.mood)
            // A cancelled load returns what it had so far; that must not replace the queue.
            try Task.checkCancellation()
            try await container.siriPlaybackCoordinator.playCollection(tracks, name: "Mood", shuffle: shuffle)
        }
        return .result(dialog: shuffle
            ? IntentDialog("Shuffling \(mood.mood.title) in Ensemble.")
            : IntentDialog("Playing \(mood.mood.title) in Ensemble."))
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
        .result(dialog: try await startRadio(from: song))
    }
}
