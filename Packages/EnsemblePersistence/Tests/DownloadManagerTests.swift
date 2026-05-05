import XCTest
@testable import EnsemblePersistence

final class DownloadManagerTests: XCTestCase {
    private let sourceA = "plex:accountA:serverA:libraryA"
    private let sourceB = "plex:accountA:serverA:libraryB"

    func testCreateAndFetchDownloadsAreSourceAware() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)

        try await seedTrack(ratingKey: "42", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "42", sourceCompositeKey: sourceB, repository: libraryRepository)

        _ = try await downloadManager.createDownload(
            forTrackRatingKey: "42",
            sourceCompositeKey: sourceA,
            quality: "high"
        )
        _ = try await downloadManager.createDownload(
            forTrackRatingKey: "42",
            sourceCompositeKey: sourceB,
            quality: "medium"
        )

        let downloadA = try await downloadManager.fetchDownload(
            forTrackRatingKey: "42",
            sourceCompositeKey: sourceA
        )
        let downloadB = try await downloadManager.fetchDownload(
            forTrackRatingKey: "42",
            sourceCompositeKey: sourceB
        )

        XCTAssertEqual(downloadA?.quality, "high")
        XCTAssertEqual(downloadB?.quality, "medium")
        XCTAssertNotEqual(downloadA?.track?.sourceCompositeKey, downloadB?.track?.sourceCompositeKey)
    }

    func testDeleteDownloadRemovesOnlyMatchingSource() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)

        try await seedTrack(ratingKey: "100", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "100", sourceCompositeKey: sourceB, repository: libraryRepository)

        _ = try await downloadManager.createDownload(
            forTrackRatingKey: "100",
            sourceCompositeKey: sourceA,
            quality: "original"
        )
        _ = try await downloadManager.createDownload(
            forTrackRatingKey: "100",
            sourceCompositeKey: sourceB,
            quality: "original"
        )

        try await downloadManager.deleteDownload(forTrackRatingKey: "100", sourceCompositeKey: sourceA)

        let remainingA = try await downloadManager.fetchDownload(forTrackRatingKey: "100", sourceCompositeKey: sourceA)
        let remainingB = try await downloadManager.fetchDownload(forTrackRatingKey: "100", sourceCompositeKey: sourceB)

        XCTAssertNil(remainingA)
        XCTAssertNotNil(remainingB)
    }

    func testRequeueDownloadResetsTransientStateButPreservesCompletedFile() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)

        try await seedTrack(ratingKey: "200", sourceCompositeKey: sourceA, repository: libraryRepository)
        let download = try await downloadManager.createDownload(
            forTrackRatingKey: "200",
            sourceCompositeKey: sourceA,
            quality: "high"
        )

        try await downloadManager.completeDownload(
            download.objectID,
            filePath: "old-file.mp3",
            fileSize: 42,
            quality: "high"
        )
        try await downloadManager.failDownload(download.objectID, error: "previous failure")

        try await downloadManager.requeueDownload(download.objectID, quality: "low")

        let fetched = try await downloadManager.fetchDownload(forTrackRatingKey: "200", sourceCompositeKey: sourceA)
        let requeued = try XCTUnwrap(fetched)
        XCTAssertEqual(requeued.downloadStatus, .pending)
        XCTAssertEqual(requeued.quality, "low")
        XCTAssertEqual(requeued.progress, 0)
        XCTAssertNil(requeued.error)
        XCTAssertNil(requeued.completedAt)
        XCTAssertEqual(requeued.filePath, "old-file.mp3")
        XCTAssertEqual(requeued.track?.localFilePath, "old-file.mp3")
    }

    func testCompleteDownloadRemovesReplacedFileAfterNewFileIsReady() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let suffix = UUID().uuidString
        let oldFilename = "old-\(suffix).mp3"
        let newFilename = "new-\(suffix).mp3"
        let oldURL = DownloadManager.downloadsDirectory.appendingPathComponent(oldFilename)
        let newURL = DownloadManager.downloadsDirectory.appendingPathComponent(newFilename)
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }

        try Data([0x01]).write(to: oldURL)
        try Data([0x02]).write(to: newURL)
        try await seedTrack(ratingKey: "201", sourceCompositeKey: sourceA, repository: libraryRepository)
        let download = try await downloadManager.createDownload(
            forTrackRatingKey: "201",
            sourceCompositeKey: sourceA,
            quality: "high"
        )

        try await downloadManager.completeDownload(
            download.objectID,
            filePath: oldFilename,
            fileSize: 1,
            quality: "high"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))

        try await downloadManager.requeueDownload(download.objectID, quality: "low")
        try await downloadManager.completeDownload(
            download.objectID,
            filePath: newFilename,
            fileSize: 1,
            quality: "low"
        )

        let fetched = try await downloadManager.fetchDownload(forTrackRatingKey: "201", sourceCompositeKey: sourceA)
        let completed = try XCTUnwrap(fetched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(completed.filePath, newFilename)
        XCTAssertEqual(completed.track?.localFilePath, newFilename)
    }

    private func seedTrack(
        ratingKey: String,
        sourceCompositeKey: String,
        repository: LibraryRepository
    ) async throws {
        _ = try await repository.upsertTrack(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            title: "Track \(ratingKey)",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: nil,
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/metadata/\(ratingKey)",
            dateAdded: Date(),
            dateModified: Date(),
            lastPlayed: nil,
            rating: nil,
            playCount: 0,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
