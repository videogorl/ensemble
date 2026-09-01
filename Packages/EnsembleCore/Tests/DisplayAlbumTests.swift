import EnsembleCore
import EnsembleDomain
import XCTest

final class DisplayAlbumTests: XCTestCase {
    func testAlbumFamilyGroupingRetainsSourcesAndKeepsDistinctEditionsSeparate() {
        let plex = Album(
            id: "plex",
            key: "/plex",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            year: 2012,
            trackCount: 16,
            sourceCompositeKey: "plex:a:s:3"
        )
        let apple = Album(
            id: "apple",
            key: "/apple",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            year: 2012,
            trackCount: 16,
            sourceCompositeKey: "appleMusic:a:d:l"
        )
        let standard = Album(
            id: "standard",
            key: "/standard",
            title: "Synthetica",
            artistName: "Metric",
            year: 2012,
            trackCount: 11,
            sourceCompositeKey: "plex:a:s:3"
        )
        let missingYear = Album(
            id: "unknown",
            key: "/unknown",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            sourceCompositeKey: "plex:a:other:3"
        )
        let preferences = EnsembleMergingPreferences(
            mergeAlbums: true,
            preferredSourceKeys: ["appleMusic:a:d:l", "plex:a:s:3"]
        )

        let groups = DisplayAlbum.group([plex, apple, standard, missingYear], preferences: preferences)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].albums.map(\.id), ["apple", "plex"])
        XCTAssertEqual(groups[0].primaryAlbum.id, "apple")
        XCTAssertEqual(groups[1].primaryAlbum.id, "standard")
        XCTAssertEqual(groups[2].primaryAlbum.id, "unknown")
    }
}
