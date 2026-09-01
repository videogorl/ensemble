import EnsembleDomain
import Foundation

/// Presentation album that retains every exact-source release in one album family.
public struct DisplayAlbum: Identifiable, Hashable, Sendable {
    public let id: String
    public let albums: [Album]

    public var isMerged: Bool { albums.count > 1 }
    public var primaryAlbum: Album { albums[0] }
    public var title: String { primaryAlbum.title }
    public var artistName: String? { primaryAlbum.artistName }
    public var albumArtist: String? { primaryAlbum.albumArtist }
    public var year: Int? { primaryAlbum.year }
    public var dateAdded: Date? { albums.compactMap(\.dateAdded).max() }
    public var dateModified: Date? { albums.compactMap(\.dateModified).max() }
    public var sourceKeys: [String] { albums.compactMap(\.sourceCompositeKey) }

    public init(id: String, albums: [Album]) {
        precondition(!albums.isEmpty, "DisplayAlbum requires at least one backing album")
        self.id = id
        self.albums = albums
    }

    public static func single(_ album: Album) -> DisplayAlbum {
        DisplayAlbum(id: "single:\(album.sourceScopedID)", albums: [album])
    }

    public static func group(
        _ albums: [Album],
        preferences: EnsembleMergingPreferences = .default
    ) -> [DisplayAlbum] {
        guard preferences.isEnabled, preferences.mergeAlbums else {
            return albums.map(single)
        }

        return EnsembleMergeIdentity.grouped(
            albums,
            preferences: preferences,
            identity: {
                EnsembleMergeIdentity.albumFamily(
                    title: $0.title,
                    artist: $0.albumArtist ?? $0.artistName,
                    year: $0.year
                )
            },
            sourceKey: \.sourceCompositeKey
        ).map { albums in
            guard albums.count > 1 else { return .single(albums[0]) }
            let identity = EnsembleMergeIdentity.albumFamily(
                title: albums[0].title,
                artist: albums[0].albumArtist ?? albums[0].artistName,
                year: albums[0].year
            )!
            return DisplayAlbum(id: "merged:\(identity)", albums: albums)
        }
    }
}
