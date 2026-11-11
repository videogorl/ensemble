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

    public init(preferences: EnsembleMergingPreferences = .default, hiddenSourceKeys: Set<String> = []) {
        self.preferences = preferences
        self.hiddenSourceKeys = hiddenSourceKeys
    }

    /// The published presentation, or the defaults (merging on, nothing hidden) before the app has written one.
    public static func load(
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> SiriPlaylistPresentation {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
                .appendingPathComponent(filename),
              let data = try? Data(contentsOf: url),
              let presentation = try? JSONDecoder().decode(Self.self, from: data) else { return SiriPlaylistPresentation() }
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
