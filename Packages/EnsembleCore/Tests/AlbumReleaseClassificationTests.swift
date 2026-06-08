import XCTest
@testable import EnsembleCore

final class AlbumReleaseClassificationTests: XCTestCase {
    func testExplicitSingleAndEPTitleMarkersClassifyAsSinglesAndEPs() {
        XCTAssertTrue(makeAlbum(id: "single", title: "Next Semester - Single", trackCount: 0).isLikelySingleOrEP())
        XCTAssertTrue(makeAlbum(id: "ep", title: "The Purpose and Distraction EP", trackCount: 0).isLikelySingleOrEP())
    }

    func testOneTrackReleaseClassifiesAsSingle() {
        let album = makeAlbum(id: "14305", title: "Tear in My Heart", trackCount: 1)

        XCTAssertTrue(album.isLikelySingleOrEP())
    }

    func testShortReleaseWithLoadedTracksClassifiesAsEP() {
        let album = makeAlbum(id: "ep", title: "Short Release", trackCount: 0)
        let tracks = [
            makeTrack(id: "1", albumID: "ep", duration: 180),
            makeTrack(id: "2", albumID: "ep", duration: 210),
            makeTrack(id: "3", albumID: "ep", duration: 240),
            makeTrack(id: "4", albumID: "ep", duration: 200)
        ]

        XCTAssertTrue(album.isLikelySingleOrEP(artistTracks: tracks))
    }

    func testUnknownCountReleaseStaysClassifiedAsAlbum() {
        let album = makeAlbum(id: "album", title: "Breach", trackCount: 0)

        XCTAssertFalse(album.isLikelySingleOrEP())
    }

    func testFullLengthReleaseWithLoadedTracksStaysClassifiedAsAlbum() {
        let album = makeAlbum(id: "6278", title: "Trench", trackCount: 0)
        let tracks = (1...14).map { index in
            makeTrack(id: "\(index)", albumID: "6278", duration: 180)
        }

        XCTAssertFalse(album.isLikelySingleOrEP(artistTracks: tracks))
    }

    private func makeAlbum(id: String, title: String, trackCount: Int) -> Album {
        Album(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            year: 2024,
            trackCount: trackCount
        )
    }

    private func makeTrack(id: String, albumID: String, duration: TimeInterval) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            albumName: "Album",
            albumRatingKey: albumID,
            duration: duration
        )
    }
}
