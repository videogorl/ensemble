import EnsemblePersistence
@testable import EnsembleCore

extension LibraryBatch {
    /// A batch of new rows with unique IDs, so a pass reports exactly these changes. No inventory: it never deletes.
    static func writing(artists: Int = 0, albums: Int = 0, tracks: Int = 0, genres: Int = 0) -> LibraryBatch {
        func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { _ in "\(prefix)-\(UUID().uuidString)" } }
        return LibraryBatch(
            artists: ids("artist", artists).map {
                ArtistUpsertInput(
                    ratingKey: $0, key: "/artist/\($0)", name: $0, summary: nil, thumbPath: nil, artPath: nil,
                    dateAdded: nil, dateModified: nil
                )
            },
            albums: ids("album", albums).map {
                AlbumUpsertInput(
                    ratingKey: $0, key: "/album/\($0)", title: $0, artistName: nil, albumArtist: nil,
                    artistRatingKey: nil, summary: nil, thumbPath: nil, artPath: nil, year: nil, trackCount: nil,
                    dateAdded: nil, dateModified: nil, rating: nil
                )
            },
            tracks: ids("track", tracks).map {
                TrackUpsertInput(
                    ratingKey: $0, key: "/track/\($0)", title: $0, artistName: nil, albumName: nil,
                    albumRatingKey: nil, trackNumber: nil, discNumber: nil, duration: nil, thumbPath: nil,
                    streamKey: nil, dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil, playCount: nil
                )
            },
            genres: genres == 0 ? nil : ids("genre", genres).map { GenreUpsertInput(ratingKey: $0, key: "/genre/\($0)", title: $0) },
            queryStartedAt: Date()
        )
    }
}

extension PlaylistHeaderList {
    /// `count` new playlists with unique IDs, so a pass reports exactly these changes. No inventory: it never deletes.
    static func writing(_ count: Int = 0) -> PlaylistHeaderList {
        PlaylistHeaderList(
            headers: (0..<count).map { _ in
                let id = "playlist-\(UUID().uuidString)"
                return PlaylistUpsertInput(
                    ratingKey: id, key: "/playlists/\(id)", title: id, summary: nil, compositePath: nil, isSmart: false,
                    duration: 0, trackCount: 0, dateAdded: nil, dateModified: nil, lastPlayed: nil
                )
            },
            inventory: nil,
            queryStartedAt: Date()
        )
    }
}
