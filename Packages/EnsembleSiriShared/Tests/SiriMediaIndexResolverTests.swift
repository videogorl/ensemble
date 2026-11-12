import XCTest
@testable import EnsembleSiriShared

final class SiriMediaIndexResolverTests: XCTestCase {
    func testResolverRanksByMatchThenRecency() {
        let older = SiriMediaIndexItem(
            kind: .album,
            id: "older",
            displayName: "Road Trip",
            sourceCompositeKey: "plex:one",
            lastPlayed: Date(timeIntervalSince1970: 10)
        )
        let newer = SiriMediaIndexItem(
            kind: .album,
            id: "newer",
            displayName: "Road Trip",
            sourceCompositeKey: "plex:two",
            lastPlayed: Date(timeIntervalSince1970: 20)
        )
        let index = SiriMediaIndex(items: [older, newer])

        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: "album road trip",
            requestedKinds: [.album],
            index: index
        )

        XCTAssertEqual(ranked.map(\.item.id), ["newer", "older"])
        XCTAssertEqual(ranked.first?.score, 1.0)
    }

    func testResolverSourceMatchingAcceptsLibraryScopeForServerRequest() {
        XCTAssertTrue(SiriMediaIndexResolver.sourceMatches(
            requestSource: "plex:account:server",
            candidateSource: "plex:account:server:library"
        ))
        XCTAssertFalse(SiriMediaIndexResolver.sourceMatches(
            requestSource: "plex:account:other",
            candidateSource: "plex:account:server:library"
        ))
    }

    func testResolverInfersMediaKindFromPhrasePrefix() {
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "playlist Road Trip"), .playlist)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "shuffle the playlist Road Trip"), .playlist)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "the album Faedom"), .album)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "artist Bjork"), .artist)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "track Hunter"), .track)
        XCTAssertNil(SiriMediaIndexResolver.kindInferred(from: "Hunter"))
    }

    func testKindWordQueryReadsLeadingAndTrailingKindWords() {
        let cases: [(String, SiriMediaKind?, String?)] = [
            ("focus playlist", .playlist, "focus"),
            ("my focus playlist", .playlist, "focus"),
            ("the focus playlist", .playlist, "focus"),
            ("the playlist focus", .playlist, "focus"),
            ("playlist Road Trip", .playlist, "road trip"),
            ("the album Faedom", .album, "faedom"),
            ("Faedom album", .album, "faedom"),
            ("my artist Bjork", .artist, "bjork"),
            ("Hunter song", .track, "hunter"),
            ("the track Hunter", .track, "hunter"),
            ("ZZ Test Siri AI playlist", .playlist, "zz test siri ai"),
            ("Hunter", nil, nil),
            ("playlist", nil, nil),
            ("my playlist", nil, nil),
            ("the song", nil, nil)
        ]
        for (query, kind, text) in cases {
            let result = SiriMediaIndexResolver.kindWordQuery(from: query)
            XCTAssertEqual(result?.kind, kind, query)
            XCTAssertEqual(result?.text, text, query)
        }
    }

    func testFindItemsDeduplicatesEquivalentDisplayNamesWithinKind() {
        let index = SiriMediaIndex(items: [
            SiriMediaIndexItem(kind: .playlist, id: "1", displayName: "Road Trip", secondaryText: "A"),
            SiriMediaIndexItem(kind: .playlist, id: "2", displayName: "Road Trip", secondaryText: "A"),
            SiriMediaIndexItem(kind: .album, id: "3", displayName: "Road Trip", secondaryText: "A")
        ])

        let results = SiriMediaIndexResolver.findItems(
            in: index,
            kind: .playlist,
            matching: "road trip"
        )

        XCTAssertEqual(results.map(\.id), ["1"])
    }

    /// "faedom" by the right artist scores 0.636 on its own; the artist match lifts it, an unqualified request stays strict.
    func testArtistMatchLiftsFuzzyTitleAcrossKinds() {
        let index = SiriMediaIndex(items: [
            SiriMediaIndexItem(kind: .track, id: "t", displayName: "Faedom", sourceCompositeKey: "plex:a", secondaryText: "Gorillaz")
        ])
        let freedom = SiriMediaIndexResolver.rankCandidates(for: "freedom", requestedKinds: nil, index: index, artistHint: "Gorillaz")
        XCTAssertEqual(freedom.map(\.item.id), ["t"])
        XCTAssertTrue(SiriMediaIndexResolver.rankCandidates(for: "freedom", requestedKinds: nil, index: index).isEmpty)
        XCTAssertTrue(SiriMediaIndexResolver.rankCandidates(for: "freedom", requestedKinds: nil, index: index, artistHint: "Someone Else").isEmpty)
    }

    /// With no single kind asked for, only a real match (exact, prefix, whole word) may stand in for the name.
    func testCrossKindRankingRejectsEditDistanceOnlyMatches() {
        let index = SiriMediaIndex(items: [
            SiriMediaIndexItem(kind: .album, id: "1", displayName: "Forestry", sourceCompositeKey: "plex:a"),
            SiriMediaIndexItem(kind: .track, id: "2", displayName: "Kim & Jessie", sourceCompositeKey: "plex:a"),
            SiriMediaIndexItem(kind: .playlist, id: "3", displayName: "focus", sourceCompositeKey: "plex:a")
        ])
        let cases: [(query: String, kinds: Set<SiriMediaKind>?, expected: [String])] = [
            ("Firestorm", nil, []),
            ("Firestorm", [.track, .album, .artist, .playlist], []),
            ("Kim and Jessie", nil, ["2"]),
            ("Shuffle my focus playlist", nil, ["3"])
        ]
        for testCase in cases {
            let ranked = SiriMediaIndexResolver.rankCandidates(for: testCase.query, requestedKinds: testCase.kinds, index: index)
            XCTAssertEqual(ranked.map(\.item.id), testCase.expected, testCase.query)
        }
    }

    /// Phone findings (16 Pro, typed Siri): "kim and jessie" played the one-word "Kim"; "remains of rock and roll"
    /// played the track whose whole title is "&". A title matches inside a request only when it covers a real share of it,
    /// and a title that is only "and" matches only exactly.
    func testShortOrConnectorOnlyTitlesDoNotWinAgainstLongerRequests() {
        func track(_ id: String, _ title: String, _ artist: String) -> SiriMediaIndexItem {
            SiriMediaIndexItem(kind: .track, id: id, displayName: title, sourceCompositeKey: "plex:a", secondaryText: artist)
        }
        let index = SiriMediaIndex(items: [
            track("kim", "Kim", "Steve Hackett"),
            track("amp", "&", "Tally Hall"),
            track("remains", "The Remains of Rock & Roll", "Broken Bells"),
            track("rest", "Rest", "Dispatch"),
            track("pretty", "Pretty, Odd", "Panic! At The Disco"),
            track("shes", "She's A Handsome Woman", "Panic! At The Disco"),
            track("intense", "Intense Focus", "Someone"),
            track("dsotm", "The Dark Side of the Moon", "Pink Floyd"),
            track("remaster", "Song (Remastered 2011)", "Band"),
            track("feat", "Song feat. Artist", "Band"),
            track("deluxe", "Album (Deluxe Edition)", "Band"),
            track("dazed", "Dazed and Confused", "Led Zeppelin"),
            track("nine", "9 to 5", "Dolly Parton"),
            SiriMediaIndexItem(kind: .playlist, id: "focus", displayName: "focus", sourceCompositeKey: "plex:a")
        ])
        let cases: [(query: String, artist: String?, kinds: Set<SiriMediaKind>?, expected: [String])] = [
            ("kim and jessie", nil, [.track], []),
            ("remains of rock and roll", nil, [.track], ["remains"]),
            ("remains of rock and roll", "Broken Bells", [.track], ["remains"]),
            ("the remains of rock & roll", "Broken Bells", [.track], ["remains"]),
            ("Rest", nil, [.track], ["rest"]),
            ("Pretty, Odd", nil, [.track], ["pretty"]),
            ("She's A Handsome Woman", nil, [.track], ["shes"]),
            ("Intense Focus", nil, [.track], ["intense"]),
            ("focus", nil, [.playlist], ["focus"]),
            ("&", nil, [.track], ["amp"]),
            ("and", nil, [.track], ["amp"]),
            // A request that abbreviates a longer title still finds it.
            ("Dark Side", nil, [.track], ["dsotm"]),
            ("Song", nil, [.track], ["remaster", "feat"]),
            ("Album", nil, [.track], ["deluxe"]),
            ("Dazed", nil, [.track], ["dazed"]),
            ("9", nil, [.track], ["nine"])
        ]
        for testCase in cases {
            let ranked = SiriMediaIndexResolver.rankCandidates(
                for: testCase.query, requestedKinds: testCase.kinds, index: index, artistHint: testCase.artist
            )
            XCTAssertEqual(ranked.map(\.item.id), testCase.expected, testCase.query)
        }
    }
}
