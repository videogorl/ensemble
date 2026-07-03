import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    func testFetchTrackArtworkFallbackFindsEquivalentArtworkBackedDuplicate() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)

        _ = try await repository.upsertTrack(
            ratingKey: "track-1",
            key: "/library/metadata/track-1",
            title: "2085",
            artistName: "AJR",
            albumName: "The Maybe Man",
            albumRatingKey: nil,
            trackNumber: 13,
            discNumber: 1,
            duration: 331_000,
            thumbPath: "/library/metadata/album-1/thumb/1000",
            streamKey: "/library/parts/track-1/file.m4a",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: "plex/account/server/library-a"
        )

        _ = try await repository.upsertTrack(
            ratingKey: "track-2",
            key: "/library/metadata/track-2",
            title: "2085",
            artistName: "AJR",
            albumName: "The Maybe Man",
            albumRatingKey: nil,
            trackNumber: 13,
            discNumber: 1,
            duration: 331_000,
            thumbPath: "/library/metadata/album-2/thumb/1000",
            streamKey: "/library/parts/track-2/file.m4a",
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: "plex/account/server/library-b"
        )

        let fallback = try await repository.fetchTrackArtworkFallback(
            title: "2085",
            albumName: "The Maybe Man",
            artistName: "AJR",
            excludingRatingKey: "track-1",
            excludingSourceCompositeKey: "plex/account/server/library-a"
        )

        XCTAssertEqual(fallback?.ratingKey, "track-2")
        XCTAssertEqual(fallback?.thumbPath, "/library/metadata/album-2/thumb/1000")
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

    func testBatchArtistUpsertRecordsArtworkInvalidationWhenMetadataDateChanges() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        try await repository.batchUpsertArtists(
            [
                makeArtistInput(
                    ratingKey: "artist-1",
                    thumbPath: "/library/metadata/artist-1/thumb",
                    dateModified: Date(timeIntervalSince1970: 1_000)
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        try await repository.batchUpsertArtists(
            [
                makeArtistInput(
                    ratingKey: "artist-1",
                    thumbPath: "/library/metadata/artist-1/thumb",
                    dateModified: Date(timeIntervalSince1970: 1_001)
                )
            ],
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

    func testBatchAlbumAndArtistUpsertsDoNotRecordDateOnlyInvalidationWithoutArtworkPath() async throws {
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

        try await repository.batchUpsertArtists(
            [
                makeArtistInput(
                    ratingKey: "artist-no-art",
                    thumbPath: nil,
                    dateModified: Date(timeIntervalSince1970: 1_000)
                )
            ],
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        try await repository.batchUpsertArtists(
            [
                makeArtistInput(
                    ratingKey: "artist-no-art",
                    thumbPath: nil,
                    dateModified: Date(timeIntervalSince1970: 1_001)
                )
            ],
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

    func testArtworkDownloadManagerReturnsStaleIdentityForOfflineFallback() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "stale-\(UUID().uuidString)"
        let artworkURL = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_album.jpg")
        let identityURL = artworkURL
            .deletingPathExtension()
            .appendingPathExtension("identity.json")
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
            try? FileManager.default.removeItem(at: identityURL)
        }

        try Data("image".utf8).write(to: artworkURL)
        let identity = ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/library/metadata/\(ratingKey)/thumb/1000",
            dateModifiedSeconds: 1_000
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let strictPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/library/metadata/\(ratingKey)/thumb/1001",
            dateModifiedSeconds: 1_001
        )
        XCTAssertNil(strictPath)

        let stalePath = try await manager.getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album
        )
        XCTAssertEqual(stalePath, artworkURL.path)

        let wrongTypePath = try await manager.getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist
        )
        XCTAssertNil(wrongTypePath)
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

    func testArtworkDownloadManagerTreatsServerLimitedDetailAttemptAsCached() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "server-limited-\(UUID().uuidString)"
        let artworkURL = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_album.jpg")
        let identityURL = artworkURL
            .deletingPathExtension()
            .appendingPathExtension("identity.json")
        defer {
            try? FileManager.default.removeItem(at: artworkURL)
            try? FileManager.default.removeItem(at: identityURL)
        }

        try makeJPEG(width: 500, height: 500, at: artworkURL)
        let identity = ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/library/metadata/\(ratingKey)/thumb",
            dateModifiedSeconds: 1_000,
            requestedPixelDimension: 1_000
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let exists = await manager.localArtworkExists(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/library/metadata/\(ratingKey)/thumb",
            dateModifiedSeconds: 1_000,
            minimumPixelDimension: 1_000
        )
        XCTAssertTrue(exists)

        let changedIdentityExists = await manager.localArtworkExists(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/library/metadata/\(ratingKey)/thumb/new",
            dateModifiedSeconds: 1_000,
            minimumPixelDimension: 1_000
        )
        XCTAssertFalse(changedIdentityExists)
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

    private func makeArtistInput(
        ratingKey: String,
        thumbPath: String?,
        dateModified: Date?
    ) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            name: "Artist \(ratingKey)",
            summary: nil,
            thumbPath: thumbPath,
            artPath: nil,
            dateAdded: nil,
            dateModified: dateModified
        )
    }
}

private func makeJPEG(width: Int, height: Int, at url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "LibraryRepositoryTests", code: 1)
    }

    context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
          ) else {
        throw NSError(domain: "LibraryRepositoryTests", code: 2)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "LibraryRepositoryTests", code: 3)
    }
}
