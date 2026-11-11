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

    /// A REST body replaces the stored one only with a total that matches its items, or with no total and
    /// MusicKit's read of the playlist agreeing on the song count; a contradiction never does.
    func testWhenARESTPlaylistBodyIsProvenComplete() {
        typealias Verdict = AppleMusicPlaylistBodyProof.RESTVerdict
        let cases: [(name: String, items: Int, total: AppleMusicReportedTotal, verdict: Verdict)] = [
            ("total matches", 3, .reported(3), .complete),
            ("empty and the total says empty", 0, .reported(0), .complete),
            ("total above the items", 2, .reported(3), .unproven),
            ("total below the items", 3, .reported(2), .unproven),
            ("pages contradict each other", 3, .contradictory, .unproven),
            ("an empty page pointed onward", 0, .contradictory, .unproven),
            ("no total given", 3, .absent, .needsWitness),
            ("no total, no items", 0, .absent, .needsWitness),
        ]
        for testCase in cases {
            XCTAssertEqual(
                AppleMusicPlaylistBodyProof.restVerdict(itemCount: testCase.items, total: testCase.total),
                testCase.verdict, testCase.name
            )
        }
        XCTAssertTrue(AppleMusicPlaylistBodyProof.witnessed(restSongCount: 3, nativeSongCount: 3))
        XCTAssertTrue(AppleMusicPlaylistBodyProof.witnessed(restSongCount: 0, nativeSongCount: 0))
        XCTAssertFalse(AppleMusicPlaylistBodyProof.witnessed(restSongCount: 3, nativeSongCount: 2))
        XCTAssertFalse(AppleMusicPlaylistBodyProof.witnessed(restSongCount: 0, nativeSongCount: 2))
    }

    /// MusicKit's read counts only when its tracks loaded and every batch it advertised arrived.
    func testWhenAMusicKitPlaylistReadIsProvenComplete() async throws {
        struct Case {
            let name: String
            let tracksLoaded: Bool
            /// Whether each load attempt succeeds; the read advertises another batch until the list ends.
            let batches: [Bool]
            let complete: Bool
        }
        let cases = [
            Case(name: "loaded, nothing further", tracksLoaded: true, batches: [], complete: true),
            Case(name: "loaded with every batch", tracksLoaded: true, batches: [true, true], complete: true),
            Case(name: "tracks never loaded", tracksLoaded: false, batches: [], complete: false),
            Case(name: "a batch is missing", tracksLoaded: true, batches: [true, false], complete: false),
            Case(name: "the first batch is missing", tracksLoaded: true, batches: [false], complete: false),
        ]
        for testCase in cases {
            var remaining = testCase.batches
            let complete = try await AppleMusicPlaylistBodyProof.isCompleteNativeRead(
                tracksLoaded: testCase.tracksLoaded,
                hasNextBatch: { !remaining.isEmpty },
                loadNextBatch: { remaining.removeFirst() }
            )
            XCTAssertEqual(complete, testCase.complete, testCase.name)
        }
    }
}
