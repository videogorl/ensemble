import XCTest
@testable import EnsemblePersistence

final class OfflineDownloadTargetRepositoryTests: XCTestCase {
    func testReplaceMembershipsTracksCountsAndPrunesRemovedEntries() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let repository = OfflineDownloadTargetRepository(coreDataStack: stack)

        try await seedTrack(ratingKey: "1", sourceCompositeKey: "plex:a:s:l1", repository: libraryRepository)
        try await seedTrack(ratingKey: "2", sourceCompositeKey: "plex:a:s:l1", repository: libraryRepository)

        _ = try await repository.upsertTarget(
            key: "offline:playlist:plex:a:s:*:abc",
            kind: .playlist,
            ratingKey: "abc",
            sourceCompositeKey: "plex:a:s",
            displayName: "Playlist A"
        )

        let firstReference = OfflineTrackReference(trackRatingKey: "1", trackSourceCompositeKey: "plex:a:s:l1")
        let secondReference = OfflineTrackReference(trackRatingKey: "2", trackSourceCompositeKey: "plex:a:s:l1")
        try await repository.replaceMemberships(
            targetKey: "offline:playlist:plex:a:s:*:abc",
            trackReferences: [firstReference, secondReference]
        )

        let initialFirstCount = try await repository.membershipCount(for: firstReference)
        let initialSecondCount = try await repository.membershipCount(for: secondReference)
        let hasInitialFirstMembership = try await repository.hasAnyMembership(for: firstReference)
        let initialReferences = try await repository.fetchTrackReferences(targetKey: "offline:playlist:plex:a:s:*:abc")

        XCTAssertEqual(initialFirstCount, 1)
        XCTAssertEqual(initialSecondCount, 1)
        XCTAssertTrue(hasInitialFirstMembership)
        XCTAssertEqual(initialReferences.count, 2)

        try await repository.replaceMemberships(
            targetKey: "offline:playlist:plex:a:s:*:abc",
            trackReferences: [firstReference]
        )

        let finalFirstCount = try await repository.membershipCount(for: firstReference)
        let finalSecondCount = try await repository.membershipCount(for: secondReference)
        let hasFinalSecondMembership = try await repository.hasAnyMembership(for: secondReference)

        XCTAssertEqual(finalFirstCount, 1)
        XCTAssertEqual(finalSecondCount, 0)
        XCTAssertFalse(hasFinalSecondMembership)
    }

    func testMembershipCountIsSourceAwareForSameRatingKey() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let repository = OfflineDownloadTargetRepository(coreDataStack: stack)

        try await seedTrack(ratingKey: "10", sourceCompositeKey: "plex:acc:srv:l1", repository: libraryRepository)
        try await seedTrack(ratingKey: "10", sourceCompositeKey: "plex:acc:srv:l2", repository: libraryRepository)

        _ = try await repository.upsertTarget(
            key: "offline:album:plex:acc:srv:l1:10",
            kind: .album,
            ratingKey: "10",
            sourceCompositeKey: "plex:acc:srv:l1",
            displayName: "Album 10"
        )
        _ = try await repository.upsertTarget(
            key: "offline:playlist:plex:acc:srv:*:pl",
            kind: .playlist,
            ratingKey: "pl",
            sourceCompositeKey: "plex:acc:srv",
            displayName: "Playlist"
        )

        let l1Reference = OfflineTrackReference(trackRatingKey: "10", trackSourceCompositeKey: "plex:acc:srv:l1")
        let l2Reference = OfflineTrackReference(trackRatingKey: "10", trackSourceCompositeKey: "plex:acc:srv:l2")

        try await repository.replaceMemberships(
            targetKey: "offline:album:plex:acc:srv:l1:10",
            trackReferences: [l1Reference]
        )
        try await repository.replaceMemberships(
            targetKey: "offline:playlist:plex:acc:srv:*:pl",
            trackReferences: [l2Reference]
        )

        let l1Count = try await repository.membershipCount(for: l1Reference)
        let l2Count = try await repository.membershipCount(for: l2Reference)
        XCTAssertEqual(l1Count, 1)
        XCTAssertEqual(l2Count, 1)
    }

    func testUnreferencedTrackReferencesBatchesAndPreservesSharedTracks() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let targetA = "offline:library:source-a"
        let targetB = "offline:album:source-a:shared"
        let shared = OfflineTrackReference(
            trackRatingKey: "shared",
            trackSourceCompositeKey: "source-a"
        )
        let candidates = (0..<501).map {
            OfflineTrackReference(
                trackRatingKey: "track-\($0)",
                trackSourceCompositeKey: "source-a"
            )
        } + [shared]

        _ = try await repository.upsertTarget(
            key: targetA,
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: "source-a",
            displayName: "Library"
        )
        _ = try await repository.upsertTarget(
            key: targetB,
            kind: .album,
            ratingKey: "shared",
            sourceCompositeKey: "source-a",
            displayName: "Shared"
        )
        try await repository.replaceMemberships(
            targetKey: targetA,
            trackReferences: candidates
        )
        try await repository.replaceMemberships(
            targetKey: targetB,
            trackReferences: [shared]
        )

        try await repository.deleteTarget(key: targetA)
        let unreferenced = try await repository.unreferencedTrackReferences(from: candidates)

        XCTAssertEqual(Set(unreferenced), Set(candidates.dropLast()))
    }

    func testFetchTargetKeysReturnsTargetsContainingReference() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let repository = OfflineDownloadTargetRepository(coreDataStack: stack)

        try await seedTrack(ratingKey: "20", sourceCompositeKey: "plex:acc:srv:l1", repository: libraryRepository)
        let reference = OfflineTrackReference(trackRatingKey: "20", trackSourceCompositeKey: "plex:acc:srv:l1")

        _ = try await repository.upsertTarget(
            key: "offline:album:plex:acc:srv:l1:20",
            kind: .album,
            ratingKey: "20",
            sourceCompositeKey: "plex:acc:srv:l1",
            displayName: "Album 20"
        )
        _ = try await repository.upsertTarget(
            key: "offline:playlist:plex:acc:srv:*:shared",
            kind: .playlist,
            ratingKey: "shared",
            sourceCompositeKey: "plex:acc:srv",
            displayName: "Shared"
        )

        try await repository.replaceMemberships(
            targetKey: "offline:album:plex:acc:srv:l1:20",
            trackReferences: [reference]
        )
        try await repository.replaceMemberships(
            targetKey: "offline:playlist:plex:acc:srv:*:shared",
            trackReferences: [reference]
        )

        let targetKeys = try await repository.fetchTargetKeys(containing: reference)

        XCTAssertEqual(
            Set(targetKeys),
            [
                "offline:album:plex:acc:srv:l1:20",
                "offline:playlist:plex:acc:srv:*:shared",
            ]
        )
    }

    func testTotalTrackDurationCountsSharedTracksOnce() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let repository = OfflineDownloadTargetRepository(coreDataStack: stack)

        try await seedTrack(
            ratingKey: "30",
            sourceCompositeKey: "plex:acc:srv:l1",
            duration: 90_000,
            repository: libraryRepository
        )
        try await seedTrack(
            ratingKey: "31",
            sourceCompositeKey: "plex:acc:srv:l1",
            duration: 45_000,
            repository: libraryRepository
        )

        let shared = OfflineTrackReference(trackRatingKey: "30", trackSourceCompositeKey: "plex:acc:srv:l1")
        let unique = OfflineTrackReference(trackRatingKey: "31", trackSourceCompositeKey: "plex:acc:srv:l1")

        _ = try await repository.upsertTarget(
            key: "offline:album:plex:acc:srv:l1:30",
            kind: .album,
            ratingKey: "30",
            sourceCompositeKey: "plex:acc:srv:l1",
            displayName: "Album 30"
        )
        _ = try await repository.upsertTarget(
            key: "offline:playlist:plex:acc:srv:*:mix",
            kind: .playlist,
            ratingKey: "mix",
            sourceCompositeKey: "plex:acc:srv",
            displayName: "Mix"
        )

        try await repository.replaceMemberships(
            targetKey: "offline:album:plex:acc:srv:l1:30",
            trackReferences: [shared]
        )
        try await repository.replaceMemberships(
            targetKey: "offline:playlist:plex:acc:srv:*:mix",
            trackReferences: [shared, unique]
        )

        let duration = try await repository.totalTrackDurationMs()

        XCTAssertEqual(duration, 135_000)
    }

    private func seedTrack(
        ratingKey: String,
        sourceCompositeKey: String,
        duration: Int = 120_000,
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
            duration: duration,
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
