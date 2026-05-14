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
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "the album Faedom"), .album)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "artist Bjork"), .artist)
        XCTAssertEqual(SiriMediaIndexResolver.kindInferred(from: "track Hunter"), .track)
        XCTAssertNil(SiriMediaIndexResolver.kindInferred(from: "Hunter"))
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
}
