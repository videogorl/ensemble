import XCTest
@testable import EnsembleAPI

final class PlexPlaylistMutationModelsTests: XCTestCase {
    func testPlaylistTrackDecodesPlaylistItemID() throws {
        let json = """
        {
            \"ratingKey\": \"123\",
            \"key\": \"/library/metadata/123\",
            \"playlistItemID\": \"9876\",
            \"librarySectionID\": 5,
            \"title\": \"Song\"
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        XCTAssertEqual(track.playlistItemID, "9876")
        XCTAssertEqual(track.librarySectionID, 5)
    }

    func testPlaylistDeduplicationPreservesFirstServerRecord() throws {
        let playlists = try JSONDecoder().decode([PlexPlaylist].self, from: Data("""
        [
            {"ratingKey":"1","key":"/playlists/1","title":"First","playlistType":"audio"},
            {"ratingKey":"1","key":"/playlists/1","title":"Duplicate","playlistType":"audio"},
            {"ratingKey":"2","key":"/playlists/2","title":"Second","playlistType":"audio"}
        ]
        """.utf8))

        XCTAssertEqual(PlexPlaylist.deduplicated(playlists).map(\.title), ["First", "Second"])
    }

    func testPlexSourceIdentityHandlesServerAndLibraryScopes() {
        let library = PlexSourceIdentity.parse("plex:account:server:library")
        let server = PlexSourceIdentity.parse("plex:account:server")

        XCTAssertEqual(library?.serverSourceKey, "plex:account:server")
        XCTAssertEqual(library?.librarySourceKey, "plex:account:server:library")
        XCTAssertEqual(server?.isServerScoped, true)
        XCTAssertTrue(PlexSourceIdentity.isSameServer(library?.librarySourceKey, server?.serverSourceKey))
    }
}
