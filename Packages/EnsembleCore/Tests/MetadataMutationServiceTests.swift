import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence
@testable import EnsembleAPI

@MainActor
final class MetadataMutationServiceTests: XCTestCase {
    func testDeleteTrackFailsOfflineWithoutLocalCleanup() async throws {
        let harness = try await makeHarness(isOffline: true)

        await XCTAssertThrowsErrorAsync(
            try await harness.service.deleteTrack(harness.track)
        ) { error in
            XCTAssertEqual(error as? MetadataMutationError, .unavailableOffline("Delete Track"))
        }

        let existing = try await harness.libraryRepository.fetchTrack(
            ratingKey: harness.track.id,
            sourceCompositeKey: harness.track.sourceCompositeKey
        )
        XCTAssertNotNil(existing)
        XCTAssertTrue(harness.removedTrackIDs.ids.isEmpty)
        XCTAssertTrue(harness.client.deletedIDs.isEmpty)
    }

    func testDeleteTrackRemovesLocalArtifactsAfterRemoteSuccess() async throws {
        let harness = try await makeHarness()

        _ = try await harness.downloadManager.createDownload(
            forTrackRatingKey: harness.track.id,
            sourceCompositeKey: harness.sourceKey,
            quality: "original"
        )

        _ = try await harness.targetRepository.upsertTarget(
            key: "track-target",
            kind: .album,
            ratingKey: "album-1",
            sourceCompositeKey: harness.sourceKey,
            displayName: "Album Target"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "track-target",
            trackReferences: [
                OfflineTrackReference(
                    trackRatingKey: harness.track.id,
                    trackSourceCompositeKey: harness.sourceKey
                )
            ]
        )

        try await harness.service.deleteTrack(harness.track)

        let deletedTrack = try await harness.libraryRepository.fetchTrack(
            ratingKey: harness.track.id,
            sourceCompositeKey: harness.track.sourceCompositeKey
        )
        let deletedDownload = try await harness.downloadManager.fetchDownload(
            forTrackRatingKey: harness.track.id,
            sourceCompositeKey: harness.sourceKey
        )
        let remainingTargetKeys = try await harness.targetRepository.fetchTargetKeys(
            containing: OfflineTrackReference(
                trackRatingKey: harness.track.id,
                trackSourceCompositeKey: harness.sourceKey
            )
        )
        XCTAssertNil(deletedTrack)
        XCTAssertNil(deletedDownload)
        XCTAssertTrue(remainingTargetKeys.isEmpty)
        XCTAssertEqual(harness.client.deletedIDs, [[harness.track.id]])
        XCTAssertEqual(harness.removedTrackIDs.ids, [harness.track.id])
    }

    func testEditTrackSendsFieldUpdatesAndRefreshesLocalTitle() async throws {
        let harness = try await makeHarness()

        try await harness.service.editTrack(
            harness.track,
            request: MetadataEditRequest(
                title: "New Track Title",
                sortTitle: "Track Title, New",
                titleLocked: true,
                sortTitleLocked: false
            )
        )

        XCTAssertEqual(harness.client.updatedSectionID, "lib")
        XCTAssertEqual(harness.client.updatedMetadataType, 10)
        XCTAssertEqual(harness.client.updatedIDs, [harness.track.id])
        XCTAssertEqual(
            harness.client.updatedFields,
            [
                PlexMetadataFieldUpdate(fieldName: "title", value: "New Track Title", isLocked: true),
                PlexMetadataFieldUpdate(fieldName: "titleSort", value: "Track Title, New", isLocked: false)
            ]
        )

        let updated = try await harness.libraryRepository.fetchTrack(
            ratingKey: harness.track.id,
            sourceCompositeKey: harness.track.sourceCompositeKey
        )
        XCTAssertEqual(updated?.title, "New Track Title")
    }

    func testDeleteTrackDoesNotCleanupLocalStateWhenRemoteDeleteFails() async throws {
        let harness = try await makeHarness(clientError: PlexAPIError.httpError(statusCode: 403))

        await XCTAssertThrowsErrorAsync(
            try await harness.service.deleteTrack(harness.track)
        )

        let existing = try await harness.libraryRepository.fetchTrack(
            ratingKey: harness.track.id,
            sourceCompositeKey: harness.track.sourceCompositeKey
        )
        XCTAssertNotNil(existing)
        XCTAssertTrue(harness.removedTrackIDs.ids.isEmpty)
    }

    func testDeleteTrackAttemptsServerDeleteWhenOwnershipHintIsMissing() async throws {
        let harness = try await makeHarness(canManageServer: false)

        try await harness.service.deleteTrack(harness.track)

        let existing = try await harness.libraryRepository.fetchTrack(
            ratingKey: harness.track.id,
            sourceCompositeKey: harness.track.sourceCompositeKey
        )
        XCTAssertNil(existing)
        XCTAssertEqual(harness.client.deletedIDs, [[harness.track.id]])
    }

    // MARK: - Harness

    private func makeHarness(
        isOffline: Bool = false,
        canManageServer: Bool = true,
        clientError: Error? = nil
    ) async throws -> Harness {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let targetRepository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let artworkDownloadManager = ArtworkDownloadManager(coreDataStack: stack)
        let sourceKey = "plex:acc:srv:lib"

        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: sourceKey,
            type: "plex",
            accountId: "acc",
            serverId: "srv",
            libraryId: "lib",
            displayName: "Library",
            accountName: "Account"
        )
        _ = try await libraryRepository.upsertArtist(
            ratingKey: "artist-1",
            key: "/library/metadata/artist-1",
            name: "Artist",
            summary: nil,
            thumbPath: nil,
            artPath: nil,
            dateAdded: nil,
            dateModified: nil,
            sourceCompositeKey: sourceKey
        )
        _ = try await libraryRepository.upsertAlbum(
            ratingKey: "album-1",
            key: "/library/metadata/album-1",
            title: "Album",
            artistName: "Artist",
            albumArtist: "Artist",
            artistRatingKey: "artist-1",
            summary: nil,
            thumbPath: nil,
            artPath: nil,
            year: 2024,
            trackCount: 1,
            dateAdded: nil,
            dateModified: nil,
            rating: nil,
            genreNames: nil,
            sourceCompositeKey: sourceKey
        )
        let cdTrack = try await libraryRepository.upsertTrack(
            ratingKey: "track-1",
            key: "/library/metadata/track-1",
            title: "Track",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: "album-1",
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-1/file.mp3",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            lastRatedAt: nil,
            rating: nil,
            playCount: nil,
            genreNames: nil,
            sourceCompositeKey: sourceKey
        )

        let client = MockMetadataMutationClient(error: clientError)
        let removedTrackIDs = TrackIDBox()
        let service = MetadataMutationService(
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            artworkDownloadManager: artworkDownloadManager,
            isOffline: { isOffline },
            canManageServer: { _, _ in canManageServer },
            makeClient: { _, _ in client },
            clearLyricsCache: { _, _ in },
            removeDeletedTracksFromPlayback: { trackIDs in
                removedTrackIDs.ids.formUnion(trackIDs)
            }
        )

        return Harness(
            service: service,
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            client: client,
            removedTrackIDs: removedTrackIDs,
            track: Track(from: cdTrack),
            sourceKey: sourceKey
        )
    }

    private struct Harness {
        let service: MetadataMutationService
        let libraryRepository: LibraryRepository
        let downloadManager: DownloadManager
        let targetRepository: OfflineDownloadTargetRepository
        let client: MockMetadataMutationClient
        let removedTrackIDs: TrackIDBox
        let track: Track
        let sourceKey: String
    }

    private final class MockMetadataMutationClient: MetadataMutationClient, @unchecked Sendable {
        private let error: Error?
        private(set) var deletedIDs: [[String]] = []
        private(set) var updatedSectionID: String?
        private(set) var updatedMetadataType: Int?
        private(set) var updatedIDs: [String] = []
        private(set) var updatedFields: [PlexMetadataFieldUpdate] = []

        init(error: Error? = nil) {
            self.error = error
        }

        func deleteMetadata(ids: [String]) async throws {
            if let error { throw error }
            deletedIDs.append(ids)
        }

        func updateMetadata(
            sectionId: String,
            metadataType: Int,
            ids: [String],
            fieldUpdates: [PlexMetadataFieldUpdate]
        ) async throws {
            if let error { throw error }
            updatedSectionID = sectionId
            updatedMetadataType = metadataType
            updatedIDs = ids
            updatedFields = fieldUpdates
        }
    }

    private final class TrackIDBox {
        var ids: Set<String> = []
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
