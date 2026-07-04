import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class TrackDownloadRowStatsTests: XCTestCase {
    func testStatsSummarizeCompletedRows() {
        let rows = [
            makeRow(status: .completed, fileSize: 10),
            makeRow(status: .completed, fileSize: 15),
        ]

        let stats = TrackDownloadRowStats(rows: rows)

        XCTAssertEqual(stats.failedCount, 0)
        XCTAssertEqual(stats.completedCount, 2)
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.downloadedBytes, 25)
        XCTAssertEqual(stats.progress, 1)
        XCTAssertEqual(stats.status, .completed)
    }

    func testStatusPriorityKeepsFailuresFirst() {
        let rows = [
            makeRow(status: .completed),
            makeRow(status: .downloading),
            makeRow(status: .failed),
        ]

        let stats = TrackDownloadRowStats(rows: rows)

        XCTAssertEqual(stats.failedCount, 1)
        XCTAssertEqual(stats.completedCount, 1)
        XCTAssertEqual(stats.progress, Float(1) / Float(3))
        XCTAssertEqual(stats.status, .failed)
    }

    func testEmptyRowsRemainPendingWithZeroProgress() {
        let stats = TrackDownloadRowStats(rows: [])

        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.progress, 0)
        XCTAssertEqual(stats.status, .pending)
    }

    func testPlayableTrackIndexUsesSourceScopedIdentity() {
        let row = makeRow(status: .completed, trackRatingKey: "track", sourceCompositeKey: "source-b")
        let tracks = [
            Track(id: "track", key: "/tracks/a", title: "Wrong Source", sourceCompositeKey: "source-a"),
            Track(id: "track", key: "/tracks/b", title: "Right Source", sourceCompositeKey: "source-b"),
        ]

        XCTAssertEqual(row.sourceScopedID, "source-b||track")
        XCTAssertEqual(row.playableTrackIndex(in: tracks), 1)
    }

    private func makeRow(
        status: CDDownload.Status,
        fileSize: Int64 = 0,
        trackRatingKey: String = "track",
        sourceCompositeKey: String = "source"
    ) -> TrackDownloadRow {
        TrackDownloadRow(
            id: UUID().uuidString,
            trackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceCompositeKey,
            title: "Track",
            artistName: nil,
            thumbPath: nil,
            fallbackThumbPath: nil,
            albumRatingKey: nil,
            status: status,
            progress: status == .completed ? 1 : 0,
            fileSize: fileSize,
            errorMessage: nil,
            downloadedQuality: nil,
            discNumber: 1,
            trackNumber: 1,
            index: 0
        )
    }
}
