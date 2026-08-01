import XCTest
@testable import EnsembleCore

@MainActor
final class NormalizedBrowseSortingTests: XCTestCase {
    func testOptionalDateSortsMissingValuesLastInBothDirectionsWithStableTies() {
        let date = Date(timeIntervalSince1970: 1_000)
        let tracks = [
            Track(id: "missing-b", key: "/missing-b", title: "Missing B", sourceCompositeKey: "plex:b:s:l"),
            Track(id: "dated-b", key: "/dated-b", title: "Dated B", dateAdded: date, sourceCompositeKey: "plex:b:s:l"),
            Track(id: "missing-a", key: "/missing-a", title: "Missing A", sourceCompositeKey: "plex:a:s:l"),
            Track(id: "dated-a", key: "/dated-a", title: "Dated A", dateAdded: date, sourceCompositeKey: "plex:a:s:l")
        ]

        let ascending = LibraryViewModel.sortTracks(tracks, by: .dateAdded, direction: .ascending)
        let descending = LibraryViewModel.sortTracks(tracks, by: .dateAdded, direction: .descending)

        XCTAssertEqual(ascending.map(\.id), ["dated-a", "dated-b", "missing-a", "missing-b"])
        XCTAssertEqual(descending.map(\.id), ["dated-a", "dated-b", "missing-a", "missing-b"])
    }

    func testMergedArtistsSortByAggregateDateAfterGrouping() {
        let mergedArtists = [
            Artist(
                id: "ambient-old",
                key: "/ambient-old",
                name: "Ambient Artist",
                dateAdded: Date(timeIntervalSince1970: 2020),
                sourceCompositeKey: "plex:a:s:l"
            ),
            Artist(
                id: "ambient-new",
                key: "/ambient-new",
                name: "Ambient Artist",
                dateAdded: Date(timeIntervalSince1970: 2025),
                sourceCompositeKey: "appleMusic:a:d:l"
            ),
            Artist(
                id: "middle",
                key: "/middle",
                name: "Middle Artist",
                dateAdded: Date(timeIntervalSince1970: 2023),
                sourceCompositeKey: "plex:a:s:l"
            )
        ]

        let sorted = LibraryViewModel.sortDisplayArtists(
            DisplayArtist.group(mergedArtists),
            by: .dateAdded,
            direction: .ascending
        )

        XCTAssertEqual(sorted.map(\.name), ["Middle Artist", "Ambient Artist"])
        XCTAssertEqual(sorted.last?.dateAdded, Date(timeIntervalSince1970: 2025))
    }

    func testApplePlaylistStaysSeparateWhenSortingSameNamedPlaylists() {
        let playlists = [
            Playlist(
                id: "ambient-a",
                key: "/ambient-a",
                title: "Ambient",
                trackCount: 2,
                duration: 20,
                dateAdded: Date(timeIntervalSince1970: 2020),
                sourceCompositeKey: "plex:a:s:l"
            ),
            Playlist(
                id: "middle",
                key: "/middle",
                title: "Middle",
                trackCount: 4,
                duration: 40,
                dateAdded: Date(timeIntervalSince1970: 2023),
                sourceCompositeKey: "plex:a:s:l"
            ),
            Playlist(
                id: "ambient-b",
                key: "/ambient-b",
                title: "Ambient",
                trackCount: 3,
                duration: 30,
                dateAdded: Date(timeIntervalSince1970: 2025),
                sourceCompositeKey: "appleMusic:a:d:l"
            )
        ]
        let grouped = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .dateAdded, ascending: true).map { $0.primaryPlaylist.id },
            ["ambient-a", "middle", "ambient-b"]
        )
        XCTAssertEqual(
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .trackCount, ascending: true).map { $0.primaryPlaylist.id },
            ["ambient-a", "ambient-b", "middle"]
        )
        XCTAssertEqual(
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .duration, ascending: true).map { $0.primaryPlaylist.id },
            ["ambient-a", "ambient-b", "middle"]
        )
    }

    func testNormalizedMetadataSortsApplePlexAndMissingValuesAcrossBrowseKinds() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let appleSource = MusicSourceIdentifier.appleMusic.compositeKey
        let plexSource = "plex:account:server:library"

        let tracks = [
            Track(
                id: "apple-track",
                key: "apple-track",
                title: "Apple",
                dateAdded: new,
                lastPlayed: new,
                playCount: 4,
                sourceCompositeKey: appleSource
            ),
            Track(
                id: "plex-track",
                key: "/library/metadata/1",
                title: "Plex",
                dateAdded: old,
                lastPlayed: old,
                playCount: 9,
                sourceCompositeKey: plexSource
            ),
            Track(id: "missing-track", key: "missing-track", title: "Missing")
        ]
        XCTAssertEqual(
            LibraryViewModel.sortTracks(tracks, by: .lastPlayed, direction: .ascending).map(\.id),
            ["plex-track", "apple-track", "missing-track"]
        )
        XCTAssertEqual(
            LibraryViewModel.sortTracks(tracks, by: .playCount, direction: .descending).map(\.id),
            ["plex-track", "apple-track", "missing-track"]
        )

        let albums = [
            Album(
                id: "apple-album",
                key: "apple-album",
                title: "Apple",
                dateAdded: new,
                sourceCompositeKey: appleSource
            ),
            Album(
                id: "plex-album",
                key: "/library/metadata/2",
                title: "Plex",
                dateAdded: old,
                dateModified: new,
                sourceCompositeKey: plexSource
            ),
            Album(id: "missing-album", key: "missing-album", title: "Missing")
        ]
        XCTAssertEqual(
            LibraryViewModel.sortAlbums(albums, by: .dateAdded, direction: .ascending).map(\.id),
            ["plex-album", "apple-album", "missing-album"]
        )
        XCTAssertEqual(
            LibraryViewModel.sortAlbums(albums, by: .dateModified, direction: .descending).first?.id,
            "plex-album"
        )

        let artists = [
            Artist(
                id: "apple-artist",
                key: "apple-artist",
                name: "Apple",
                dateAdded: new,
                sourceCompositeKey: appleSource
            ),
            Artist(
                id: "plex-artist",
                key: "/library/metadata/3",
                name: "Plex",
                dateAdded: old,
                dateModified: new,
                sourceCompositeKey: plexSource
            ),
            Artist(id: "missing-artist", key: "missing-artist", name: "Missing")
        ]
        XCTAssertEqual(
            LibraryViewModel.sortArtists(artists, by: .dateAdded, direction: .ascending).map(\.id),
            ["plex-artist", "apple-artist", "missing-artist"]
        )
        XCTAssertEqual(
            LibraryViewModel.sortArtists(artists, by: .dateModified, direction: .descending).first?.id,
            "plex-artist"
        )

        let playlists = [
            Playlist(
                id: "apple-playlist",
                key: "apple-playlist",
                title: "Apple",
                dateAdded: new,
                sourceCompositeKey: appleSource
            ),
            Playlist(
                id: "plex-playlist",
                key: "/playlists/1",
                title: "Plex",
                dateAdded: old,
                dateModified: new,
                lastPlayed: old,
                sourceCompositeKey: plexSource
            ),
            Playlist(id: "missing-playlist", key: "missing-playlist", title: "Missing")
        ]
        XCTAssertEqual(
            PlaylistViewModel.sortPlaylists(playlists, by: .dateAdded, ascending: true).map(\.id),
            ["plex-playlist", "apple-playlist", "missing-playlist"]
        )
        XCTAssertEqual(
            PlaylistViewModel.sortPlaylists(playlists, by: .dateModified, ascending: false).first?.id,
            "plex-playlist"
        )
        XCTAssertEqual(
            PlaylistViewModel.sortPlaylists(playlists, by: .lastPlayed, ascending: false).first?.id,
            "plex-playlist"
        )
    }

    func testBrowseEqualityDetectsMetadataChangesForStableIDs() {
        let oldAlbum = Album(
            id: "album",
            key: "/album",
            title: "Album",
            dateAdded: Date(timeIntervalSince1970: 1),
            sourceCompositeKey: "plex:a:s:l"
        )
        let changedDate = Album(
            id: "album",
            key: "/album",
            title: "Album",
            dateAdded: Date(timeIntervalSince1970: 2),
            sourceCompositeKey: "plex:a:s:l"
        )
        let changedSource = Album(
            id: "album",
            key: "/album",
            title: "Album",
            dateAdded: Date(timeIntervalSince1970: 1),
            sourceCompositeKey: "appleMusic:a:d:l"
        )
        let oldTrack = Track(id: "track", key: "/track", title: "Track", rating: 10, favoriteState: false)
        let changedFavorite = Track(id: "track", key: "/track", title: "Track", rating: 10, favoriteState: true)

        XCTAssertNotEqual(oldAlbum, changedDate)
        XCTAssertNotEqual(oldAlbum, changedSource)
        XCTAssertNotEqual(oldTrack, changedFavorite)
        XCTAssertNotEqual(
            AlbumBrowseSnapshot(
                albums: [oldAlbum],
                sections: [],
                availableGenres: [],
                phase: .idle,
                isShowingStaleSnapshot: false
            ),
            AlbumBrowseSnapshot(
                albums: [changedDate],
                sections: [],
                availableGenres: [],
                phase: .idle,
                isShowingStaleSnapshot: false
            )
        )
    }
}
