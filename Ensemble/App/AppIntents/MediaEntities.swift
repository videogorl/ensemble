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
        // The index is capped, so a name it does not hold may still be in the library: the library's candidates
        // compete with the index's own, ranked together.
        let indexed = loadIndex()?.items ?? []
        let library = await libraryCandidates(kind: kind, matching: rawQuery, limit: limit)
        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: rawQuery,
            requestedKinds: kind.map { [$0] },
            index: SiriMediaIndex(items: SiriMediaRows.combining(indexed, with: library)),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        )
        let results = Array(await presenting(ranked.map(\.item)).prefix(limit))
        AppIntentsLog.logger.info(
            "SIRI_SHORTCUT: findItems kind=\(kind?.rawValue ?? "any", privacy: .public) raw='\(rawQuery, privacy: .private)' matches=\(results.count, privacy: .public)"
        )
        return results
    }

    /// The rows the library screens would show for `items`, under the merge settings and source visibility, both read
    /// when the picker asks so a changed setting shows at once: songs, albums and artists per `SiriMediaRows`,
    /// playlists per `SiriPlaylistRows`.
    static func presenting(_ items: [SiriMediaIndexItem]) async -> [SiriMediaIndexItem] {
        let (isSourceVisible, serverNames) = await sourceScope(naming: Set(items.compactMap(\.sourceCompositeKey)))
        let preferences = SettingsManager.storedMergingPreferences()
        let rows = SiriMediaRows.presented(
            items, preferences: preferences, isSourceVisible: isSourceVisible,
            serverName: { $0.flatMap { serverNames[$0] } }
        )
        guard rows.contains(where: { $0.kind == .playlist }) else { return rows }
        let playlists = Dictionary(
            SiriPlaylistRows.deduplicated(SiriPlaylistRows.presented(
                rows.filter { $0.kind == .playlist },
                among: fetchItems(kind: .playlist),
                preferences: preferences,
                isSourceVisible: isSourceVisible
            )).map { ($0.reference.sourceScopedIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return rows.compactMap { $0.kind == .playlist ? playlists[$0.reference.sourceScopedIdentifier] : $0 }
    }

    /// The index's items of a kind that are shown: songs, albums and artists only from sources the library shows.
    /// (A playlist hidden since a shortcut was saved still resolves; see `storedItems`.)
    static func visibleItems(kind: SiriMediaKind?) async -> [SiriMediaIndexItem] {
        let items = fetchItems(kind: kind)
        guard items.contains(where: { $0.kind != .playlist }) else { return items }
        let (isSourceVisible, _) = await sourceScope(naming: [])
        return items.filter { $0.kind == .playlist || isSourceVisible($0.sourceCompositeKey) }
    }

    /// Whether the library shows a source (enabled, and not hidden by the profile or Focus), and the server names of `keys`.
    private static func sourceScope(naming keys: Set<String>) async -> (isVisible: @Sendable (String?) -> Bool, names: [String: String]) {
        await MainActor.run {
            let container = AppRoot.container
            let names = keys.reduce(into: [String: String]()) {
                $0[$1] = container.accountManager.sourcePresentation(for: $1)?.serverName
            }
            return (
                container.libraryVisibilityStore.playlistSourceVisibility(in: container.accountManager.sourceConfigurationSnapshot),
                names
            )
        }
    }

    /// Items from the full store, for names the capped index does not hold; see `SiriPlaybackCoordinator.libraryCandidates`.
    @MainActor
    private static func libraryCandidates(kind: SiriMediaKind?, matching query: String, limit: Int) async -> [SiriMediaIndexItem] {
        let container = AppRoot.container
        if container.accountManager.credentialLoadState != .loaded { await container.accountManager.loadAccountsAsync() }
        return (try? await container.siriPlaybackCoordinator.libraryCandidates(kind: kind, matching: query, limit: limit)) ?? []
    }

    /// Index items for saved references the index no longer presents but the store still holds: a playlist hidden
    /// since the shortcut was saved, or a song, album or artist the capped index never held.
    @MainActor
    static func storedItems(forReferences references: [StoredReference]) async -> [SiriMediaIndexItem] {
        let container = AppRoot.container
        var items: [SiriMediaIndexItem] = []
        for reference in references {
            if reference.kind != .playlist {
                if container.accountManager.credentialLoadState != .loaded { await container.accountManager.loadAccountsAsync() }
                if let item = try? await container.siriPlaybackCoordinator.storedItem(
                    kind: reference.kind, id: reference.id, sourceCompositeKey: reference.sourceKey
                ) { items.append(item) }
                continue
            }
            guard let stored = try? await container.playlistRepository.fetchPlaylistHeader(
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

    struct StoredReference {
        let kind: SiriMediaKind
        let id: String
        let sourceKey: String?
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
    /// The item a saved identifier names, in this entity's identifier format.
    static func storedReference(in identifier: String) -> SiriIndexLookup.StoredReference?
}

extension IndexItemEntity {
    /// `ratingKey||sourceCompositeKey`, for the entities of one kind.
    static func storedReference(in identifier: String) -> SiriIndexLookup.StoredReference? {
        guard let indexKind else { return nil }
        let parts = identifier.components(separatedBy: "||")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return .init(kind: indexKind, id: parts[0], sourceKey: parts.dropFirst().joined(separator: "||").nilIfEmpty)
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
        guard await restoreFocusFilter() else { return [] }
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }
        let items = await SiriIndexLookup.visibleItems(kind: Entity.indexKind)
        // Saved identifiers resolve whichever row is shown, so only the server label is added here.
        var entities = SiriPlaylistRows.labeled(items, among: items).map(Entity.init(item:)).filter { wanted.contains($0.id) }
        // A playlist hidden since the shortcut was saved, or a song, album or artist the capped index never held, is
        // not in the index but is still in the store. Its identifier keeps resolving (in either identifier format);
        // playing or opening a playlist lands on the visible playlist that stands for it.
        let missing = wanted.subtracting(entities.map(\.id)).compactMap(Entity.storedReference(in:))
        if !missing.isEmpty {
            entities += await SiriIndexLookup.storedItems(forReferences: missing).map(Entity.init(item:))
        }
        return entities
    }

    func entities(matching string: String) async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        return await SiriIndexLookup.findItems(kind: Entity.indexKind, matching: string).map(Entity.init(item:))
    }

    func suggestedEntities() async throws -> [Entity] {
        guard await restoreFocusFilter() else { return [] }
        return await SiriIndexLookup.recentItems(kind: Entity.indexKind).map(Entity.init(item:))
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

    static func storedReference(in identifier: String) -> SiriIndexLookup.StoredReference? {
        SystemMediaReference.components(fromSourceScopedIdentifier: identifier)
            .map { .init(kind: $0.kind, id: $0.id, sourceKey: $0.sourceCompositeKey) }
    }

    var displayRepresentation: DisplayRepresentation {
        // A server name tells same-named rows apart; otherwise just the kind shows.
        let subtitle = item.secondaryText != nil
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
