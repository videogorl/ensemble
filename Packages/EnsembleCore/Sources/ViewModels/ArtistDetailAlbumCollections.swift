import Foundation

enum ArtistDetailAlbumCollections {
    static func merged(local: [Album], remote: [Album]) -> [Album] {
        guard !remote.isEmpty else { return sorted(local) }

        var albumsByID = Dictionary(uniqueKeysWithValues: local.map { ($0.sourceScopedID, $0) })
        for album in remote where album.releaseFormat != nil || albumsByID[album.sourceScopedID] == nil {
            albumsByID[album.sourceScopedID] = album
        }

        return sorted(Array(albumsByID.values))
    }

    static func sorted(_ albums: [Album]) -> [Album] {
        albums.sorted { left, right in
            let leftYear = left.year ?? Int.min
            let rightYear = right.year ?? Int.min
            if leftYear != rightYear {
                return leftYear > rightYear
            }

            let titleComparison = left.title.localizedStandardCompare(right.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            return left.sourceScopedID < right.sourceScopedID
        }
    }
}
