import XCTest
@testable import EnsembleSiriShared

final class EnsemblePermalinkTests: XCTestCase {
    func testTrackRoundTripPreservesMatchingMetadata() throws {
        let link = EnsemblePermalink(
            kind: .track,
            title: "Pagan Poetry",
            artistName: "Björk",
            albumTitle: "Vespertine",
            duration: 301.4,
            trackNumber: 5,
            discNumber: 1
        )

        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ensemble.videogorl.me")
        XCTAssertTrue(url.absoluteString.contains("/media/v1/song/Pagan%20Poetry"), url.absoluteString)

        let decoded = try XCTUnwrap(EnsemblePermalink(url: url), url.absoluteString)
        XCTAssertEqual(decoded.kind, .track)
        XCTAssertEqual(decoded.title, "Pagan Poetry")
        XCTAssertEqual(decoded.artistName, "Björk")
        XCTAssertEqual(decoded.albumTitle, "Vespertine")
        XCTAssertEqual(decoded.duration, 301)
        XCTAssertEqual(decoded.trackNumber, 5)
        XCTAssertEqual(decoded.discNumber, 1)
    }

    func testPlaylistRoundTripPreservesSmartFlag() throws {
        let link = EnsemblePermalink(kind: .playlist, title: "Road Trip", isSmartPlaylist: false)
        let url = try XCTUnwrap(link.url)
        let decoded = try XCTUnwrap(EnsemblePermalink(url: url), url.absoluteString)

        XCTAssertEqual(decoded.kind, .playlist)
        XCTAssertEqual(decoded.title, "Road Trip")
        XCTAssertEqual(decoded.isSmartPlaylist, false)
    }

    func testRejectsUnsupportedVersionAndNonEnsembleScheme() {
        XCTAssertNil(EnsemblePermalink(url: URL(string: "ensemble://media/v2/song/Test")!))
        XCTAssertNil(EnsemblePermalink(url: URL(string: "https://example.com/media/v1/song/Test")!))
    }

    func testLegacyCustomSchemeStillDecodes() throws {
        let decoded = try XCTUnwrap(
            EnsemblePermalink(url: URL(string: "ensemble://media/v1/song/Pagan%20Poetry?artist=Bj%C3%B6rk")!)
        )

        XCTAssertEqual(decoded.kind, .track)
        XCTAssertEqual(decoded.title, "Pagan Poetry")
        XCTAssertEqual(decoded.artistName, "Björk")
    }
}
