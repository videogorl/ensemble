import XCTest
@testable import EnsembleCore

final class AppleMusicPlaylistInventoryProofTests: XCTestCase {
    /// The list may delete only when the REST total and rows agree, MusicKit agrees with the REST list,
    /// and neither read repeats a playlist.
    func testWhenAPlaylistListIsProvenComplete() {
        let cases: [(name: String, rest: [String], total: Int?, native: [String], complete: Bool)] = [
            ("both reads agree", ["a", "b"], 2, ["b", "a"], true),
            ("MusicKit is behind by a playlist", ["a", "b"], 2, ["a"], true),
            ("no total reported", ["a", "b"], nil, ["a", "b"], false),
            ("fewer rows than the total", ["a"], 2, ["a"], false),
            ("more rows than the total", ["a", "b"], 1, ["a", "b"], false),
            ("REST repeats a playlist", ["a", "a"], 2, ["a"], false),
            ("MusicKit repeats a playlist", ["a", "b"], 2, ["a", "a"], false),
            ("MusicKit lists one REST lacks", ["a"], 1, ["a", "b"], false),
            ("REST empty, MusicKit not", [], 0, ["a"], false),
            ("MusicKit empty, REST not", ["a"], 1, [], false),
            ("both empty", [], 0, [], true),
        ]
        for testCase in cases {
            let inventory = AppleMusicPlaylistInventoryProof.inventory(
                restIDs: testCase.rest, restTotal: testCase.total, nativeIDs: testCase.native
            )
            XCTAssertEqual(inventory != nil, testCase.complete, testCase.name)
            if testCase.complete { XCTAssertEqual(inventory?.playlistIDs, Set(testCase.rest), testCase.name) }
        }
    }
}
