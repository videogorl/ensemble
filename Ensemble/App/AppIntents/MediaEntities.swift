import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation
import OSLog

enum AppIntentsLog {
    static let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-appshortcuts",
        category: "AppShortcuts"
    )
}

// MARK: - Index lookup

/// Reads the shared Siri media index that the app publishes into the App Group.
enum SiriIndexLookup {
    static func fetchItems(kind: SiriMediaKind?) -> [SiriMediaIndexItem] {
        guard let kind else { return loadIndex()?.items ?? [] }
        return SiriMediaIndexResolver.items(in: loadIndex(), kind: kind)
    }

    /// The few most recently played items of a kind (any kind when nil). Shortcuts and Spotlight list an
    /// App Shortcut only for the values its parameter suggests.
    static func recentItems(kind: SiriMediaKind?, limit: Int = 6) -> [SiriMediaIndexItem] {
        let recent = fetchItems(kind: kind).sorted {
            ($0.lastPlayed ?? .distantPast, $0.playCount ?? 0) > ($1.lastPlayed ?? .distantPast, $1.playCount ?? 0)
        }
        // The same item from two sources counts once.
        return Array(SiriMediaIndexResolver.deduplicateEquivalentItems(presentingPlaylists(recent)).prefix(limit))
    }

    static func findItems(kind: SiriMediaKind?, matching rawQuery: String, limit: Int = 10) -> [SiriMediaIndexItem] {
        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: rawQuery,
            requestedKinds: kind.map { [$0] },
            index: loadIndex(),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        )
        let results = Array(
            SiriMediaIndexResolver.deduplicateEquivalentItems(presentingPlaylists(ranked.map(\.item))).prefix(limit)
        )
        AppIntentsLog.logger.info(
            "SIRI_SHORTCUT: findItems kind=\(kind?.rawValue ?? "any", privacy: .public) raw='\(rawQuery, privacy: .private)' matches=\(results.count, privacy: .public)"
        )
        return results
    }

    /// Playlists as the playlist screen shows them under the current merge setting, read when the picker asks so a
    /// changed setting shows at once.
    private static func presentingPlaylists(_ items: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        guard items.contains(where: { $0.kind == .playlist }) else { return items }
        return SiriPlaylistRows.presented(
            items,
            among: fetchItems(kind: .playlist),
            preferences: SettingsManager.storedMergingPreferences()
        )
    }

    private static func loadIndex() -> SiriMediaIndex? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SiriSharedConstants.appGroupIdentifier
        ) else {
            return nil
        }
        return SiriMediaIndexResolver.loadIndex(from: containerURL.appendingPathComponent(SiriSharedConstants.indexFilename))
    }
}

extension SiriMediaIndexItem {
    /// The index item describing a track the player already has, so it can be returned as an entity.
    init(track: Track) {
        self.init(
            kind: .track,
            id: track.id,
            displayName: track.title,
            sourceCompositeKey: track.sourceCompositeKey,
            secondaryText: track.artistName,
            albumTitle: track.albumName,
            artistName: track.artistName,
            duration: track.duration,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber
        )
    }
}

// MARK: - Entities

/// An App Entity backed by one item of the Siri media index. Every kind is built by the same initialiser.
protocol IndexItemEntity: AppEntity where ID == String {
    /// The index kind this entity lists; nil for the entity that spans every kind.
    static var indexKind: SiriMediaKind? { get }
    var item: SiriMediaIndexItem { get }
    init(item: SiriMediaIndexItem)
}

extension IndexItemEntity {
    /// Saved shortcuts store this identifier: `ratingKey||sourceCompositeKey`.
    var id: String { "\(item.id)||\(item.sourceCompositeKey ?? "")" }

    var title: String { item.displayName }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(item.displayName)", subtitle: item.secondaryText.map { "\($0)" })
    }

    func playbackRequest(shuffle: Bool = false) -> SiriPlaybackRequest {
        SiriPlaybackRequest(
            entityID: item.id,
            sourceCompositeKey: item.sourceCompositeKey,
            displayName: item.displayName,
            shuffle: shuffle
        )
    }
}

/// Resolves entities from the Siri media index. The three requirements are answered once here.
protocol IndexItemEntityQuery: EntityStringQuery where Entity: IndexItemEntity {}

extension IndexItemEntityQuery {
    func entities(for identifiers: [Entity.ID]) async throws -> [Entity] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }
        let items = SiriIndexLookup.fetchItems(kind: Entity.indexKind)
        // Saved identifiers resolve whichever row is shown, so only the server label is added here.
        return SiriPlaylistRows.labeled(items, among: items).map(Entity.init(item:)).filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [Entity] {
        SiriIndexLookup.findItems(kind: Entity.indexKind, matching: string).map(Entity.init(item:))
    }

    func suggestedEntities() async throws -> [Entity] {
        SiriIndexLookup.recentItems(kind: Entity.indexKind).map(Entity.init(item:))
    }
}

// The type names below are part of saved shortcuts; do not rename them.

struct EnsembleTrackEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .track
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Track")
    static var defaultQuery = EnsembleTrackEntityQuery()
    let item: SiriMediaIndexItem
}

struct EnsembleTrackEntityQuery: IndexItemEntityQuery { typealias Entity = EnsembleTrackEntity }

struct EnsembleAlbumEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .album
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static var defaultQuery = EnsembleAlbumEntityQuery()
    let item: SiriMediaIndexItem
}

struct EnsembleAlbumEntityQuery: IndexItemEntityQuery { typealias Entity = EnsembleAlbumEntity }

struct EnsembleArtistEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .artist
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist")
    static var defaultQuery = EnsembleArtistEntityQuery()
    let item: SiriMediaIndexItem
}

struct EnsembleArtistEntityQuery: IndexItemEntityQuery { typealias Entity = EnsembleArtistEntity }

struct EnsemblePlaylistEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = .playlist
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static var defaultQuery = EnsemblePlaylistEntityQuery()
    let item: SiriMediaIndexItem
}

struct EnsemblePlaylistEntityQuery: IndexItemEntityQuery { typealias Entity = EnsemblePlaylistEntity }

/// A song, album, artist or playlist, for actions and Spotlight results that accept any of them.
struct EnsembleMediaEntity: IndexItemEntity {
    static let indexKind: SiriMediaKind? = nil
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ensemble Media")
    static var defaultQuery = EnsembleMediaEntityQuery()
    let item: SiriMediaIndexItem

    /// Saved shortcuts and Spotlight store `kind||ratingKey||sourceCompositeKey`.
    var id: String { item.reference.sourceScopedIdentifier }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(item.displayName)", subtitle: "\(item.kind.displayName)")
    }

    var permalink: EnsemblePermalink {
        EnsemblePermalink(
            kind: item.kind,
            title: item.displayName,
            artistName: item.artistName ?? item.secondaryText,
            albumTitle: item.albumTitle,
            duration: item.duration,
            trackNumber: item.trackNumber,
            discNumber: item.discNumber,
            isSmartPlaylist: item.isSmartPlaylist
        )
    }
}

struct EnsembleMediaEntityQuery: IndexItemEntityQuery { typealias Entity = EnsembleMediaEntity }

private extension SiriMediaKind {
    var displayName: String {
        switch self {
        case .track: return "Song"
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        }
    }
}

// MARK: - Moods

/// A mood from the cached Plex moods, merged across libraries by name.
struct EnsembleMoodEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mood")
    static var defaultQuery = EnsembleMoodEntityQuery()

    let mood: Mood
    var id: String { mood.id }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(mood.title)") }
}

struct EnsembleMoodEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [EnsembleMoodEntity] {
        let wanted = Set(identifiers)
        return await AppRoot.container.libraryCollectionTracks.moods()
            .filter { wanted.contains($0.id) }
            .map(EnsembleMoodEntity.init(mood:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [EnsembleMoodEntity] {
        await AppRoot.container.libraryCollectionTracks.moods()
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
            .map(EnsembleMoodEntity.init(mood:))
    }

    @MainActor
    func suggestedEntities() async throws -> [EnsembleMoodEntity] {
        await AppRoot.container.libraryCollectionTracks.moods().map(EnsembleMoodEntity.init(mood:))
    }
}
