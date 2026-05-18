import Foundation

/// UI artist entry that can represent one physical artist or a merged same-name group.
public struct DisplayArtist: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let artists: [Artist]

    public var isMerged: Bool { artists.count > 1 }
    public var primaryArtist: Artist { artists[0] }
    public var sourceKeys: [String] { artists.compactMap(\.sourceCompositeKey) }
    public var dateAdded: Date? { artists.compactMap(\.dateAdded).max() }
    public var dateModified: Date? { artists.compactMap(\.dateModified).max() }
    public var thumbPath: String? { primaryArtist.thumbPath }
    public var fallbackThumbPath: String? { primaryArtist.fallbackThumbPath }
    public var fallbackRatingKey: String? { primaryArtist.fallbackRatingKey }
    public var sourceScopedID: String { id }

    public init(id: String, name: String, artists: [Artist]) {
        precondition(!artists.isEmpty, "DisplayArtist requires at least one backing artist")
        self.id = id
        self.name = name
        self.artists = artists
    }

    public static func single(_ artist: Artist) -> DisplayArtist {
        DisplayArtist(
            id: "single:\(artist.sourceScopedID)",
            name: artist.name,
            artists: [artist]
        )
    }

    public static func merged(name: String, normalizedName: String, artists: [Artist]) -> DisplayArtist {
        DisplayArtist(
            id: "merged:\(normalizedName)",
            name: name,
            artists: artists
        )
    }

    /// Groups visible artists by normalized display name while preserving each backing source item.
    public static func group(_ artists: [Artist]) -> [DisplayArtist] {
        var groups: [(normalizedName: String, name: String, artists: [Artist])] = []
        var indexByName: [String: Int] = [:]

        for artist in artists {
            let normalizedName = Self.normalizedName(artist.name)
            if let index = indexByName[normalizedName] {
                groups[index].artists.append(artist)
            } else {
                indexByName[normalizedName] = groups.count
                groups.append((normalizedName: normalizedName, name: artist.name, artists: [artist]))
            }
        }

        return groups.map { group in
            if group.artists.count == 1 {
                return .single(group.artists[0])
            }
            return .merged(
                name: group.name,
                normalizedName: group.normalizedName,
                artists: group.artists
            )
        }
    }

    public static func normalizedName(_ name: String) -> String {
        let folded = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
