import EnsembleDomain
import XCTest
@testable import EnsembleSiriShared

final class SiriMediaRowsTests: XCTestCase {
    private let serverA = "plex:acct:a:lib"
    private let serverB = "plex:acct:b:lib"

    private func track(_ id: String, _ title: String, source: String, album: String = "Album", duration: TimeInterval = 180) -> SiriMediaIndexItem {
        SiriMediaIndexItem(
            kind: .track, id: id, displayName: title, sourceCompositeKey: source, secondaryText: "Artist",
            albumTitle: album, artistName: "Artist", duration: duration, trackNumber: 1, discNumber: 1
        )
    }

    private func album(_ id: String, source: String, year: Int? = 2000) -> SiriMediaIndexItem {
        SiriMediaIndexItem(kind: .album, id: id, displayName: "Album", sourceCompositeKey: source, secondaryText: "Artist", artistName: "Artist", year: year, albumArtist: "Artist")
    }

    private func present(_ rows: [SiriMediaIndexItem], _ preferences: EnsembleMergingPreferences, hidden: Set<String> = []) -> [SiriMediaIndexItem] {
        SiriMediaRows.presented(
            rows, preferences: preferences, isSourceVisible: { $0.map { !hidden.contains($0) } ?? false },
            serverName: { $0 == self.serverA ? "Alpha" : "Beta" }
        )
    }

    /// One row per item as the library displays it with Merging on for the kind; one row per source, labelled by
    /// server, with it off; hidden sources never show; identical rows from one source are never collapsed.
    func testPresentedFollowsTheMergeSettingsAndVisibility() {
        let songs = [track("1", "Song", source: serverA), track("2", "Song", source: serverB)]
        let recordings = [track("1", "Song", source: serverA), track("2", "Song", source: serverB, duration: 240)]
        let albums = [album("1", source: serverA), album("2", source: serverB)]

        let cases: [(name: String, rows: [SiriMediaIndexItem], preferences: EnsembleMergingPreferences, hidden: Set<String>, expected: [String], labels: [String?])] = [
            ("songs merged", songs, .init(mergeTracks: true), [], ["1"], [nil]),
            ("songs not merged", songs, .init(mergeTracks: false), [], ["1", "2"], ["Artist · Alpha", "Artist · Beta"]),
            ("merging off entirely", songs, .init(isEnabled: false, mergeTracks: true), [], ["1", "2"], ["Artist · Alpha", "Artist · Beta"]),
            ("different recordings stay apart", recordings, .init(mergeTracks: true), [], ["1", "2"], ["Artist · Alpha", "Artist · Beta"]),
            ("albums merged", albums, .init(mergeAlbums: true), [], ["1"], [nil]),
            ("albums without a year stay apart", [album("1", source: serverA, year: nil), album("2", source: serverB, year: nil)], .init(mergeAlbums: true), [], ["1", "2"], ["Artist · Alpha", "Artist · Beta"]),
            ("hidden source", songs, .init(mergeTracks: false), [serverB], ["1"], [nil]),
            ("same item twice", [songs[0], songs[0]], .init(mergeTracks: false), [], ["1"], [nil])
        ]
        for testCase in cases {
            let rows = present(testCase.rows, testCase.preferences, hidden: testCase.hidden)
            XCTAssertEqual(rows.map(\.id), testCase.expected, testCase.name)
            XCTAssertEqual(rows.map(\.secondaryText).map { $0 == "Artist" ? nil : $0 }, testCase.labels, testCase.name)
        }
    }

    /// The library's candidates join the index's, so an exact unindexed title outranks an indexed partial match.
    func testCombiningLetsAnUnindexedExactTitleOutrankAnIndexedPartialMatch() {
        let indexed = [track("live", "Sunrise Live", source: serverA)]
        let library = [track("live", "Sunrise Live", source: serverA), track("exact", "Sunrise", source: serverA)]
        let combined = SiriMediaRows.combining(indexed, with: library)
        XCTAssertEqual(combined.map(\.id), ["live", "exact"])
        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: "Sunrise", requestedKinds: [.track], index: SiriMediaIndex(items: combined),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        )
        XCTAssertEqual(ranked.first?.item.id, "exact")
    }

    /// An index row written before the library held a year is replaced by the library's copy of the same item, so
    /// the album still merges.
    func testCombiningPrefersTheLibrarysMetadataForTheSameItem() {
        let old = album("1", source: serverA, year: nil)
        let fresh = album("1", source: serverA, year: 2001)
        let combined = SiriMediaRows.combining([old, track("t", "Song", source: serverA)], with: [fresh])
        XCTAssertEqual(combined.map(\.id), ["1", "t"])
        XCTAssertEqual(combined.first?.year, 2001)
    }
}
