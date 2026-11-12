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
    static func recentItems(kind: SiriMediaKind?, limit: Int = 6) async -> [SiriMediaIndexItem] {
        let recent = fetchItems(kind: kind).sorted {
            ($0.lastPlayed ?? .distantPast, $0.playCount ?? 0) > ($1.lastPlayed ?? .distantPast, $1.playCount ?? 0)
        }
        return Array(await presenting(recent).prefix(limit))
    }

    static func findItems(kind: SiriMediaKind?, matching rawQuery: String, limit: Int = 10) async -> [SiriMediaIndexItem] {
        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: rawQuery,
            requestedKinds: kind.map { [$0] },
            index: loadIndex(),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        )
        let results = Array(await presenting(ranked.map(\.item)).prefix(limit))
        AppIntentsLog.logger.info(
            "SIRI_SHORTCUT: findItems kind=\(kind?.rawValue ?? "any", privacy: .public) raw='\(rawQuery, privacy: .private)' matches=\(results.count, privacy: .public)"
        )
        return results
    }

    /// Distinct rows: the same item from two sources counts once, while playlists are shown as the playlist screen
    /// shows them under the current merge setting and source visibility, both read when the picker asks so a changed
    /// setting shows at once.
    private static func presenting(_ items: [SiriMediaIndexItem]) async -> [SiriMediaIndexItem] {
        guard items.contains(where: { $0.kind == .playlist }) else {
            return SiriMediaIndexResolver.deduplicateEquivalentItems(items)
        }
        let isSourceVisible = await MainActor.run {
            AppRoot.container.libraryVisibilityStore.playlistSourceVisibility(
                in: AppRoot.container.accountManager.sourceConfigurationSnapshot
            )
        }
        return SiriPlaylistRows.deduplicated(SiriPlaylistRows.presented(
            items,
            among: fetchItems(kind: .playlist),
            preferences: SettingsManager.storedMergingPreferences(),
            isSourceVisible: isSourceVisible
        ))
    }

    /// Index items for saved playlist references the index no longer presents but the playlist store still holds.
    @MainActor
    static func storedPlaylistItems(forReferences references: [(id: String, sourceKey: String?)]) async -> [SiriMediaIndexItem] {
        var items: [SiriMediaIndexItem] = []
        for reference in references {
            guard let stored = try? await AppRoot.container.playlistRepository.fetchPlaylistHeader(
                ratingKey: reference.id,
                sourceCompositeKey: reference.sourceKey
            ) else { continue }
            let playlist = Playlist(from: stored)
            items.append(SiriMediaIndexItem(
                kind: .playlist,
                id: playlist.id,
                displayName: playlist.title,
                sourceCompositeKey: playlist.sourceCompositeKey,
                isSmartPlaylist: playlist.isSmart
            ))
        }
        return items
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
    /// The playlist a saved identifier names, in this entity's identifier format; nil for other kinds.
    static func playlistReference(in identifier: String) -> (id: String, sourceKey: String?)?
}

extension IndexItemEntity {
    /// `ratingKey||sourceCompositeKey`, for the playlist entity only.
    static func playlistReference(in identifier: String) -> (id: String, sourceKey: String?)? {
        guard indexKind == .playlist else { return nil }
        let parts = identifier.components(separatedBy: "||")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts.dropFirst().joined(separator: "||").nilIfEmpty)
    }

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
        var entities = SiriPlaylistRows.labeled(items, among: items).map(Entity.init(item:)).filter { wanted.contains($0.id) }
        // A playlist hidden since the shortcut was saved is no longer in the index, but is still in the store.
        // Its identifier keeps resolving (in either identifier format); playing or opening it lands on the visible
        // playlist that stands for it.
        let missing = wanted.subtracting(entities.map(\.id)).compactMap { id in Entity.playlistReference(in: id).map { (id, $0) } }
        if !missing.isEmpty {
            entities += await SiriIndexLookup.storedPlaylistItems(forReferences: missing.map(\.1)).map(Entity.init(item:))
        }
        return entities
    }

    func entities(matching string: String) async throws -> [Entity] {
        await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: string).map(Entity.init(item:))
    }

    func suggestedEntities() async throws -> [Entity] {
        await SiriIndexLookup.recentItems(kind: Entity.indexKind).map(Entity.init(item:))
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

    static func playlistReference(in identifier: String) -> (id: String, sourceKey: String?)? {
        guard let components = SystemMediaReference.components(fromSourceScopedIdentifier: identifier),
              components.kind == .playlist else { return nil }
        return (components.id, components.sourceCompositeKey)
    }

    var displayRepresentation: DisplayRepresentation {
        // A playlist's server name tells same-named playlists apart; other kinds show just their kind.
        let subtitle = item.kind == .playlist && item.secondaryText != nil
            ? "\(item.kind.displayName) · \(item.secondaryText ?? "")"
            : item.kind.displayName
        return DisplayRepresentation(title: "\(item.displayName)", subtitle: "\(subtitle)")
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
