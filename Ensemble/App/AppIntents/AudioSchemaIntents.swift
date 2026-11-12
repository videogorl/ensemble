import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation
import MediaIntents

// Siri AI audio schemas (iOS and macOS 27). Siri AI routes audio requests to these instead of resolving them itself.
// They are thin: entities are built from the same index items, and every action calls the code the existing
// intents call.

// The type names and identifiers of the entities saved shortcuts use are not touched: these are separate types, since
// an entity adopts one schema and the existing ones are available from iOS 17.

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.song)
struct EnsembleSongAudioEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .track
    static var defaultQuery = EnsembleSongAudioEntityQuery()
    let item: SiriMediaIndexItem
    var title: String
    var artistName: String
    var artists: [EnsembleArtistAudioEntity]
    var album: EnsembleAlbumAudioEntity?
    var albumTitle: String?
    var composerName: String?
    var composers: [EnsembleArtistAudioEntity]
    var internationalStandardRecordingCode: String?

    init(item: SiriMediaIndexItem) {
        self.item = item
        title = item.displayName
        artistName = item.artistName ?? item.secondaryText ?? ""
        artists = []
        albumTitle = item.albumTitle
        composers = []
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct EnsembleSongAudioEntityQuery: AudioSchemaEntityQuery { typealias Entity = EnsembleSongAudioEntity }

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.album)
struct EnsembleAlbumAudioEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .album
    static var defaultQuery = EnsembleAlbumAudioEntityQuery()
    let item: SiriMediaIndexItem
    var title: String
    var artistName: String
    var artists: [EnsembleArtistAudioEntity]
    var universalProductCode: String?

    init(item: SiriMediaIndexItem) {
        self.item = item
        title = item.displayName
        artistName = item.artistName ?? item.secondaryText ?? ""
        artists = []
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct EnsembleAlbumAudioEntityQuery: AudioSchemaEntityQuery { typealias Entity = EnsembleAlbumAudioEntity }

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct EnsembleArtistAudioEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .artist
    static var defaultQuery = EnsembleArtistAudioEntityQuery()
    let item: SiriMediaIndexItem
    var name: String

    init(item: SiriMediaIndexItem) {
        self.item = item
        name = item.displayName
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct EnsembleArtistAudioEntityQuery: AudioSchemaEntityQuery { typealias Entity = EnsembleArtistAudioEntity }

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum EnsembleAudioOwner {
    case person(IntentPerson)
    case name(String)
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct EnsemblePlaylistAudioEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .playlist
    static var defaultQuery = EnsemblePlaylistAudioEntityQuery()
    let item: SiriMediaIndexItem
    var title: String
    var owner: EnsembleAudioOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    init(item: SiriMediaIndexItem) {
        self.item = item
        title = item.displayName
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct EnsemblePlaylistAudioEntityQuery: AudioSchemaEntityQuery { typealias Entity = EnsemblePlaylistAudioEntity }

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum EnsembleAudioItem {
    case song(EnsembleSongAudioEntity)
    case album(EnsembleAlbumAudioEntity)
    case artist(EnsembleArtistAudioEntity)
    case playlist(EnsemblePlaylistAudioEntity)

    var item: SiriMediaIndexItem {
        switch self {
        case let .song(entity): return entity.item
        case let .album(entity): return entity.item
        case let .artist(entity): return entity.item
        case let .playlist(entity): return entity.item
        }
    }
}

// MARK: - Search

/// The queries Siri AI uses. Saved shortcuts keep resolving what they saved (a hidden playlist's shortcut still
/// resolves so running it can refuse); Siri AI is only ever given what the library shows now, so every result, however
/// it was found, passes today's source visibility and hidden-media rules (the cached index is stale until it rebuilds
/// after a change), then today's merge presentation.
@available(iOS 27.0, macOS 27.0, *)
protocol AudioSchemaEntityQuery: IndexItemEntityQuery {}

@available(iOS 27.0, macOS 27.0, *)
extension AudioSchemaEntityQuery {
    private func currentlyVisible(_ items: [SiriMediaIndexItem]) async -> [SiriMediaIndexItem] {
        let container = await MainActor.run { AppRoot.container }
        return await container.siriPlaybackCoordinator.currentlyVisible(items)
    }

    private func current(_ items: [SiriMediaIndexItem]) async -> [Entity] {
        await currentlyVisible(items).map(Entity.init(item:))
    }

    func entities(for identifiers: [Entity.ID]) async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }
        var items = SiriIndexLookup.fetchItems(kind: Entity.indexKind).filter { wanted.contains(Entity.init(item: $0).id) }
        let missing = wanted.subtracting(items.map { Entity.init(item: $0).id }).compactMap(Entity.storedReference(in:))
        if !missing.isEmpty { items += await SiriIndexLookup.storedItems(forReferences: missing) }
        // Presented after the check, so a merged playlist stands for a copy that is still shown.
        return await SiriIndexLookup.presenting(await currentlyVisible(items)).map(Entity.init(item:))
    }

    func entities(matching string: String) async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        return await current(await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: string))
    }

    func suggestedEntities() async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        return await current(await SiriIndexLookup.recentItems(kind: Entity.indexKind))
    }

    /// What Siri's audio search finds, with the existing matcher.
    func audioSearchResults(_ search: AudioSearch) async -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        let items: [SiriMediaIndexItem]
        switch search.criteria {
        case let .searchQuery(query):
            items = await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: query)
        case .unspecified:
            items = await SiriIndexLookup.recentItems(kind: Entity.indexKind)
        case .url:
            // Siri-supplied URLs are not Ensemble links; nothing to resolve.
            items = []
        @unknown default:
            items = []
        }
        let results = await current(items)
        AppIntentsLog.logger.info(
            "SIRI_AI: audio search kind=\(Entity.indexKind?.rawValue ?? "any", privacy: .public) results=\(results.count, privacy: .public)"
        )
        return results
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EnsembleSongAudioEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [EnsembleSongAudioEntity] { await audioSearchResults(search) }
}

@available(iOS 27.0, macOS 27.0, *)
extension EnsembleAlbumAudioEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [EnsembleAlbumAudioEntity] { await audioSearchResults(search) }
}

@available(iOS 27.0, macOS 27.0, *)
extension EnsembleArtistAudioEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [EnsembleArtistAudioEntity] { await audioSearchResults(search) }
}

@available(iOS 27.0, macOS 27.0, *)
extension EnsemblePlaylistAudioEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [EnsemblePlaylistAudioEntity] { await audioSearchResults(search) }
}

// MARK: - Actions

/// Siri's warm-up hand-off. Ensemble does not warm a queue ahead of playing, so the value is never read.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct EnsembleWarmupAudioQueueResult: TransientAppEntity {
    let id = "queue"
    var displayRepresentation: DisplayRepresentation { "Queue" }
    init() {}
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum EnsemblePlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [EnsemblePlaybackAttributes: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum EnsembleQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [EnsembleQueueInsertionLocation: DisplayRepresentation] = [
        .next: "Next",
        .tail: "Tail"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioInEnsembleIntent: AudioPlaybackIntent {
    var audioEntity: EnsembleAudioItem
    var playbackAttributes: Set<EnsemblePlaybackAttributes>
    var warmupAudioQueueResult: EnsembleWarmupAudioQueueResult?
    var queueLocation: EnsembleQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = audioEntity.item
        AppIntentsLog.logger.info(
            "SIRI_AI: play-audio kind=\(item.kind.rawValue, privacy: .public) shuffle=\(playbackAttributes.contains(.shuffle), privacy: .public) queue=\(queueLocation?.rawValue ?? "none", privacy: .public)"
        )
        let media = EnsembleMediaEntity(item: item)
        let dialog: IntentDialog
        if let queueLocation {
            dialog = try await media.enqueue(playNext: queueLocation == .next)
        } else {
            dialog = try await media.play(shuffle: playbackAttributes.contains(.shuffle))
            if playbackAttributes.contains(.repeat) { _ = await setRepeat(.all) }
        }
        AppIntentsLog.logger.info("SIRI_AI: play-audio done")
        return .result(dialog: dialog)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddAudioToEnsemblePlaylistIntent: AppIntent {
    var audioEntity: EnsembleAudioItem
    var playlist: EnsemblePlaylistAudioEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = audioEntity.item
        AppIntentsLog.logger.info(
            "SIRI_AI: add-to-playlist kind=\(item.kind.rawValue, privacy: .public) playlist='\(playlist.item.displayName, privacy: .private)'"
        )
        let coordinator = try await readyContainer().siriPlaybackCoordinator
        let tracks = try await reportingFailures {
            try await coordinator.resolveTracks(
                kind: item.kind,
                request: EnsembleMediaEntity(item: item).playbackRequest()
            )
        }
        let dialog = try await add(tracks, to: playlist.item)
        AppIntentsLog.logger.info("SIRI_AI: add-to-playlist done")
        return .result(dialog: dialog)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.createStation)
struct CreateEnsembleStationIntent: AudioPlaybackIntent {
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentsLog.logger.info("SIRI_AI: create-station")
        return .result(dialog: try await startRadio(from: nil))
    }
}
