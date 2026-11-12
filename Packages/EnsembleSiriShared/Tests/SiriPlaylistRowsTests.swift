import EnsembleDomain
import EnsembleSupport
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

    /// Voice Add offers one name per playlist, with the server named only where two offered playlists share a title,
    /// and the chosen name resolves back to exactly that playlist. An unavailable presentation is not "no match": a
    /// playlist among the best candidates defers to the app instead of letting another kind win.
    func testVoiceDestinationNamesRoundTripAndUnavailablePresentationDefers() {
        let home = playlist("road-home", "Road Trip", server: "home")
        let away = playlist("road-away", "Road Trip", server: "away")
        let solo = playlist("solo", "Solo", server: "home")
        let offered = [home, away, solo]
        XCTAssertEqual(offered.map { SiriPlaylistRows.destinationName(for: $0, among: offered) },
                       ["Road Trip (Home)", "Road Trip (Away)", "Solo"])
        for item in offered {
            let name = SiriPlaylistRows.destinationName(for: item, among: offered)
            XCTAssertEqual(SiriPlaylistRows.destinations(named: name, among: offered), [item], name)
        }
        XCTAssertEqual(SiriPlaylistRows.destinations(named: "Road Trip", among: offered), [], "an unqualified shared title is not a choice")

        // A playlist literally titled like a label, and two servers with one name, still get distinct names.
        let literal = SiriMediaIndexItem(kind: .playlist, id: "literal", displayName: "Focus (Home)", sourceCompositeKey: "plex:account-1:home", sourceName: "Home")
        func focus(_ id: String, _ key: String, _ server: String) -> SiriMediaIndexItem {
            SiriMediaIndexItem(kind: .playlist, id: id, displayName: "Focus", sourceCompositeKey: key, sourceName: server)
        }
        let collisions: [(name: String, offered: [SiriMediaIndexItem], expected: [String])] = [
            ("label collides with a literal title",
             [focus("f1", "plex:account-1:home", "Home"), focus("f2", "plex:account-1:away", "Away"), literal],
             ["Focus (Home) 2", "Focus (Away)", "Focus (Home)"]),
            ("two labels collide with each other",
             [focus("f1", "plex:account-1:a", "Home"), focus("f2", "plex:account-1:b", "Home")],
             ["Focus (Home)", "Focus (Home) 2"])
        ]
        for testCase in collisions {
            let names = testCase.offered.map { SiriPlaylistRows.destinationName(for: $0, among: testCase.offered) }
            XCTAssertEqual(names, testCase.expected, testCase.name)
            XCTAssertEqual(Set(names.map(PlexPlaylistMergeRules.normalizedTitle)).count, names.count, testCase.name)
            XCTAssertEqual(names.map { SiriPlaylistRows.destinations(named: $0, among: testCase.offered).map(\.id) },
                           testCase.offered.map { [$0.id] }, "each name round-trips to its own row: \(testCase.name)")
            let reversed = Array(testCase.offered.reversed())
            XCTAssertEqual(testCase.offered.map { SiriPlaylistRows.destinationName(for: $0, among: reversed) },
                           names, "order of the offered list does not change the names")
        }

        let album = SiriMediaIndexItem(kind: .album, id: "a", displayName: "Focus", sourceCompositeKey: "plex:account-1:home")
        let hiddenAlbum = SiriMediaIndexItem(kind: .album, id: "hidden", displayName: "Focus", sourceCompositeKey: "plex:account-1:server:hidden-library")
        let index = SiriMediaIndex(items: [home, album, hiddenAlbum])
        let covering = SiriPlaylistPresentation(hiddenSourceKeys: ["plex:account-1:server:hidden-library"], indexGeneratedAt: index.generatedAt)
        let stale = SiriPlaylistPresentation(hiddenSourceKeys: [], indexGeneratedAt: Date(timeIntervalSince1970: 1))
        typealias Ranked = SiriMediaIndexResolver.RankedItem
        let ranked: [Ranked] = [.init(item: hiddenAlbum, score: 0.95), .init(item: album, score: 0.9)]
        let cases: [(name: String, ranked: [Ranked], presentation: SiriPlaylistPresentation?, expected: [String]?)] = [
            ("no presentation: defer to the app, whatever the kind", ranked, nil, nil),
            ("stale presentation: defer to the app", ranked, stale, nil),
            ("playlist ties the best: defer to the app", [.init(item: home, score: 0.9), .init(item: album, score: 0.85)], nil, nil),
            ("hidden library's better copy is not offered; the visible copy stands", ranked, covering, ["a"]),
            ("nothing ranked", [], nil, [])
        ]
        for testCase in cases {
            let rows = SiriPlaylistRows.presented(testCase.ranked, index: index, presentation: testCase.presentation, tieMargin: 0.1)
            XCTAssertEqual(rows?.map(\.item.id), testCase.expected, testCase.name)
        }
    }
}
