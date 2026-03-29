import Foundation

/// Represents a playlist entry in the UI — either a single playlist or a merged group
/// of same-named playlists from different servers. When merging is enabled, playlists
/// with identical titles and the same isSmart type are grouped into one DisplayPlaylist.
public struct DisplayPlaylist: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let isSmart: Bool
    public let playlists: [Playlist]

    /// Whether this entry represents multiple playlists merged together
    public var isMerged: Bool { playlists.count > 1 }

    /// The first constituent playlist (used for artwork, primary source key, etc.)
    public var primaryPlaylist: Playlist { playlists[0] }

    // MARK: - Aggregated Properties

    /// Sum of all constituent playlists' track counts
    public var trackCount: Int { playlists.reduce(0) { $0 + $1.trackCount } }

    /// Sum of all constituent playlists' durations
    public var duration: TimeInterval { playlists.reduce(0) { $0 + $1.duration } }

    /// Most recent dateAdded across all constituent playlists
    public var dateAdded: Date? { playlists.compactMap(\.dateAdded).max() }

    /// Most recent dateModified across all constituent playlists
    public var dateModified: Date? { playlists.compactMap(\.dateModified).max() }

    /// Most recent lastPlayed across all constituent playlists
    public var lastPlayed: Date? { playlists.compactMap(\.lastPlayed).max() }

    /// Artwork path from the primary playlist
    public var compositePath: String? { primaryPlaylist.compositePath }

    /// Source composite key from the primary playlist
    public var sourceCompositeKey: String? { primaryPlaylist.sourceCompositeKey }

    /// All constituent playlist source keys (for server name resolution)
    public var sourceKeys: [String] { playlists.compactMap(\.sourceCompositeKey) }

    // MARK: - Formatted Display

    /// Formatted total duration string
    public var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    // MARK: - Initialization

    public init(id: String, title: String, isSmart: Bool, playlists: [Playlist]) {
        self.id = id
        self.title = title
        self.isSmart = isSmart
        self.playlists = playlists
    }

    // MARK: - Factory Methods

    /// Wraps a single playlist as a non-merged DisplayPlaylist
    public static func single(_ playlist: Playlist) -> DisplayPlaylist {
        DisplayPlaylist(
            id: "single:\(playlist.id):\(playlist.sourceCompositeKey ?? "")",
            title: playlist.title,
            isSmart: playlist.isSmart,
            playlists: [playlist]
        )
    }

    /// Creates a merged DisplayPlaylist from multiple same-named playlists
    public static func merged(title: String, isSmart: Bool, playlists: [Playlist]) -> DisplayPlaylist {
        DisplayPlaylist(
            id: "merged:\(title):\(isSmart)",
            title: title,
            isSmart: isSmart,
            playlists: playlists
        )
    }

    // MARK: - Grouping Helpers

    /// Groups playlists into DisplayPlaylist entries based on merge toggle.
    /// When merge is enabled, playlists with the same (title, isSmart) are grouped.
    /// When merge is disabled, each playlist becomes its own DisplayPlaylist.
    /// The input order is preserved — the first occurrence of each group key
    /// determines the group's position in the output.
    public static func group(_ playlists: [Playlist], merge: Bool) -> [DisplayPlaylist] {
        guard merge else {
            return playlists.map { .single($0) }
        }

        // Group by exact (title, isSmart) key, preserving insertion order
        var groups: [(key: String, title: String, isSmart: Bool, playlists: [Playlist])] = []
        var keyIndex: [String: Int] = [:]

        for playlist in playlists {
            let groupKey = "\(playlist.title)\u{0}\(playlist.isSmart)"
            if let index = keyIndex[groupKey] {
                groups[index].playlists.append(playlist)
            } else {
                keyIndex[groupKey] = groups.count
                groups.append((key: groupKey, title: playlist.title, isSmart: playlist.isSmart, playlists: [playlist]))
            }
        }

        return groups.map { group in
            if group.playlists.count == 1 {
                return .single(group.playlists[0])
            }
            return .merged(title: group.title, isSmart: group.isSmart, playlists: group.playlists)
        }
    }

    /// Detects playlist titles that exist on multiple servers (name collisions).
    /// Scoped by isSmart so smart and regular playlists are checked independently.
    /// Returns a set of titles that have name collisions.
    public static func detectNameCollisions(_ playlists: [Playlist]) -> Set<String> {
        // Group by (title, isSmart), then check if any group has 2+ distinct source keys
        var groups: [String: Set<String>] = [:]  // groupKey -> set of sourceCompositeKeys

        for playlist in playlists {
            let groupKey = "\(playlist.title)\u{0}\(playlist.isSmart)"
            let sourceKey = playlist.sourceCompositeKey ?? ""
            groups[groupKey, default: []].insert(sourceKey)
        }

        var collisionTitles = Set<String>()
        for (groupKey, sourceKeys) in groups where sourceKeys.count > 1 {
            // Extract title from group key (everything before the null separator)
            if let separatorIndex = groupKey.firstIndex(of: "\u{0}") {
                collisionTitles.insert(String(groupKey[groupKey.startIndex..<separatorIndex]))
            }
        }
        return collisionTitles
    }

    /// Round-robin interleaves tracks from multiple playlists.
    /// Alternates one track from each source; when a source runs out, continues with remaining.
    public static func interleave(_ trackSets: [[Track]]) -> [Track] {
        guard !trackSets.isEmpty else { return [] }
        if trackSets.count == 1 { return trackSets[0] }

        var result: [Track] = []
        result.reserveCapacity(trackSets.reduce(0) { $0 + $1.count })
        var iterators = trackSets.map { $0.makeIterator() }
        var active = Array(repeating: true, count: iterators.count)

        while active.contains(true) {
            for i in iterators.indices where active[i] {
                if let next = iterators[i].next() {
                    result.append(next)
                } else {
                    active[i] = false
                }
            }
        }
        return result
    }
}
