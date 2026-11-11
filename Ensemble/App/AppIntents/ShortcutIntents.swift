import AppIntents
import Foundation

// Voice-friendly wrappers. Each takes one enum value, so one App Shortcut covers a family of related actions,
// and calls the same code as the typed editor actions.

// MARK: - Play Collection

enum EnsembleCollection: String, AppEnum {
    case favorites
    case favoritesShuffled
    case libraryShuffled
    case recentlyAdded

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorites: DisplayRepresentation(
            title: "My Favorites",
            synonyms: ["Favorites", "My Favourites", "Favourites", "My Favorite Songs"]
        ),
        .favoritesShuffled: DisplayRepresentation(
            title: "Shuffled Favorites",
            synonyms: ["Shuffle My Favorites", "Shuffle Favorites", "Shuffle My Favourites", "My Favorites Shuffled"]
        ),
        .libraryShuffled: DisplayRepresentation(
            title: "Shuffled Library",
            synonyms: ["Shuffle My Library", "Shuffle My Music", "My Library Shuffled", "Shuffle Everything"]
        ),
        .recentlyAdded: DisplayRepresentation(
            title: "Recently Added",
            synonyms: ["My Recently Added", "Recently Added Music", "New Music", "What I Added Recently"]
        )
    ]
}

struct PlayEnsembleCollectionIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Collection in Ensemble"
    static var description = IntentDescription("Plays your favorites, shuffles your favorites or library, or plays what you added recently.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$collection) in Ensemble") }

    @Parameter(title: "Collection", default: .favorites)
    var collection: EnsembleCollection

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch collection {
        case .favorites: return .result(dialog: try await playFavorites(shuffle: false))
        case .favoritesShuffled: return .result(dialog: try await playFavorites(shuffle: true))
        case .libraryShuffled: return .result(dialog: try await shuffleLibrary())
        case .recentlyAdded: return .result(dialog: try await playRecentlyAdded(shuffle: false))
        }
    }
}

// MARK: - Playback Option

enum EnsemblePlaybackOption: String, AppEnum {
    case shuffleOn
    case shuffleOff
    case repeatOff
    case repeatAll
    case repeatOne
    case autoplayOn
    case autoplayOff
    case smartMixOn
    case smartMixOff

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Option")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffleOn: DisplayRepresentation(title: "Shuffle On", synonyms: ["Shuffle", "Shuffle Music"]),
        .shuffleOff: DisplayRepresentation(title: "Shuffle Off", synonyms: ["Stop Shuffling", "No Shuffle"]),
        .repeatOff: DisplayRepresentation(title: "Repeat Off", synonyms: ["No Repeat", "Stop Repeating"]),
        .repeatAll: DisplayRepresentation(title: "Repeat All", synonyms: ["Repeat Everything", "Repeat the Queue", "Repeat"]),
        .repeatOne: DisplayRepresentation(title: "Repeat One", synonyms: ["Repeat This Song", "Repeat Song", "Repeat the Song"]),
        .autoplayOn: DisplayRepresentation(title: "Autoplay On", synonyms: ["Autoplay"]),
        .autoplayOff: DisplayRepresentation(title: "Autoplay Off", synonyms: ["Stop Autoplay"]),
        .smartMixOn: DisplayRepresentation(title: "SmartMix On", synonyms: ["Smart Mix On", "SmartMix", "Smart Mix"]),
        .smartMixOff: DisplayRepresentation(title: "SmartMix Off", synonyms: ["Smart Mix Off"])
    ]
}

struct SetEnsemblePlaybackOptionIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Playback Option in Ensemble"
    static var description = IntentDescription("Turns shuffle, repeat, Autoplay or SmartMix on or off.")
    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$option) in Ensemble") }

    @Parameter(title: "Option", default: .shuffleOn)
    var option: EnsemblePlaybackOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch option {
        case .shuffleOn: return .result(dialog: await setShuffle(true))
        case .shuffleOff: return .result(dialog: await setShuffle(false))
        case .repeatOff: return .result(dialog: await setRepeat(.off))
        case .repeatAll: return .result(dialog: await setRepeat(.all))
        case .repeatOne: return .result(dialog: await setRepeat(.one))
        case .autoplayOn: return .result(dialog: await setAutoplay(true))
        case .autoplayOff: return .result(dialog: await setAutoplay(false))
        case .smartMixOn: return .result(dialog: await setSmartMix(true))
        case .smartMixOff: return .result(dialog: await setSmartMix(false))
        }
    }
}

// MARK: - This Song

enum EnsembleSongAction: String, AppEnum {
    case favorite
    case unfavorite
    case startRadio

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song Action")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorite: DisplayRepresentation(title: "Favorite", synonyms: ["Like", "Love", "Heart"]),
        .unfavorite: DisplayRepresentation(title: "Unfavorite", synonyms: ["Unlike", "Unlove", "Remove from favorites"]),
        .startRadio: DisplayRepresentation(title: "Start Radio from", synonyms: ["Play Radio from", "Start a Radio from"])
    ]
}

struct EnsembleSongActionIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "This Song in Ensemble"
    static var description = IntentDescription("Favorites or unfavorites the song that is playing, or starts a radio from it.")
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) this song in Ensemble") }

    @Parameter(title: "Action", default: .favorite)
    var action: EnsembleSongAction

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch action {
        case .favorite: return .result(dialog: try await setCurrentSongFavorite(true))
        case .unfavorite: return .result(dialog: try await setCurrentSongFavorite(false))
        case .startRadio: return .result(dialog: try await startRadio(from: nil))
        }
    }
}
