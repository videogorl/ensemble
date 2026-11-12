import EnsembleDomain
import EnsembleSupport
import Foundation

/// The playlist rows Siri, Shortcuts and the picker offer, kept in step with the playlist screen for the current
/// merge setting: one row per same-named group when merging, otherwise every visible server's playlist, told apart
/// by server name. The app and the Siri extension share this one definition.
public enum SiriPlaylistRows {
    /// Rows for `candidates` (any kinds; only playlists change). `playlists` is the index's playlists; other kinds
    /// are ignored. Playlists from sources the screen hides are not offered, and cannot be a group's representative.
    public static func presented(
        _ candidates: [SiriMediaIndexItem],
        among playlists: [SiriMediaIndexItem],
        preferences: EnsembleMergingPreferences,
        isSourceVisible: @Sendable (String?) -> Bool
    ) -> [SiriMediaIndexItem] {
        let shown = playlists.filter { $0.kind == .playlist && isSourceVisible($0.sourceCompositeKey) }
        let rows = candidates.filter { $0.kind != .playlist || isSourceVisible($0.sourceCompositeKey) }
        guard preferences.isEnabled, preferences.mergePlaylists else {
            return labeled(rows, among: shown)
        }
        // The group's first playlist in the user's source order is the one the playlist screen leads with.
        let representatives = Set(
            PlexPlaylistMergeRules.grouped(shown, title: \.displayName, isSmart: { $0.isSmartPlaylist ?? false })
                .compactMap { preferences.ordered($0, sourceKey: \.sourceCompositeKey).first?.scopedID }
        )
        return rows.filter { $0.kind != .playlist || representatives.contains($0.scopedID) }
    }

    /// `presented` for a ranked list: keeps each surviving item's score and order.
    public static func presented(
        _ ranked: [SiriMediaIndexResolver.RankedItem],
        among playlists: [SiriMediaIndexItem],
        preferences: EnsembleMergingPreferences,
        isSourceVisible: @Sendable (String?) -> Bool
    ) -> [SiriMediaIndexResolver.RankedItem] {
        let rows = presented(ranked.map(\.item), among: playlists, preferences: preferences, isSourceVisible: isSourceVisible)
        let byIdentity = Dictionary(rows.map { ($0.reference.sourceScopedIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { entry in
            byIdentity[entry.item.reference.sourceScopedIdentifier].map { .init(item: $0, score: entry.score) }
        }
    }

    /// `presented` for a ranked list against the published presentation. Nil means the presentation is unavailable
    /// (never published, unreadable, or for another index) and a playlist is among the best candidates: nothing can be
    /// shown to be visible, so the caller defers to the app, which resolves the name itself, rather than let a
    /// suppressed playlist change the answer. Otherwise the playlists are dropped when unavailable.
    public static func presented(
        _ ranked: [SiriMediaIndexResolver.RankedItem],
        index: SiriMediaIndex,
        presentation: SiriPlaylistPresentation?,
        tieMargin: Double
    ) -> [SiriMediaIndexResolver.RankedItem]? {
        if let presentation, presentation.covers(index) {
            return presented(
                ranked,
                among: SiriMediaIndexResolver.items(in: index, kind: .playlist),
                preferences: presentation.preferences,
                isSourceVisible: presentation.isSourceVisible
            )
        }
        guard let top = ranked.first?.score else { return [] }
        if ranked.contains(where: { $0.item.kind == .playlist && $0.score >= top - tieMargin }) { return nil }
        return ranked.filter { $0.item.kind != .playlist }
    }

    /// The name Voice Add offers for each offered playlist (by `scopedID`), unique across the offered set: a title as it
    /// is, unless another offered playlist shares it, then "Title (Server)". A label that collides with another
    /// row's name (a playlist literally titled "Title (Server)", or two servers with the same name) gets " 2", " 3" in
    /// `scopedID` order, so the result does not depend on the order of `offered`. A row's own title is never changed.
    public static func destinationNames(for offered: [SiriMediaIndexItem]) -> [String: String] {
        func key(_ name: String) -> String { PlexPlaylistMergeRules.normalizedTitle(name) }
        var titleCounts: [String: Int] = [:]
        for item in offered { titleCounts[key(item.displayName), default: 0] += 1 }
        var names: [String: String] = [:]
        var used = Set<String>()
        var labelled: [SiriMediaIndexItem] = []
        for item in offered {
            if titleCounts[key(item.displayName)] ?? 0 > 1, item.sourceName != nil {
                labelled.append(item)
            } else {
                names[item.scopedID] = item.displayName
                used.insert(key(item.displayName))
            }
        }
        for item in labelled.sorted(by: { $0.scopedID < $1.scopedID }) {
            let base = "\(item.displayName) (\(item.sourceName ?? ""))"
            var name = base
            var number = 2
            while !used.insert(key(name)).inserted {
                name = "\(base) \(number)"
                number += 1
            }
            names[item.scopedID] = name
        }
        return names
    }

    /// The name Voice Add offers for `item`; see `destinationNames`.
    public static func destinationName(for item: SiriMediaIndexItem, among offered: [SiriMediaIndexItem]) -> String {
        destinationNames(for: offered)[item.scopedID] ?? item.displayName
    }

    /// The offered playlists a destination name stands for. Offered names are unique, so one row for a name this
    /// resolver offered, none for any other; more than one means the caller must not write.
    public static func destinations(named name: String, among offered: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        let key = PlexPlaylistMergeRules.normalizedTitle(name)
        let names = destinationNames(for: offered)
        return offered.filter { PlexPlaylistMergeRules.normalizedTitle(names[$0.scopedID] ?? $0.displayName) == key }
    }

    /// Distinct rows: playlists by identity, never by name (two servers may share a name and a title); other kinds by
    /// the index's equivalence rule.
    public static func deduplicated(_ rows: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        var keptOthers = Set(SiriMediaIndexResolver.deduplicateEquivalentItems(rows.filter { $0.kind != .playlist }))
        var seenPlaylists = Set<String>()
        return rows.filter {
            $0.kind == .playlist ? seenPlaylists.insert($0.scopedID).inserted : keptOthers.remove($0) != nil
        }
    }

    /// Adds the server name to playlists whose title another server also uses. Nothing is dropped, so a saved
    /// shortcut's identifier still resolves.
    public static func labeled(
        _ candidates: [SiriMediaIndexItem],
        among playlists: [SiriMediaIndexItem]
    ) -> [SiriMediaIndexItem] {
        var serversByTitle: [String: Set<String>] = [:]
        for playlist in playlists where playlist.kind == .playlist {
            serversByTitle[PlexPlaylistMergeRules.normalizedTitle(playlist.displayName), default: []]
                .insert(playlist.sourceCompositeKey ?? "")
        }
        return candidates.map { item in
            guard item.kind == .playlist,
                  serversByTitle[PlexPlaylistMergeRules.normalizedTitle(item.displayName)]?.count ?? 0 > 1,
                  let sourceName = item.sourceName else { return item }
            var labeled = item
            labeled.secondaryText = sourceName
            return labeled
        }
    }
}

extension SiriMediaIndexItem {
    /// The identity a saved shortcut stores: `ratingKey||sourceCompositeKey`.
    var scopedID: String { "\(id)||\(sourceCompositeKey ?? "")" }
}

/// What the Siri extension cannot read from the app's own process: the merge setting and which playlist sources
/// the playlist screen hides. The app writes it to the App Group whenever either changes.
public struct SiriPlaylistPresentation: Codable, Sendable, Equatable {
    public static let filename = "siri-playlist-presentation.json"

    public var preferences: EnsembleMergingPreferences
    public var hiddenSourceKeys: Set<String>
    /// The generation of the media index this was computed for. An index the app has rebuilt since (new sources) is
    /// not covered, so a reader treats the presentation as unavailable until the app publishes the matching one.
    public var indexGeneratedAt: Date?

    public init(
        preferences: EnsembleMergingPreferences = .default,
        hiddenSourceKeys: Set<String> = [],
        indexGeneratedAt: Date? = nil
    ) {
        self.preferences = preferences
        self.hiddenSourceKeys = hiddenSourceKeys
        self.indexGeneratedAt = indexGeneratedAt
    }

    /// Whether this was published for `index`.
    public func covers(_ index: SiriMediaIndex) -> Bool {
        indexGeneratedAt == index.generatedAt
    }

    /// The published presentation, or nil before the app has written one (or when the file is unreadable).
    public static func load(
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> SiriPlaylistPresentation? {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
                .appendingPathComponent(filename),
              let data = try? Data(contentsOf: url),
              let presentation = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return presentation
    }

    public func write(
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(Self.filename) else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public var isSourceVisible: @Sendable (String?) -> Bool {
        let hidden = hiddenSourceKeys
        return { key in key.map { !hidden.contains($0) } ?? false }
    }
}
