import EnsembleAPI
import EnsembleDomain
import EnsembleSiriShared
import Foundation

/// The playlist rows an App Intents picker offers, kept in step with the playlist screen for the current merge
/// setting: one row per same-named group when merging, otherwise every server's playlist, told apart by server name.
public enum SiriPlaylistRows {
    /// Rows for `candidates` (any kinds; only playlists change). `playlists` is the index's playlists; other kinds are ignored.
    public static func presented(
        _ candidates: [SiriMediaIndexItem],
        among playlists: [SiriMediaIndexItem],
        preferences: EnsembleMergingPreferences
    ) -> [SiriMediaIndexItem] {
        guard preferences.isEnabled, preferences.mergePlaylists else {
            return labeled(candidates, among: playlists)
        }
        // The group's first playlist in the user's source order is the one the playlist screen leads with.
        let representatives = Set(
            PlexPlaylistMergeRules.grouped(playlists.filter { $0.kind == .playlist }, title: \.displayName, isSmart: { $0.isSmartPlaylist ?? false })
                .compactMap { preferences.ordered($0, sourceKey: \.sourceCompositeKey).first?.scopedID }
        )
        return candidates.filter { $0.kind != .playlist || representatives.contains($0.scopedID) }
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

private extension SiriMediaIndexItem {
    var scopedID: String { "\(id)||\(sourceCompositeKey ?? "")" }
}
