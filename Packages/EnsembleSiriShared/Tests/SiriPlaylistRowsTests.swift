import EnsembleDomain
import XCTest
@testable import EnsembleSiriShared

final class SiriPlaylistRowsTests: XCTestCase {
    private func playlist(_ id: String, _ title: String, server: String, smart: Bool = false) -> SiriMediaIndexItem {
        SiriMediaIndexItem(
            kind: .playlist, id: id, displayName: title, sourceCompositeKey: "plex:account-1:\(server)",
            isSmartPlaylist: smart, sourceName: server.capitalized
        )
    }

    /// The picker offers what the playlist screen shows: one row per same-named group while merging (the
    /// preferred source's copy), every server's copy, told apart by server, when not.
    func testRowsFollowTheMergeSetting() {
        let small = playlist("focus-small", "focus", server: "other")
        let big = playlist("focus-big", "Focus ", server: "minibar")
        let solo = playlist("solo", "Solo", server: "other")
        let track = SiriMediaIndexItem(kind: .track, id: "focus", displayName: "focus", sourceCompositeKey: "plex:account-1:other")
        let all = [small, big, solo]

        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        var preferMinibar = EnsembleMergingPreferences.default
        preferMinibar.preferredSourceKeys = ["plex:account-1:minibar"]

        let cases: [(name: String, preferences: EnsembleMergingPreferences, rows: [String])] = [
            ("merging, source order", .default, ["focus-small", "solo"]),
            ("merging, preferred source leads", preferMinibar, ["focus-big", "solo"]),
            ("merging switched off", off, ["focus-small", "focus-big", "solo"])
        ]
        for testCase in cases {
            let rows = SiriPlaylistRows.presented(all + [track], among: all, preferences: testCase.preferences, isSourceVisible: { _ in true })
            XCTAssertEqual(rows.filter { $0.kind == .playlist }.map(\.id), testCase.rows, testCase.name)
            XCTAssertTrue(rows.contains(track), testCase.name)
        }

        let labeled = SiriPlaylistRows.presented(all, among: all, preferences: off, isSourceVisible: { _ in true })
        XCTAssertEqual(labeled.map(\.secondaryText), ["Other", "Minibar", nil], "only colliding titles get a server name")
    }

    /// A hidden source is never offered or chosen as a group's representative; distinct playlists are never
    /// collapsed by name (same friendly name on two servers, smart next to regular).
    func testHiddenSourcesAndSameNamedRowsStayDistinct() {
        let hiddenPreferred = playlist("focus-a", "focus", server: "a")
        let visible = playlist("focus-b", "focus", server: "b")
        let smart = playlist("focus-smart", "focus", server: "b", smart: true)
        var twinA = playlist("twin-a", "twin", server: "a")
        var twinB = playlist("twin-b", "twin", server: "b")
        twinA = SiriMediaIndexItem(kind: .playlist, id: "twin-a", displayName: "twin", sourceCompositeKey: "plex:account-1:a", sourceName: "Home")
        twinB = SiriMediaIndexItem(kind: .playlist, id: "twin-b", displayName: "twin", sourceCompositeKey: "plex:account-1:b", sourceName: "Home")
        let all = [hiddenPreferred, visible, smart, twinA, twinB]
        var preferA = EnsembleMergingPreferences.default
        preferA.preferredSourceKeys = ["plex:account-1:a"]
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        let hideA: @Sendable (String?) -> Bool = { $0 != "plex:account-1:a" }

        let cases: [(name: String, preferences: EnsembleMergingPreferences, rows: [String])] = [
            ("merging: a hidden preferred source yields to the visible copy; smart stays apart",
             preferA, ["focus-b", "focus-smart", "twin-b"]),
            ("not merging: hidden source dropped, same-named rows kept", off, ["focus-b", "focus-smart", "twin-b"])
        ]
        for testCase in cases {
            let rows = SiriPlaylistRows.presented(all, among: all, preferences: testCase.preferences, isSourceVisible: hideA)
            XCTAssertEqual(rows.map(\.id), testCase.rows, testCase.name)
        }

        let shown = SiriPlaylistRows.presented([twinA, twinB], among: all, preferences: off, isSourceVisible: { _ in true })
        XCTAssertEqual(shown.map(\.id), ["twin-a", "twin-b"], "servers sharing a friendly name still give two rows")
    }

    /// A presentation published for an older index does not cover a rebuilt one, so a reader treats it as unavailable.
    func testPresentationCoversOnlyItsOwnIndexGeneration() {
        let index = SiriMediaIndex(generatedAt: Date(timeIntervalSince1970: 10), items: [])
        XCTAssertTrue(SiriPlaylistPresentation(indexGeneratedAt: index.generatedAt).covers(index))
        XCTAssertFalse(SiriPlaylistPresentation(indexGeneratedAt: Date(timeIntervalSince1970: 9)).covers(index))
        XCTAssertFalse(SiriPlaylistPresentation().covers(index))
    }
}
