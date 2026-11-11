import XCTest
@testable import EnsembleAPI

final class PlexPlaylistMutationModelsTests: XCTestCase {
    func testAlbumAndPlaylistDecodeRatings() throws {
        let album = try JSONDecoder().decode(PlexAlbum.self, from: Data(#"""
        {"ratingKey":"a","key":"/library/metadata/a","title":"Album","userRating":10,"lastRatedAt":100}
        """#.utf8))
        let playlist = try JSONDecoder().decode(PlexPlaylist.self, from: Data(#"""
        {"ratingKey":"p","key":"/playlists/p","title":"Playlist","userRating":8,"lastRatedAt":200}
        """#.utf8))

        XCTAssertEqual(album.userRating, 10)
        XCTAssertEqual(album.lastRatedAt, 100)
        XCTAssertEqual(playlist.userRating, 8)
        XCTAssertEqual(playlist.lastRatedAt, 200)
    }

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

    func testPlaylistMergeRulesPreserveIdentityOrderAndRoundRobinValues() {
        let items = [
            (title: "Café Mix", isSmart: false, id: "regular-a"),
            (title: "Other", isSmart: false, id: "other"),
            (title: "  CAFE   MIX ", isSmart: false, id: "regular-b"),
            (title: "Cafe Mix", isSmart: true, id: "smart")
        ]

        let groups = PlexPlaylistMergeRules.grouped(
            items,
            title: \.title,
            isSmart: \.isSmart
        )

        XCTAssertEqual(groups.map { $0.map(\.id) }, [["regular-a", "regular-b"], ["other"], ["smart"]])
        XCTAssertEqual(PlexPlaylistMergeRules.interleaved([["a1", "a2"], ["b1"], ["c1", "c2"]]), ["a1", "b1", "c1", "a2", "c2"])
    }
}

final class PlexPlaylistListCompletenessTests: XCTestCase {
    /// A playlist list may delete only when its container proves it: a size equal to the rows, no
    /// contradicting total or offset, and no repeated playlist.
    func testWhenAPlaylistListIsProvenComplete() throws {
        func row(_ id: String) -> String { #"{"ratingKey":"\#(id)","key":"/playlists/\#(id)","title":"P\#(id)"}"# }
        func body(container: String, rows: [String]) -> Data {
            Data(#"{"MediaContainer":{\#(container)"Metadata":[\#(rows.map(row).joined(separator: ","))]}}"#.utf8)
        }
        let cases: [(name: String, data: Data, complete: Bool, count: Int)] = [
            ("size matches", body(container: #""size":2,"#, rows: ["1", "2"]), true, 2),
            ("size and total match", body(container: #""size":2,"totalSize":2,"#, rows: ["1", "2"]), true, 2),
            ("no size", body(container: "", rows: ["1", "2"]), false, 2),
            ("size short of the rows", body(container: #""size":1,"#, rows: ["1", "2"]), false, 2),
            ("total above the rows", body(container: #""size":2,"totalSize":5,"#, rows: ["1", "2"]), false, 2),
            ("not the first page", body(container: #""size":2,"offset":2,"#, rows: ["1", "2"]), false, 2),
            ("repeated playlist", body(container: #""size":2,"#, rows: ["1", "1"]), false, 1),
        ]
        for testCase in cases {
            let list = try PlexAPIClient.decodePlaylistList(testCase.data)
            XCTAssertEqual(list.isComplete, testCase.complete, testCase.name)
            XCTAssertEqual(list.playlists.count, testCase.count, testCase.name)
        }
    }

    func testAnEmptyPlaylistListIsCompleteWhenTheContainerSaysSoAndNotOtherwise() throws {
        let empty = try PlexAPIClient.decodePlaylistList(Data(#"{"MediaContainer":{"size":0}}"#.utf8))
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.playlists.isEmpty)
        let unsized = try PlexAPIClient.decodePlaylistList(Data(#"{"MediaContainer":{}}"#.utf8))
        XCTAssertFalse(unsized.isComplete)
    }
}
