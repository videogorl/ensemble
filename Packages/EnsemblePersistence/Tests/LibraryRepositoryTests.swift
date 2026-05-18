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

    func testBatchAlbumUpsertRecordsArtworkInvalidationWhenThumbChanges() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"
        let initialDate = Date(timeIntervalSince1970: 1_000)

        try await repository.batchUpsertAlbums(
            [
                makeAlbumInput(
                    ratingKey: "album-1",
                    thumbPath: "/library/metadata/album-1/thumb/old",
                    dateModified: initialDate
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        try await repository.batchUpsertAlbums(
            [
                makeAlbumInput(
                    ratingKey: "album-1",
                    thumbPath: "/library/metadata/album-1/thumb/old",
                    dateModified: initialDate
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        try await repository.batchUpsertAlbums(
            [
                makeAlbumInput(
                    ratingKey: "album-1",
                    thumbPath: "/library/metadata/album-1/thumb/new",
                    dateModified: initialDate
                )
            ],
            sourceCompositeKey: sourceKey
        )

        XCTAssertEqual(
            repository.drainArtworkInvalidationInfo(),
            [
                ArtworkInvalidationInfo(
                    ratingKey: "album-1",
                    type: .album,
                    reason: .pathChanged
                )
            ]
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testArtistUpsertRecordsArtworkInvalidationWhenMetadataDateChanges() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        _ = try await repository.upsertArtist(
            ratingKey: "artist-1",
            key: "/library/metadata/artist-1",
            name: "Artist One",
            summary: nil,
            thumbPath: "/library/metadata/artist-1/thumb",
            artPath: nil,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_000),
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await repository.upsertArtist(
            ratingKey: "artist-1",
            key: "/library/metadata/artist-1",
            name: "Artist One",
            summary: nil,
            thumbPath: "/library/metadata/artist-1/thumb",
            artPath: nil,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_001),
            sourceCompositeKey: sourceKey
        )

        XCTAssertEqual(
            repository.drainArtworkInvalidationInfo(),
            [
                ArtworkInvalidationInfo(
                    ratingKey: "artist-1",
                    type: .artist,
                    reason: .metadataModified
                )
            ]
        )
    }

    func testAlbumAndArtistUpsertsDoNotRecordDateOnlyInvalidationWithoutArtworkPath() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        try await repository.batchUpsertAlbums(
            [
                makeAlbumInput(
                    ratingKey: "album-no-art",
                    thumbPath: nil,
                    dateModified: Date(timeIntervalSince1970: 1_000)
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        try await repository.batchUpsertAlbums(
            [
                makeAlbumInput(
                    ratingKey: "album-no-art",
                    thumbPath: nil,
                    dateModified: Date(timeIntervalSince1970: 1_001)
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await repository.upsertArtist(
            ratingKey: "artist-no-art",
            key: "/library/metadata/artist-no-art",
            name: "Artist No Art",
            summary: nil,
            thumbPath: nil,
            artPath: nil,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_000),
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await repository.upsertArtist(
            ratingKey: "artist-no-art",
            key: "/library/metadata/artist-no-art",
            name: "Artist No Art",
            summary: nil,
            thumbPath: nil,
            artPath: nil,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_001),
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testArtworkDownloadManagerRejectsStaleIdentitySidecarsForAllArtworkTypes() async throws {
        let manager = ArtworkDownloadManager()
        var cleanupURLs: [URL] = []
        defer {
            cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        for type in [ArtworkType.album, .artist, .playlist, .track] {
            let ratingKey = "identity-\(type.rawValue)-\(UUID().uuidString)"
            let artworkURL = ArtworkDownloadManager.artworkDirectory
                .appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
            let identityURL = artworkURL
                .deletingPathExtension()
                .appendingPathExtension("identity.json")
            cleanupURLs.append(contentsOf: [artworkURL, identityURL])

            let sourcePath = "/library/metadata/\(ratingKey)/thumb/1000"
            try Data("image".utf8).write(to: artworkURL)
            let identity = ArtworkIdentity(
                ratingKey: ratingKey,
                type: type,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000
            )
            try JSONEncoder().encode(identity).write(to: identityURL)

            let matchingPath = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000
            )
            XCTAssertEqual(matchingPath, artworkURL.path)

            let changedPath = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourcePath: "/library/metadata/\(ratingKey)/thumb/1001",
                dateModifiedSeconds: 1_000
            )
            XCTAssertNil(changedPath)

            let changedDate = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_001
            )
            XCTAssertNil(changedDate)
        }
    }

    func testArtworkDownloadManagerAcceptsLegacyArtworkWithoutIdentitySidecar() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "legacy-\(UUID().uuidString)"
        let artworkURL = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_playlist.jpg")
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
        }

        try Data("legacy image".utf8).write(to: artworkURL)

        let localPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .playlist,
            sourcePath: "/playlists/playlist-1/composite/new",
            dateModifiedSeconds: 1_001
        )

        XCTAssertEqual(localPath, artworkURL.path)
    }

    func testArtworkDownloadManagerRejectsIdentityForDifferentRatingKeyOrType() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "identity-mismatch-\(UUID().uuidString)"
        let artworkURL = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_artist.jpg")
        let identityURL = artworkURL
            .deletingPathExtension()
            .appendingPathExtension("identity.json")
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
            try? FileManager.default.removeItem(at: identityURL)
        }

        try Data("image".utf8).write(to: artworkURL)
        let identity = ArtworkIdentity(
            ratingKey: "different-\(ratingKey)",
            type: .artist,
            sourcePath: "/library/metadata/artist-1/thumb",
            dateModifiedSeconds: 1_000
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let wrongRatingKeyPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist,
            sourcePath: "/library/metadata/artist-1/thumb",
            dateModifiedSeconds: 1_000
        )
        XCTAssertNil(wrongRatingKeyPath)

        try JSONEncoder().encode(
            ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: "/library/metadata/artist-1/thumb",
                dateModifiedSeconds: 1_000
            )
        ).write(to: identityURL)

        let wrongTypePath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist,
            sourcePath: "/library/metadata/artist-1/thumb",
            dateModifiedSeconds: 1_000
        )
        XCTAssertNil(wrongTypePath)
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

    private func makeAlbumInput(
        ratingKey: String,
        thumbPath: String?,
        dateModified: Date?
    ) -> AlbumUpsertInput {
        AlbumUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            title: "Album \(ratingKey)",
            artistName: "Artist",
            albumArtist: "Artist",
            artistRatingKey: nil,
            summary: nil,
            thumbPath: thumbPath,
            artPath: nil,
            year: 2024,
            trackCount: 1,
            dateAdded: nil,
            dateModified: dateModified,
            rating: nil
        )
    }
}
