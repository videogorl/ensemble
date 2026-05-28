import EnsembleCore
import XCTest

final class DisplayArtistTests: XCTestCase {
    func testGroupMergesNormalizedNamesAndPreservesBackingArtists() {
        let subscriber = Artist(
            id: "11617",
            key: "/library/metadata/11617",
            name: "AJR",
            sourceCompositeKey: "plex:subscriber:server:3"
        )
        let freeShared = Artist(
            id: "11617",
            key: "/library/metadata/11617",
            name: "ajr",
            sourceCompositeKey: "plex:free:server:3"
        )
        let testLibrary = Artist(
            id: "1",
            key: "/library/metadata/1",
            name: "A J R",
            sourceCompositeKey: "plex:free:test-server:1"
        )

        let grouped = DisplayArtist.group([subscriber, freeShared, testLibrary])

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].name, "AJR")
        XCTAssertTrue(grouped[0].isMerged)
        XCTAssertEqual(grouped[0].artists.map(\.sourceScopedID), [
            "plex:subscriber:server:3||11617",
            "plex:free:server:3||11617"
        ])
        XCTAssertFalse(grouped[1].isMerged)
        XCTAssertEqual(grouped[1].primaryArtist.sourceScopedID, "plex:free:test-server:1||1")
    }

    func testGroupUsesSourceScopedIDForSingles() {
        let artist = Artist(
            id: "42",
            key: "/library/metadata/42",
            name: "The Cars",
            sourceCompositeKey: "plex:account:server:1"
        )

        let grouped = DisplayArtist.group([artist])

        XCTAssertEqual(grouped.first?.id, "single:plex:account:server:1||42")
    }

    func testMergedArtistUsesArtworkBackedArtistForArtwork() {
        let missingArtwork = Artist(
            id: "1",
            key: "/library/metadata/1",
            name: "AJR",
            sourceCompositeKey: "plex:test:server:1"
        )
        let artworkBacked = Artist(
            id: "11617",
            key: "/library/metadata/11617",
            name: "AJR",
            thumbPath: "/library/metadata/11617/thumb/1779789836",
            sourceCompositeKey: "plex:main:server:3"
        )

        let displayArtist = DisplayArtist.merged(
            name: "AJR",
            normalizedName: "ajr",
            artists: [missingArtwork, artworkBacked]
        )

        XCTAssertEqual(displayArtist.primaryArtist.sourceScopedID, "plex:test:server:1||1")
        XCTAssertEqual(displayArtist.artworkArtist.sourceScopedID, "plex:main:server:3||11617")
        XCTAssertEqual(displayArtist.thumbPath, "/library/metadata/11617/thumb/1779789836")
    }
}
