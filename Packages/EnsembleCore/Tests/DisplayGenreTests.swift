import EnsembleCore
import XCTest

final class DisplayGenreTests: XCTestCase {
    func testGroupMergesNormalizedTitlesAndPreservesBackingGenres() {
        let main = Genre(
            id: "17",
            key: "/library/sections/1/genre/17",
            title: "Rock",
            sourceCompositeKey: "plex:main:server:1"
        )
        let shared = Genre(
            id: "17",
            key: "/library/sections/2/genre/17",
            title: "röck",
            sourceCompositeKey: "plex:shared:server:2"
        )
        let hipHop = Genre(
            id: "42",
            key: "/library/sections/1/genre/42",
            title: "Hip Hop",
            sourceCompositeKey: "plex:main:server:1"
        )

        let grouped = DisplayGenre.group([main, shared, hipHop])

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].title, "Rock")
        XCTAssertTrue(grouped[0].isMerged)
        XCTAssertEqual(grouped[0].genres.map(\.sourceScopedID), [
            "plex:main:server:1||17",
            "plex:shared:server:2||17"
        ])
        XCTAssertFalse(grouped[1].isMerged)
        XCTAssertEqual(grouped[1].primaryGenre.sourceScopedID, "plex:main:server:1||42")
    }

    func testGroupUsesSourceScopedIDForSingles() {
        let genre = Genre(
            id: "7",
            key: "/library/sections/3/genre/7",
            title: "Jazz",
            sourceCompositeKey: "plex:account:server:3"
        )

        let grouped = DisplayGenre.group([genre])

        XCTAssertEqual(grouped.first?.id, "single:plex:account:server:3||7")
    }

    func testMatchesAlbumUsesNormalizedGenreTitle() {
        let genre = DisplayGenre.single(
            Genre(
                id: "11",
                key: "/library/sections/1/genre/11",
                title: "Röck",
                sourceCompositeKey: "plex:main:server:1"
            )
        )
        let album = Album(
            id: "album-1",
            key: "/library/metadata/album-1",
            title: "A Rock Album",
            genres: ["rock"],
            sourceCompositeKey: "plex:shared:server:2"
        )

        XCTAssertTrue(genre.matches(album: album))
    }
}
