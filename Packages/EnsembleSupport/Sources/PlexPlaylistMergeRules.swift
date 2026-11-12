import Foundation

/// Cross-client rules for presenting same-named Plex playlists as one collection.
public enum PlexPlaylistMergeRules {
    /// Case-, diacritic-, width-, and whitespace-insensitive playlist identity.
    public static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    public static func key(title: String, isSmart: Bool) -> String {
        "\(normalizedTitle(title))\u{0}\(isSmart)"
    }

    /// Groups equal playlist identities while preserving their first occurrence and source order.
    public static func grouped<Item>(
        _ items: [Item],
        title: (Item) -> String,
        isSmart: (Item) -> Bool
    ) -> [[Item]] {
        var groups: [[Item]] = []
        var indexes: [String: Int] = [:]

        for item in items {
            let itemKey = key(title: title(item), isSmart: isSmart(item))
            if let index = indexes[itemKey] {
                groups[index].append(item)
            } else {
                indexes[itemKey] = groups.count
                groups.append([item])
            }
        }
        return groups
    }

    /// Round-robin interleaves values, continuing with remaining collections as shorter ones end.
    public static func interleaved<Element>(_ collections: [[Element]]) -> [Element] {
        guard collections.count > 1 else { return collections.first ?? [] }

        var result: [Element] = []
        result.reserveCapacity(collections.reduce(0) { $0 + $1.count })
        var iterators = collections.map { $0.makeIterator() }
        var active = Array(repeating: true, count: iterators.count)

        while active.contains(true) {
            for index in iterators.indices where active[index] {
                if let next = iterators[index].next() {
                    result.append(next)
                } else {
                    active[index] = false
                }
            }
        }
        return result
    }
}
