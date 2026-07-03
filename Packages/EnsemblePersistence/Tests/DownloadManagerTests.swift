import CoreData
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

    func testBatchCreateDownloadsKeepsSameRatingKeyAcrossSourcesSeparate() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)

        try await seedTrack(ratingKey: "7551", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "7551", sourceCompositeKey: sourceB, repository: libraryRepository)

        let created = try await downloadManager.batchCreateDownloads(
            references: [
                OfflineTrackReference(trackRatingKey: "7551", trackSourceCompositeKey: sourceA),
                OfflineTrackReference(trackRatingKey: "7551", trackSourceCompositeKey: sourceB)
            ],
            quality: "low"
        )
        let duplicateCreateCount = try await downloadManager.batchCreateDownloads(
            references: [
                OfflineTrackReference(trackRatingKey: "7551", trackSourceCompositeKey: sourceA),
                OfflineTrackReference(trackRatingKey: "7551", trackSourceCompositeKey: sourceB)
            ],
            quality: "low"
        )

        let downloadA = try await downloadManager.fetchDownload(forTrackRatingKey: "7551", sourceCompositeKey: sourceA)
        let downloadB = try await downloadManager.fetchDownload(forTrackRatingKey: "7551", sourceCompositeKey: sourceB)

        XCTAssertEqual(created, 2)
        XCTAssertEqual(duplicateCreateCount, 0)
        XCTAssertEqual(downloadA?.track?.sourceCompositeKey, sourceA)
        XCTAssertEqual(downloadB?.track?.sourceCompositeKey, sourceB)
        XCTAssertNotEqual(downloadA?.objectID, downloadB?.objectID)
    }

    func testDeletingCompletedDuplicateSourcePreservesOtherDownloadAndLocalPath() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let suffix = UUID().uuidString
        let filenameA = "duplicate-a-\(suffix).mp3"
        let filenameB = "duplicate-b-\(suffix).mp3"
        let fileURLA = DownloadManager.downloadsDirectory.appendingPathComponent(filenameA)
        let fileURLB = DownloadManager.downloadsDirectory.appendingPathComponent(filenameB)
        defer {
            try? FileManager.default.removeItem(at: fileURLA)
            try? FileManager.default.removeItem(at: fileURLB)
        }

        try Data([0x01]).write(to: fileURLA)
        try Data([0x02]).write(to: fileURLB)
        try await seedTrack(ratingKey: "7551", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "7551", sourceCompositeKey: sourceB, repository: libraryRepository)
        let downloadA = try await downloadManager.createDownload(
            forTrackRatingKey: "7551",
            sourceCompositeKey: sourceA,
            quality: "low"
        )
        let downloadB = try await downloadManager.createDownload(
            forTrackRatingKey: "7551",
            sourceCompositeKey: sourceB,
            quality: "low"
        )
        try await downloadManager.completeDownload(
            downloadA.objectID,
            filePath: filenameA,
            fileSize: 1,
            quality: "low"
        )
        try await downloadManager.completeDownload(
            downloadB.objectID,
            filePath: filenameB,
            fileSize: 1,
            quality: "low"
        )

        try await downloadManager.deleteDownload(forTrackRatingKey: "7551", sourceCompositeKey: sourceA)

        let removedA = try await downloadManager.fetchDownload(forTrackRatingKey: "7551", sourceCompositeKey: sourceA)
        let remainingB = try await downloadManager.fetchDownload(forTrackRatingKey: "7551", sourceCompositeKey: sourceB)
        let trackB = try await libraryRepository.fetchTrack(ratingKey: "7551", sourceCompositeKey: sourceB)

        XCTAssertNil(removedA)
        XCTAssertEqual(remainingB?.filePath, filenameB)
        XCTAssertEqual(trackB?.localFilePath, filenameB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURLB.path))
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

    func testDeleteAllDownloadsRemovesRecordsFilesAndTrackLocalPaths() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let filename = "delete-all-\(UUID().uuidString).mp3"
        let orphanFilename = "delete-all-orphan-\(UUID().uuidString).mp3"
        let fileURL = DownloadManager.downloadsDirectory.appendingPathComponent(filename)
        let orphanURL = DownloadManager.downloadsDirectory.appendingPathComponent(orphanFilename)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(atPath: fileURL.path + ".freq")
            try? FileManager.default.removeItem(at: orphanURL)
        }

        try Data([0x01]).write(to: fileURL)
        try Data([0x02]).write(to: URL(fileURLWithPath: fileURL.path + ".freq"))
        try Data([0x03]).write(to: orphanURL)
        try await seedTrack(ratingKey: "300", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "301", sourceCompositeKey: sourceA, repository: libraryRepository)
        let completed = try await downloadManager.createDownload(
            forTrackRatingKey: "300",
            sourceCompositeKey: sourceA,
            quality: "high"
        )
        _ = try await downloadManager.createDownload(
            forTrackRatingKey: "301",
            sourceCompositeKey: sourceA,
            quality: "high"
        )
        try await downloadManager.completeDownload(
            completed.objectID,
            filePath: filename,
            fileSize: 1,
            quality: "high"
        )

        let downloadsBeforeDelete = try await downloadManager.fetchDownloads()
        XCTAssertEqual(downloadsBeforeDelete.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path + ".freq"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        try await downloadManager.deleteAllDownloads()

        let downloadsAfterDelete = try await downloadManager.fetchDownloads()
        XCTAssertTrue(downloadsAfterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + ".freq"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        let fetchedTrack = try await libraryRepository.fetchTrack(ratingKey: "300")
        let track = try XCTUnwrap(fetchedTrack)
        XCTAssertNil(track.localFilePath)
    }

    func testFetchDownloadsHealsMetadataFromDirectorySnapshot() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let suffix = UUID().uuidString
        let validFilename = "heal-valid-\(suffix).mp3"
        let missingFilename = "heal-missing-\(suffix).mp3"
        let validURL = DownloadManager.downloadsDirectory.appendingPathComponent(validFilename)
        defer { try? FileManager.default.removeItem(at: validURL) }

        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: validURL)
        try await seedTrack(ratingKey: "400", sourceCompositeKey: sourceA, repository: libraryRepository)
        try await seedTrack(ratingKey: "401", sourceCompositeKey: sourceA, repository: libraryRepository)
        let validDownload = try await downloadManager.createDownload(
            forTrackRatingKey: "400",
            sourceCompositeKey: sourceA,
            quality: "high"
        )
        let missingDownload = try await downloadManager.createDownload(
            forTrackRatingKey: "401",
            sourceCompositeKey: sourceA,
            quality: "high"
        )

        try await downloadManager.completeDownload(
            validDownload.objectID,
            filePath: validURL.path,
            fileSize: 0,
            quality: "high"
        )
        try await downloadManager.completeDownload(
            missingDownload.objectID,
            filePath: missingFilename,
            fileSize: 1,
            quality: "high"
        )
        try await updateDownloads(in: stack) { context in
            let valid = try XCTUnwrap(context.existingObject(with: validDownload.objectID) as? CDDownload)
            valid.filePath = validURL.path
            valid.fileSize = 0
            valid.track?.localFilePath = nil
        }

        _ = try await downloadManager.fetchDownloads()
        let fetchedValid = try await downloadManager.fetchDownload(forTrackRatingKey: "400", sourceCompositeKey: sourceA)
        let fetchedMissing = try await downloadManager.fetchDownload(forTrackRatingKey: "401", sourceCompositeKey: sourceA)
        let healedValid = try XCTUnwrap(fetchedValid)
        let healedMissing = try XCTUnwrap(fetchedMissing)

        XCTAssertEqual(healedValid.downloadStatus, .completed)
        XCTAssertEqual(healedValid.filePath, validFilename)
        XCTAssertEqual(healedValid.fileSize, 4)
        XCTAssertEqual(healedValid.track?.localFilePath, validFilename)
        XCTAssertEqual(healedMissing.downloadStatus, .failed)
        XCTAssertEqual(healedMissing.progress, 0)
        XCTAssertNil(healedMissing.track?.localFilePath)
    }

    private func updateDownloads(
        in stack: CoreDataStack,
        _ update: @escaping (NSManagedObjectContext) throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let context = stack.viewContext
            context.perform {
                do {
                    try update(context)
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
