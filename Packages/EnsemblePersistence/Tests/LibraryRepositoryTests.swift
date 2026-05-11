import XCTest
@testable import EnsemblePersistence

final class LibraryRepositoryTests: XCTestCase {
    func testCoreDataStackInitializationWithInMemoryStore() throws {
        let stack = CoreDataStack.inMemory()
        XCTAssertNotNil(stack.viewContext)
    }

    func testLibraryRepositoryUsesInMemoryStore() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let tracks = try await repository.fetchTracks()
        XCTAssertTrue(tracks.isEmpty)
    }

    func testBatchUpsertTracksPersistsStreamId() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)

        let input = TrackUpsertInput(
            ratingKey: "track-1",
            key: "/library/metadata/track-1",
            title: "Track One",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: nil,
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-1",
            streamId: 456,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: 0,
            playCount: 0
        )

        try await repository.batchUpsertTracks([input], sourceCompositeKey: "plex/account/server/library")

        let fetchedTrack = try await repository.fetchTrack(
            ratingKey: "track-1",
            sourceCompositeKey: "plex/account/server/library"
        )
        let track = try XCTUnwrap(fetchedTrack)
        XCTAssertEqual(track.streamId, 456)
    }

    func testDeleteAllLibraryDataPurgesFeedAndMoodCaches() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)

        try await stack.viewContext.perform {
            let mood = CDMood(context: stack.viewContext)
            mood.id = "mood-1"
            mood.key = "/library/sections/1/mood/1"
            mood.title = "Dreamy"
            mood.sourceCompositeKey = "plex:account-1:server-1:lib-1"

            let snapshot = CDHomeFeedSnapshot(context: stack.viewContext)
            snapshot.id = "snapshot-1"
            snapshot.sourceScopeKey = nil
            snapshot.sourceName = nil
            snapshot.createdAt = Date()
            snapshot.fetchedAt = Date()
            snapshot.refreshReason = "test"
            snapshot.freshnessState = "fresh"
            snapshot.schemaVersion = 1
            snapshot.isLastGood = true

            let hub = CDHub(context: stack.viewContext)
            hub.id = "hub-1"
            hub.title = "Recently Added"
            hub.type = "album"
            hub.order = 0
            hub.snapshot = snapshot

            let item = CDHubItem(context: stack.viewContext)
            item.id = "album-1"
            item.type = "album"
            item.title = "Album One"
            item.sourceCompositeKey = "plex:account-1:server-1:lib-1"
            item.order = 0
            item.hub = hub

            hub.items = NSOrderedSet(object: item)
            snapshot.hubs = NSOrderedSet(object: hub)

            let offlineTarget = CDOfflineDownloadTarget(context: stack.viewContext)
            offlineTarget.key = "library:plex:account-1:server-1:lib-1"
            offlineTarget.kind = CDOfflineDownloadTarget.Kind.library.rawValue
            offlineTarget.sourceCompositeKey = "plex:account-1:server-1:lib-1"
            offlineTarget.displayName = "Library One"
            offlineTarget.targetStatus = .completed

            try stack.viewContext.save()
        }

        try await repository.deleteAllLibraryData()

        let remainingMoods = try await stack.viewContext.perform {
            try stack.viewContext.fetch(CDMood.fetchRequest()).count
        }
        let remainingSnapshots = try await stack.viewContext.perform {
            try stack.viewContext.fetch(CDHomeFeedSnapshot.fetchRequest()).count
        }
        let remainingHubs = try await stack.viewContext.perform {
            try stack.viewContext.fetch(CDHub.fetchRequest()).count
        }
        let remainingHubItems = try await stack.viewContext.perform {
            try stack.viewContext.fetch(CDHubItem.fetchRequest()).count
        }
        let remainingOfflineTargets = try await stack.viewContext.perform {
            try stack.viewContext.fetch(CDOfflineDownloadTarget.fetchRequest()).count
        }

        XCTAssertEqual(remainingMoods, 0)
        XCTAssertEqual(remainingSnapshots, 0)
        XCTAssertEqual(remainingHubs, 0)
        XCTAssertEqual(remainingHubItems, 0)
        XCTAssertEqual(remainingOfflineTargets, 0)
    }
}
