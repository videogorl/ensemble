import XCTest
@testable import EnsembleCore

final class AlbumReleaseClassificationTests: XCTestCase {
    func testPlexEPFormatClassifiesAsSingleOrEP() {
        let album = makeAlbum(
            id: "12321",
            title: "A Little Rhythm and a Wicked Feeling",
            trackCount: 8,
            releaseFormat: .ep
        )

        XCTAssertTrue(album.isLikelySingleOrEP())
    }

    func testPlexSingleFormatClassifiesAsSingleOrEP() {
        let album = makeAlbum(
            id: "14305",
            title: "Tear in My Heart",
            trackCount: 1,
            releaseFormat: .single
        )

        XCTAssertTrue(album.isLikelySingleOrEP())
    }

    func testPlexAlbumFormatClassifiesAsAlbum() {
        let album = makeAlbum(
            id: "album",
            title: "Short Album",
            trackCount: 4,
            releaseFormat: .album
        )

        XCTAssertFalse(album.isLikelySingleOrEP())
    }

    func testUnformattedTitleMarkerStaysClassifiedAsAlbum() {
        let album = makeAlbum(id: "single", title: "Next Semester - Single", trackCount: 1)

        XCTAssertFalse(album.isLikelySingleOrEP())
    }

    func testUnformattedShortReleaseStaysClassifiedAsAlbum() {
        let album = makeAlbum(id: "ep", title: "Short Release", trackCount: 4)
        let tracks = [
            makeTrack(id: "1", albumID: "ep", duration: 180),
            makeTrack(id: "2", albumID: "ep", duration: 210),
            makeTrack(id: "3", albumID: "ep", duration: 240),
            makeTrack(id: "4", albumID: "ep", duration: 200)
        ]

        XCTAssertFalse(album.isLikelySingleOrEP(artistTracks: tracks))
    }

    func testUnformattedUnknownCountReleaseStaysClassifiedAsAlbum() {
        let album = makeAlbum(id: "album", title: "Breach", trackCount: 0)

        XCTAssertFalse(album.isLikelySingleOrEP())
    }

    private func makeAlbum(
        id: String,
        title: String,
        trackCount: Int,
        releaseFormat: AlbumReleaseFormat? = nil
    ) -> Album {
        Album(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            year: 2024,
            trackCount: trackCount,
            releaseFormat: releaseFormat
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
