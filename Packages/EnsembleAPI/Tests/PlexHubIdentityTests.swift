import XCTest
@testable import EnsembleAPI

final class PlexHubIdentityTests: XCTestCase {
    func testNormalizesRawAndSourceScopedHubIdentifiers() {
        XCTAssertEqual(
            PlexHubIdentity.normalized("music.recent.added.7"),
            PlexHubIdentity.recentlyAddedMusic
        )
        XCTAssertEqual(
            PlexHubIdentity.normalizedSourceScopedIdentifier("plex:account:server:3:music.recent.added.12"),
            PlexHubIdentity.recentlyAddedMusic
        )
        XCTAssertEqual(PlexHubIdentity.normalized("music.recent.played"), "music.recent.played")
    }

    func testHubMetadataProvidesTypeSpecificFallbackForEmptyTitle() throws {
        let data = #"{"ratingKey":"1","key":"/library/metadata/1","type":"album","title":"  "}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(PlexHubMetadata.self, from: data)

        XCTAssertEqual(metadata.displayTitle, "Unknown Album")
    }
}
