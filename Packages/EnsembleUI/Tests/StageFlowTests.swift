import XCTest
@testable import EnsembleUI
import EnsembleCore

final class StageFlowTests: XCTestCase {
    func testLayoutCenterItemFacesForward() {
        let layout = StageFlowLayoutModel.layout(for: 0, metrics: .default)

        XCTAssertEqual(layout.rotation, 0, accuracy: 0.001)
        XCTAssertEqual(layout.scale, StageFlowLayoutMetrics.default.centerScale, accuracy: 0.001)
        XCTAssertEqual(layout.opacity, 1, accuracy: 0.001)
    }

    func testLayoutImmediateNeighborsFaceCenterStage() {
        let leftLayout = StageFlowLayoutModel.layout(for: -1, metrics: .default)
        let rightLayout = StageFlowLayoutModel.layout(for: 1, metrics: .default)

        XCTAssertGreaterThan(leftLayout.rotation, 0)
        XCTAssertLessThan(rightLayout.rotation, 0)
        XCTAssertEqual(abs(leftLayout.rotation), StageFlowLayoutMetrics.default.siblingRotation, accuracy: 0.001)
        XCTAssertEqual(abs(rightLayout.rotation), StageFlowLayoutMetrics.default.siblingRotation, accuracy: 0.001)
    }

    func testLayoutFarItemsClampToWingTransformBand() {
        let nearWing = StageFlowLayoutModel.layout(for: 2, metrics: .default)
        let farWing = StageFlowLayoutModel.layout(for: 5, metrics: .default)

        XCTAssertEqual(nearWing.scale, farWing.scale, accuracy: 0.001)
        XCTAssertEqual(nearWing.opacity, farWing.opacity, accuracy: 0.001)
        XCTAssertEqual(abs(nearWing.rotation), abs(farWing.rotation), accuracy: 0.001)
        XCTAssertNotEqual(nearWing.xOffset, farWing.xOffset)
    }

    func testSnappedIndexRoundsAndClampsAtBounds() {
        XCTAssertEqual(StageFlowLayoutModel.snappedIndex(for: -10, itemCount: 6), 0)
        XCTAssertEqual(StageFlowLayoutModel.snappedIndex(for: 2.49, itemCount: 6), 2)
        XCTAssertEqual(StageFlowLayoutModel.snappedIndex(for: 2.5, itemCount: 6), 3)
        XCTAssertEqual(StageFlowLayoutModel.snappedIndex(for: 99, itemCount: 6), 5)
    }

    func testProjectedReleaseIndexPreservesFastFlickMomentum() {
        let slowProjection = StageFlowLayoutModel.projectedReleaseIndex(
            baseIndex: 4,
            dragDelta: 0.45,
            predictedTotalDelta: 0.58
        )
        let fastProjection = StageFlowLayoutModel.projectedReleaseIndex(
            baseIndex: 4,
            dragDelta: 0.45,
            predictedTotalDelta: 3.2
        )

        XCTAssertEqual(slowProjection, 4.45, accuracy: 0.05)
        XCTAssertGreaterThan(fastProjection, 6.8)
    }

    func testSongsStageFlowAlbumsUseFilteredTrackOrderAndCollapseDuplicates() {
        let tracks = [
            Track(
                id: "track-1",
                key: "/tracks/1",
                title: "First",
                artistName: "Artist A",
                albumArtistName: "Artist A",
                albumName: "Album A",
                albumRatingKey: "album-a",
                thumbPath: "/track-1",
                fallbackThumbPath: "/album-a",
                sourceCompositeKey: "plex:account:server:lib"
            ),
            Track(
                id: "track-2",
                key: "/tracks/2",
                title: "Second",
                artistName: "Artist A",
                albumArtistName: "Artist A",
                albumName: "Album A",
                albumRatingKey: "album-a",
                thumbPath: "/track-2",
                fallbackThumbPath: "/album-a",
                sourceCompositeKey: "plex:account:server:lib"
            ),
            Track(
                id: "track-3",
                key: "/tracks/3",
                title: "Third",
                artistName: "Artist B",
                albumArtistName: "Artist B",
                albumName: "Album B",
                albumRatingKey: "album-b",
                thumbPath: "/track-3",
                fallbackThumbPath: "/album-b",
                sourceCompositeKey: "plex:account:server:lib"
            )
        ]

        let albums = SongsStageFlowAlbumBuilder.build(from: tracks)

        XCTAssertEqual(albums.map(\.albumID), ["album-a", "album-b"])
        XCTAssertEqual(albums.map(\.matchingTrackCount), [2, 1])
        XCTAssertEqual(albums.first?.thumbPath, "/album-a")
    }
}
