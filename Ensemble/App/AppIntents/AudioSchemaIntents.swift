import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation
import MediaIntents

// Siri AI audio schemas (iOS and macOS 27): add to playlist and create station, plus the entities and queries they
// need. Play is deliberately not here: Siri AI picks one entity kind per request and queries only that kind, so
// "play focus" cannot be resolved across kinds; play stays with the SiriKit path (see the investigation note).
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
        let results = await SiriIndexLookup.presenting(await currentlyVisible(items)).map(Entity.init(item:))
        AppLogger.info("SIRI_AI: entities for ids kind=\(Entity.indexKind?.rawValue ?? "any") asked=\(wanted.count) found=\(items.count) visible=\(results.count)")
        return results
    }

    func entities(matching string: String) async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        let items = await findItems(matching: string)
        let results = await current(items)
        AppLogger.info("SIRI_AI: entities matching kind=\(Entity.indexKind?.rawValue ?? "any") query='\(string)' found=\(items.count) visible=\(results.count)")
        return results
    }

    func suggestedEntities() async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        return await current(await SiriIndexLookup.recentItems(kind: Entity.indexKind))
    }

    /// Siri sometimes leaves the kind word in the text ("focus playlist"). A kind word means that kind only: another
    /// kind's query finds nothing, and this kind's searches without the word. A name that really contains the word
    /// ("Love Song") is still found: an exact match of the whole text wins.
    private func findItems(matching query: String) async -> [SiriMediaIndexItem] {
        let whole = await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: query)
        guard let named = SiriMediaIndexResolver.kindWordQuery(from: query) else { return whole }
        let wanted = SiriPhraseNormalizer.basic(query)
        if whole.contains(where: { SiriPhraseNormalizer.basic($0.displayName) == wanted }) { return whole }
        guard named.kind == Entity.indexKind else { return [] }
        return await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: named.text)
    }

    /// What Siri's audio search finds, with the existing matcher.
    func audioSearchResults(_ search: AudioSearch) async -> [Entity] {
        let kind = Entity.indexKind?.rawValue ?? "any"
        guard await restoreFocusFilter() else {
            AppLogger.info("SIRI_AI: audio search kind=\(kind) refused: Focus filter not restored")
            return []
        }
        let items: [SiriMediaIndexItem]
        let criteria: String
        switch search.criteria {
        case let .searchQuery(query):
            criteria = "query='\(query)'"
            items = await findItems(matching: query)
        case .unspecified:
            criteria = "unspecified"
            items = await SiriIndexLookup.recentItems(kind: Entity.indexKind)
        case .url:
            // Siri-supplied URLs are not Ensemble links; nothing to resolve.
            criteria = "url"
            items = []
        @unknown default:
            criteria = "unknown"
            items = []
        }
        let results = await current(items)
        // In the session log (it already names tracks), so a phone run shows what Siri asked and what it was given.
        AppLogger.info("SIRI_AI: audio search kind=\(kind) \(criteria) found=\(items.count) visible=\(results.count)")
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

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddAudioToEnsemblePlaylistIntent: AppIntent {
    var audioEntity: EnsembleAudioItem
    var playlist: EnsemblePlaylistAudioEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = audioEntity.item
        AppLogger.info("SIRI_AI: add-to-playlist kind=\(item.kind.rawValue) playlist='\(playlist.item.displayName)'")
        var title = item.displayName
        do {
            let coordinator = try await readyContainer().siriPlaybackCoordinator
            let tracks = try await reportingFailures {
                try await coordinator.resolveTracks(
                    kind: item.kind,
                    request: EnsembleMediaEntity(item: item).playbackRequest()
                )
            }
            if tracks.count == 1, let track = tracks.first { title = track.title }
            let result = try await add(tracks, to: playlist.item)
            let outcome = result.outcome == .added ? "added \(result.sent)" : result.outcome.rawValue
            AppLogger.info("SIRI_AI: add-to-playlist song='\(title)' playlist='\(playlist.item.displayName)' outcome=\(outcome)")
            return .result(dialog: result.dialog)
        } catch {
            AppLogger.info("SIRI_AI: add-to-playlist song='\(title)' playlist='\(playlist.item.displayName)' outcome=error \(error.localizedDescription)")
            throw error
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.createStation)
struct CreateEnsembleStationIntent: AudioPlaybackIntent {
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppLogger.info("SIRI_AI: create-station")
        return .result(dialog: try await startRadio(from: nil))
    }
}
