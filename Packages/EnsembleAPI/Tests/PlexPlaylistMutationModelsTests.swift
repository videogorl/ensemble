import XCTest
@testable import EnsembleAPI

final class PlexPlaylistMutationModelsTests: XCTestCase {
    func testPlaylistTrackDecodesPlaylistItemID() throws {
        let json = """
        {
            \"ratingKey\": \"123\",
            \"key\": \"/library/metadata/123\",
            \"playlistItemID\": \"9876\",
            \"title\": \"Song\"
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        XCTAssertEqual(track.playlistItemID, "9876")
    }
}
