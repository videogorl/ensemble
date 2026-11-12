import EnsembleDomain
import Foundation

/// The song, album and artist rows a picker offers, kept in step with the library screens for the current merge
/// setting: items from sources the library hides are dropped; with Merging on for a kind, one row per item as the
/// library merges it (the preferred source's copy), otherwise one row per source, told apart by server name where
/// another row shares the name. Playlists pass through: see `SiriPlaylistRows`.
public enum SiriMediaRows {
    public static func presented(
        _ rows: [SiriMediaIndexItem],
        preferences: EnsembleMergingPreferences,
        isSourceVisible: @Sendable (String?) -> Bool,
        serverName: (String?) -> String?
    ) -> [SiriMediaIndexItem] {
        var seen = Set<String>()
        let shown = rows.filter {
            $0.kind == .playlist || (isSourceVisible($0.sourceCompositeKey) && seen.insert($0.reference.sourceScopedIdentifier).inserted)
        }
        let merged = EnsembleMergeIdentity.collapsed(
            shown, preferences: preferences, identity: { mergeIdentity(of: $0, preferences: preferences) }, sourceKey: \.sourceCompositeKey
        )
        return labeled(merged, serverName: serverName)
    }

    /// The index's items and the library's, each item once: the library's candidates join the index's before
    /// ranking, so an exact name the capped index lacks can outrank a partial match it holds.
    public static func combining(_ indexed: [SiriMediaIndexItem], with library: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        var known = Set(indexed.map(\.reference.sourceScopedIdentifier))
        return indexed + library.filter { known.insert($0.reference.sourceScopedIdentifier).inserted }
    }

    /// What the library merges the item by, or nil when this kind is not merged or the item lacks the identity.
    static func mergeIdentity(of item: SiriMediaIndexItem, preferences: EnsembleMergingPreferences) -> String? {
        guard preferences.isEnabled else { return nil }
        let identity: String?
        switch item.kind {
        case .track where preferences.mergeTracks:
            identity = EnsembleMergeIdentity.track(
                title: item.displayName, artist: item.artistName ?? item.albumArtist, album: item.albumTitle,
                trackNumber: item.trackNumber, discNumber: item.discNumber, duration: item.duration ?? 0
            )
        case .album where preferences.mergeAlbums:
            identity = EnsembleMergeIdentity.albumFamily(title: item.displayName, artist: item.albumArtist ?? item.artistName, year: item.year)
        case .artist where preferences.mergeArtists:
            identity = EnsembleMergeIdentity.normalizedArtist(item.displayName)
        default:
            identity = nil
        }
        return identity.map { "\(item.kind.rawValue)|\($0)" }
    }

    /// Adds the server name to rows another source's row looks the same as. Nothing is dropped.
    private static func labeled(_ rows: [SiriMediaIndexItem], serverName: (String?) -> String?) -> [SiriMediaIndexItem] {
        func key(_ item: SiriMediaIndexItem) -> String {
            [item.kind.rawValue, EnsembleMergeIdentity.normalized(item.displayName) ?? "", EnsembleMergeIdentity.normalized(item.secondaryText) ?? ""]
                .joined(separator: "|")
        }
        var sourcesByKey: [String: Set<String>] = [:]
        for item in rows where item.kind != .playlist { sourcesByKey[key(item), default: []].insert(item.sourceCompositeKey ?? "") }
        return rows.map { item in
            guard item.kind != .playlist, sourcesByKey[key(item)]?.count ?? 0 > 1,
                  let name = serverName(item.sourceCompositeKey) else { return item }
            var labeled = item
            labeled.secondaryText = [item.secondaryText, name].compactMap { $0 }.joined(separator: " · ")
            return labeled
        }
    }
}
