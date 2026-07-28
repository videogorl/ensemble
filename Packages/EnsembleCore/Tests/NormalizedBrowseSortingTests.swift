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

    func testMergedPlaylistsSortByAggregateDateCountAndDurationAfterGrouping() {
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
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .dateAdded, ascending: true).map(\.title),
            ["Middle", "Ambient"]
        )
        XCTAssertEqual(
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .trackCount, ascending: true).map(\.title),
            ["Middle", "Ambient"]
        )
        XCTAssertEqual(
            PlaylistViewModel.sortDisplayPlaylists(grouped, by: .duration, ascending: true).map(\.title),
            ["Middle", "Ambient"]
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
