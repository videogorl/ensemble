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
