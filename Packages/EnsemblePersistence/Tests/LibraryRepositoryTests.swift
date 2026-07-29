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

    func testArtworkInvalidationBufferScopesSourcesAndLetsRemovalDominate() {
        let buffer = ArtworkInvalidationBuffer()
        let sourceA = "plex:account:server:library-a"
        let sourceB = "plex:account:server:library-b"
        buffer.record(ArtworkInvalidationInfo(
            ratingKey: "shared",
            type: .album,
            reason: .pathChanged,
            sourceCompositeKey: sourceA
        ))
        buffer.record(ArtworkInvalidationInfo(
            ratingKey: "shared",
            type: .album,
            reason: .metadataModified,
            sourceCompositeKey: sourceB
        ))
        buffer.record(ArtworkInvalidationInfo(
            ratingKey: "shared",
            type: .album,
            reason: .removed,
            sourceCompositeKey: sourceA
        ))

        XCTAssertEqual(Set(buffer.drain()), [
            ArtworkInvalidationInfo(
                ratingKey: "shared",
                type: .album,
                reason: .removed,
                sourceCompositeKey: sourceA
            ),
            ArtworkInvalidationInfo(
                ratingKey: "shared",
                type: .album,
                reason: .metadataModified,
                sourceCompositeKey: sourceB
            )
        ])
    }

    func testArtworkInvalidationBufferDiscardsOnlyRequestedSource() {
        let buffer = ArtworkInvalidationBuffer()
        let sourceA = "plex:account:server:library-a"
        let sourceB = "plex:account:server:library-b"
        for sourceKey in [sourceA, sourceB] {
            buffer.record(ArtworkInvalidationInfo(
                ratingKey: "shared",
                type: .album,
                reason: .pathChanged,
                sourceCompositeKey: sourceKey
            ))
        }

        buffer.discard(sourceCompositeKey: sourceA)

        XCTAssertEqual(buffer.drain(), [
            ArtworkInvalidationInfo(
                ratingKey: "shared",
                type: .album,
                reason: .pathChanged,
                sourceCompositeKey: sourceB
            )
        ])
    }

    func testLibraryRepositoryUsesInMemoryStore() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let tracks = try await repository.fetchTracks()
        XCTAssertTrue(tracks.isEmpty)
    }

    func testNameLookupWithExplicitEmptySourceSetReturnsNothing() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        try await repository.batchUpsertTracks(
            [makeTrackInput(ratingKey: "needle")],
            sourceCompositeKey: "plex:account:server:library"
        )

        let tracks = try await repository.findTracksByTitle(
            "Track needle",
            sourceCompositeKeys: []
        )

        XCTAssertTrue(tracks.isEmpty)
    }

    func testUnscopedLibraryItemLookupsFailClosedEvenWithUniqueOwner() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let ratingKey = "shared"

        try await repository.batchUpsertArtists(
            [makeArtistInput(ratingKey: ratingKey, thumbPath: nil, dateModified: nil)],
            sourceCompositeKey: sourceA
        )
        try await repository.batchUpsertAlbums(
            [makeAlbumInput(ratingKey: ratingKey, thumbPath: nil, dateModified: nil)],
            sourceCompositeKey: sourceA
        )
        try await repository.batchUpsertTracks(
            [makeTrackInput(ratingKey: ratingKey)],
            sourceCompositeKey: sourceA
        )

        let unscopedArtist = try await repository.fetchArtist(ratingKey: ratingKey)
        let unscopedAlbum = try await repository.fetchAlbum(ratingKey: ratingKey)
        let unscopedTrack = try await repository.fetchTrack(ratingKey: ratingKey)
        let scopedArtist = try await repository.fetchArtist(ratingKey: ratingKey, sourceCompositeKey: sourceA)
        let scopedAlbum = try await repository.fetchAlbum(ratingKey: ratingKey, sourceCompositeKey: sourceA)
        let scopedTrack = try await repository.fetchTrack(ratingKey: ratingKey, sourceCompositeKey: sourceA)

        XCTAssertNil(unscopedArtist)
        XCTAssertNil(unscopedAlbum)
        XCTAssertNil(unscopedTrack)
        XCTAssertEqual(scopedArtist?.sourceCompositeKey, sourceA)
        XCTAssertEqual(scopedAlbum?.sourceCompositeKey, sourceA)
        XCTAssertEqual(scopedTrack?.sourceCompositeKey, sourceA)
    }

    func testRefreshContextPreservesRegisteredObjects() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        try await repository.batchUpsertTracks(
            [makeTrackInput(ratingKey: "held-track")],
            sourceCompositeKey: sourceKey
        )
        let fetchedTrack = try await repository.fetchTrack(
            ratingKey: "held-track",
            sourceCompositeKey: sourceKey
        )
        let heldTrack = try XCTUnwrap(fetchedTrack)

        for _ in 0..<20 {
            await repository.refreshContext()
        }

        XCTAssertEqual(heldTrack.ratingKey, "held-track")
        XCTAssertNotNil(heldTrack.managedObjectContext)
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

    func testFetchTracksBatchUsesSourceScopedReferences() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "shared"),
            makeTrackInput(ratingKey: "only-a")
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "shared"),
            makeTrackInput(ratingKey: "only-b")
        ], sourceCompositeKey: sourceB)

        let references = [
            OfflineTrackReference(trackRatingKey: "shared", trackSourceCompositeKey: sourceA),
            OfflineTrackReference(trackRatingKey: "shared", trackSourceCompositeKey: sourceB),
            OfflineTrackReference(trackRatingKey: "only-a", trackSourceCompositeKey: sourceA),
            OfflineTrackReference(trackRatingKey: "missing", trackSourceCompositeKey: sourceA)
        ]

        let tracksByKey = try await repository.fetchTracksBatch(forReferences: references)

        XCTAssertEqual(tracksByKey.count, 3)
        XCTAssertEqual(tracksByKey["\(sourceA)|shared"]?.sourceCompositeKey, sourceA)
        XCTAssertEqual(tracksByKey["\(sourceB)|shared"]?.sourceCompositeKey, sourceB)
        XCTAssertEqual(tracksByKey["\(sourceA)|only-a"]?.ratingKey, "only-a")
        XCTAssertNil(tracksByKey["\(sourceA)|missing"])
    }

    func testFetchTrackStatsBySourceAggregatesCountsAndDuration() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"
        let sourceC = "plex/account/server/library-c"

        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "a-1", duration: 90_000),
            makeTrackInput(ratingKey: "a-2", duration: 120_000)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "b-1", duration: 30_000)
        ], sourceCompositeKey: sourceB)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "c-1", duration: 10_000)
        ], sourceCompositeKey: sourceC)

        let stats = try await repository.fetchTrackStatsBySource(sourceCompositeKeys: [sourceA, sourceB])
        let emptyStats = try await repository.fetchTrackStatsBySource(sourceCompositeKeys: [])

        XCTAssertEqual(stats[sourceA], TrackSourceStats(trackCount: 2, totalDurationMs: 210_000))
        XCTAssertEqual(stats[sourceB], TrackSourceStats(trackCount: 1, totalDurationMs: 30_000))
        XCTAssertNil(stats[sourceC])
        XCTAssertTrue(emptyStats.isEmpty)
    }

    func testFetchArtworkThumbPathsUseSourceScopedReferences() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"
        let sourceC = "plex/account/server/library-c"

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: "/album/source-a.jpg", dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: "/album/source-b.jpg", dateModified: nil)
        ], sourceCompositeKey: sourceB)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: "/album/source-c.jpg", dateModified: nil)
        ], sourceCompositeKey: sourceC)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "shared", thumbPath: "/artist/source-a.jpg", dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "shared", thumbPath: "/artist/source-b.jpg", dateModified: nil)
        ], sourceCompositeKey: sourceB)

        let references = [
            SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceA),
            SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceB),
            SourceScopedArtworkReference(ratingKey: "missing", sourceCompositeKey: sourceA)
        ]

        let albumThumbPaths = try await repository.fetchAlbumThumbPaths(forReferences: references)
        let artistThumbPaths = try await repository.fetchArtistThumbPaths(forReferences: references)

        XCTAssertEqual(albumThumbPaths.count, 2)
        XCTAssertEqual(albumThumbPaths["\(sourceA)|shared"], "/album/source-a.jpg")
        XCTAssertEqual(albumThumbPaths["\(sourceB)|shared"], "/album/source-b.jpg")
        XCTAssertNil(albumThumbPaths["\(sourceC)|shared"])
        XCTAssertNil(albumThumbPaths["\(sourceA)|missing"])
        XCTAssertEqual(artistThumbPaths.count, 2)
        XCTAssertEqual(artistThumbPaths["\(sourceA)|shared"], "/artist/source-a.jpg")
        XCTAssertEqual(artistThumbPaths["\(sourceB)|shared"], "/artist/source-b.jpg")
        XCTAssertNil(artistThumbPaths["\(sourceA)|missing"])
    }

    func testFetchAlbumAndArtistBatchesUseSourceScopedReferences() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"
        let sourceC = "plex/account/server/library-c"

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceC)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        let references = [
            SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceA),
            SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceB),
            SourceScopedArtworkReference(ratingKey: "missing", sourceCompositeKey: sourceA)
        ]

        let albumsByKey = try await repository.fetchAlbums(forReferences: references)
        let artistsByKey = try await repository.fetchArtists(forReferences: references)

        XCTAssertEqual(albumsByKey.count, 2)
        XCTAssertEqual(albumsByKey["\(sourceA)|shared"]?.sourceCompositeKey, sourceA)
        XCTAssertEqual(albumsByKey["\(sourceB)|shared"]?.sourceCompositeKey, sourceB)
        XCTAssertNil(albumsByKey["\(sourceC)|shared"])
        XCTAssertNil(albumsByKey["\(sourceA)|missing"])
        XCTAssertEqual(artistsByKey.count, 2)
        XCTAssertEqual(artistsByKey["\(sourceA)|shared"]?.sourceCompositeKey, sourceA)
        XCTAssertEqual(artistsByKey["\(sourceB)|shared"]?.sourceCompositeKey, sourceB)
        XCTAssertNil(artistsByKey["\(sourceA)|missing"])
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
                    reason: .pathChanged,
                    sourceCompositeKey: sourceKey
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
                    reason: .metadataModified,
                    sourceCompositeKey: sourceKey
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
        let sourceKey = "plex:account:server:library"
        var cleanupURLs: [URL] = []
        defer {
            cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        for type in [ArtworkType.album, .artist, .playlist, .track] {
            let ratingKey = "identity-\(type.rawValue)-\(UUID().uuidString)"
            let artworkURL = ArtworkDownloadManager.artworkFileURL(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceKey
            )
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
                dateModifiedSeconds: 1_000,
                sourceCompositeKey: sourceKey
            )
            try JSONEncoder().encode(identity).write(to: identityURL)

            let matchingPath = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceKey,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000
            )
            XCTAssertEqual(matchingPath, artworkURL.path)

            let changedPath = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceKey,
                sourcePath: "/library/metadata/\(ratingKey)/thumb/1001",
                dateModifiedSeconds: 1_000
            )
            XCTAssertNil(changedPath)

            let changedDate = try await manager.getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceKey,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_001
            )
            XCTAssertNil(changedDate)
        }
    }

    func testArtworkDownloadManagerReturnsStaleIdentityForOfflineFallback() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "stale-\(UUID().uuidString)"
        let sourceKey = "plex:account:server:library"
        let artworkURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )
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
            dateModifiedSeconds: 1_000,
            sourceCompositeKey: sourceKey
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let strictPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey,
            sourcePath: "/library/metadata/\(ratingKey)/thumb/1001",
            dateModifiedSeconds: 1_001
        )
        XCTAssertNil(strictPath)

        let stalePath = try await manager.getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )
        XCTAssertEqual(stalePath, artworkURL.path)

        let wrongTypePath = try await manager.getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist,
            sourceCompositeKey: sourceKey
        )
        XCTAssertNil(wrongTypePath)
    }

    func testArtworkDownloadManagerPurgesPreV2CacheOnceAndPreservesScopedEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacyArtworkURL = directory.appendingPathComponent("legacy_album.jpg")
        let legacyIdentityURL = directory.appendingPathComponent("legacy_album.identity.json")
        let scopedArtworkURL = directory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: "album",
                type: .album,
                sourceCompositeKey: "plex:account:server:library"
            )
        )
        let scopedIdentityURL = ArtworkDownloadManager.identityURL(for: scopedArtworkURL)
        try Data("legacy".utf8).write(to: legacyArtworkURL)
        try Data("legacy identity".utf8).write(to: legacyIdentityURL)
        try seedArtwork(
            data: Data("scoped".utf8),
            at: scopedArtworkURL,
            identity: ArtworkIdentity(
                ratingKey: "album",
                type: .album,
                sourcePath: "/artwork",
                dateModifiedSeconds: nil,
                sourceCompositeKey: "plex:account:server:library"
            )
        )

        let removedCount = try ArtworkDownloadManager.purgeLegacyArtworkCacheIfNeeded(in: directory)

        XCTAssertEqual(removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyArtworkURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyIdentityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedArtworkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedIdentityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ArtworkDownloadManager.cacheVersionMarkerName).path
        ))
        XCTAssertNil(try ArtworkDownloadManager.purgeLegacyArtworkCacheIfNeeded(in: directory))
    }

    func testArtworkDownloadManagerTreatsServerLimitedDetailAttemptAsCached() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "server-limited-\(UUID().uuidString)"
        let sourceKey = "plex:account:server:library"
        let artworkURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )
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
            requestedPixelDimension: 1_000,
            sourceCompositeKey: sourceKey
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let exists = await manager.localArtworkExists(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey,
            sourcePath: "/library/metadata/\(ratingKey)/thumb",
            dateModifiedSeconds: 1_000,
            minimumPixelDimension: 1_000
        )
        XCTAssertTrue(exists)

        let changedIdentityExists = await manager.localArtworkExists(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey,
            sourcePath: "/library/metadata/\(ratingKey)/thumb/new",
            dateModifiedSeconds: 1_000,
            minimumPixelDimension: 1_000
        )
        XCTAssertFalse(changedIdentityExists)
    }

    func testArtworkDownloadManagerRejectsIdentityForDifferentRatingKeyOrType() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "identity-mismatch-\(UUID().uuidString)"
        let sourceKey = "plex:account:server:library"
        let artworkURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .artist,
            sourceCompositeKey: sourceKey
        )
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
            dateModifiedSeconds: 1_000,
            sourceCompositeKey: sourceKey
        )
        try JSONEncoder().encode(identity).write(to: identityURL)

        let wrongRatingKeyPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist,
            sourceCompositeKey: sourceKey,
            sourcePath: "/library/metadata/artist-1/thumb",
            dateModifiedSeconds: 1_000
        )
        XCTAssertNil(wrongRatingKeyPath)

        try JSONEncoder().encode(
            ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: "/library/metadata/artist-1/thumb",
                dateModifiedSeconds: 1_000,
                sourceCompositeKey: sourceKey
            )
        ).write(to: identityURL)

        let wrongTypePath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .artist,
            sourceCompositeKey: sourceKey,
            sourcePath: "/library/metadata/artist-1/thumb",
            dateModifiedSeconds: 1_000
        )
        XCTAssertNil(wrongTypePath)
    }

    func testArtworkDownloadManagerSeparatesAndCleansEqualKeysAcrossSources() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "album/同じ:\(UUID().uuidString)"
        let sourceA = "plex:account/α:server:library-one"
        let sourceB = "appleMusic:device:local:library-two"
        let sourcePath = "/artwork/shared"
        let urlA = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceA
        )
        let urlB = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceB
        )
        defer {
            try? manager.deleteArtwork(forSourceCompositeKey: sourceA)
            try? manager.deleteArtwork(forSourceCompositeKey: sourceB)
        }

        XCTAssertNotEqual(urlA, urlB)
        XCTAssertNil(urlA.lastPathComponent.range(of: "[^A-Za-z0-9_.-]", options: .regularExpression))
        XCTAssertNil(urlB.lastPathComponent.range(of: "[^A-Za-z0-9_.-]", options: .regularExpression))
        try seedArtwork(
            data: Data("source-a".utf8),
            at: urlA,
            identity: ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000,
                sourceCompositeKey: sourceA
            )
        )
        try seedArtwork(
            data: Data("source-b".utf8),
            at: urlB,
            identity: ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000,
                sourceCompositeKey: sourceB
            )
        )

        let pathA = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceA,
            sourcePath: sourcePath,
            dateModifiedSeconds: 1_000
        )
        let pathB = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceB,
            sourcePath: sourcePath,
            dateModifiedSeconds: 1_000
        )
        XCTAssertEqual(pathA, urlA.path)
        XCTAssertEqual(pathB, urlB.path)
        XCTAssertEqual(try Data(contentsOf: urlA), Data("source-a".utf8))
        XCTAssertEqual(try Data(contentsOf: urlB), Data("source-b".utf8))

        try manager.deleteArtwork(forSourceCompositeKey: sourceA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArtworkDownloadManager.identityURL(for: urlA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ArtworkDownloadManager.identityURL(for: urlB).path))
    }

    func testArtworkDownloadManagerNeverReadsWritesOrMigratesPreV2Artwork() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "legacy-\(UUID().uuidString)"
        let sourceKey = "plex:account:server:library"
        let sourcePath = "/library/metadata/\(ratingKey)/thumb"
        let legacyURL = ArtworkDownloadManager.artworkFileURL(ratingKey: ratingKey, type: .album)
        let scopedURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )
        defer {
            manager.deleteArtwork(ratingKey: ratingKey, type: .album)
            try? manager.deleteArtwork(forSourceCompositeKey: sourceKey)
        }
        try seedArtwork(
            data: Data("legacy".utf8),
            at: legacyURL,
            identity: ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: sourcePath,
                dateModifiedSeconds: 1_000,
                sourceCompositeKey: sourceKey
            )
        )

        let legacyPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: sourcePath,
            dateModifiedSeconds: 1_000
        )
        let scopedPath = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey,
            sourcePath: sourcePath,
            dateModifiedSeconds: 1_000
        )
        let stalePath = try await manager.getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )

        XCTAssertNil(legacyPath)
        XCTAssertNil(scopedPath)
        XCTAssertNil(stalePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopedURL.path))
        do {
            try await manager.downloadAndCacheArtwork(
                from: try XCTUnwrap(URL(string: "https://example.com/artwork.jpg")),
                ratingKey: ratingKey,
                type: .album
            )
            XCTFail("Expected unscoped durable artwork writes to be rejected")
        } catch ArtworkDownloadError.noArtworkPath {}
    }

    func testArtworkDownloadManagerRejectsScopedIdentityForAnotherSource() async throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "scoped-mismatch-\(UUID().uuidString)"
        let sourceA = "plex:account-a:server:library"
        let sourceB = "plex:account-b:server:library"
        let scopedURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceA
        )
        defer {
            try? manager.deleteArtwork(forSourceCompositeKey: sourceA)
            try? manager.deleteArtwork(forSourceCompositeKey: sourceB)
        }
        try seedArtwork(
            data: Data("wrong-source".utf8),
            at: scopedURL,
            identity: ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: "/artwork",
                dateModifiedSeconds: nil,
                sourceCompositeKey: sourceB
            )
        )

        let path = try await manager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceA,
            sourcePath: "/artwork",
            dateModifiedSeconds: nil
        )

        XCTAssertNil(path)
    }

    func testArtworkDownloadManagerUnscopedDeletionCannotRemoveScopedArtwork() throws {
        let manager = ArtworkDownloadManager()
        let ratingKey = "delete-scope-\(UUID().uuidString)"
        let sourceKey = "plex:account:server:library"
        let scopedURL = ArtworkDownloadManager.artworkFileURL(
            ratingKey: ratingKey,
            type: .album,
            sourceCompositeKey: sourceKey
        )
        defer { try? manager.deleteArtwork(forSourceCompositeKey: sourceKey) }
        try seedArtwork(
            data: Data("scoped".utf8),
            at: scopedURL,
            identity: ArtworkIdentity(
                ratingKey: ratingKey,
                type: .album,
                sourcePath: "/artwork",
                dateModifiedSeconds: nil,
                sourceCompositeKey: sourceKey
            )
        )

        manager.deleteArtwork(ratingKey: ratingKey, type: .album)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ArtworkDownloadManager.identityURL(for: scopedURL).path))
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

    func testOrphanRemovalKeepsValidAndOtherSourceLibraryItems() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "keep-artist", thumbPath: nil, dateModified: nil),
            makeArtistInput(ratingKey: "drop-artist", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "drop-artist", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "keep-album", thumbPath: nil, dateModified: nil),
            makeAlbumInput(ratingKey: "drop-album", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "drop-album", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "keep-track"),
            makeTrackInput(ratingKey: "drop-track")
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "drop-track")
        ], sourceCompositeKey: sourceB)

        let removedArtists = try await repository.removeOrphanedArtists(notIn: ["keep-artist"], forSource: sourceA)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: ["keep-album"], forSource: sourceA)
        let removedTracks = try await repository.removeOrphanedTracks(notIn: ["keep-track"], forSource: sourceA)

        let artists = try await repository.fetchArtists()
        let albums = try await repository.fetchAlbums()
        let keepTrack = try await repository.fetchTrack(ratingKey: "keep-track", sourceCompositeKey: sourceA)
        let otherSourceTrack = try await repository.fetchTrack(ratingKey: "drop-track", sourceCompositeKey: sourceB)
        let removedTrack = try await repository.fetchTrack(ratingKey: "drop-track", sourceCompositeKey: sourceA)

        XCTAssertEqual(removedArtists, 1)
        XCTAssertEqual(removedAlbums, 1)
        XCTAssertEqual(removedTracks, 1)
        XCTAssertEqual(Set(artists.map { "\($0.sourceCompositeKey ?? "")|\($0.ratingKey)" }), [
            "\(sourceA)|keep-artist",
            "\(sourceB)|drop-artist"
        ])
        XCTAssertEqual(Set(albums.map { "\($0.sourceCompositeKey ?? "")|\($0.ratingKey)" }), [
            "\(sourceA)|keep-album",
            "\(sourceB)|drop-album"
        ])
        XCTAssertNotNil(keepTrack)
        XCTAssertNotNil(otherSourceTrack)
        XCTAssertNil(removedTrack)
        XCTAssertEqual(Set(repository.drainArtworkInvalidationInfo()), [
            ArtworkInvalidationInfo(
                ratingKey: "drop-artist",
                type: .artist,
                reason: .removed,
                sourceCompositeKey: sourceA
            ),
            ArtworkInvalidationInfo(
                ratingKey: "drop-album",
                type: .album,
                reason: .removed,
                sourceCompositeKey: sourceA
            ),
            ArtworkInvalidationInfo(
                ratingKey: "drop-track",
                type: .track,
                reason: .removed,
                sourceCompositeKey: sourceA
            )
        ])
    }

    func testArtistAndAlbumFetchesCanUseDirectSourceScope() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist-a", thumbPath: nil, dateModified: nil),
            makeArtistInput(ratingKey: "artist-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist-b", thumbPath: nil, dateModified: nil),
            makeArtistInput(ratingKey: "artist-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album-a", thumbPath: nil, dateModified: nil),
            makeAlbumInput(ratingKey: "album-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album-b", thumbPath: nil, dateModified: nil),
            makeAlbumInput(ratingKey: "album-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        let sourceAArtists = try await repository.fetchArtists(forSource: sourceA)
        let sourceAAlbums = try await repository.fetchAlbums(forSource: sourceA)

        XCTAssertEqual(Set(sourceAArtists.compactMap(\.sourceCompositeKey)), [sourceA])
        XCTAssertEqual(Set(sourceAArtists.map(\.ratingKey)), ["artist-a", "artist-shared"])
        XCTAssertEqual(Set(sourceAAlbums.compactMap(\.sourceCompositeKey)), [sourceA])
        XCTAssertEqual(Set(sourceAAlbums.map(\.ratingKey)), ["album-a", "album-shared"])
    }

    func testLibraryMetadataCountsUseDirectSourceScope() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist-a", thumbPath: nil, dateModified: nil),
            makeArtistInput(ratingKey: "artist-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist-b", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album-a", thumbPath: nil, dateModified: nil),
            makeAlbumInput(ratingKey: "album-shared", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album-b", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceB)

        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track-a"),
            makeTrackInput(ratingKey: "track-shared")
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track-b")
        ], sourceCompositeKey: sourceB)

        let allArtistCount = try await repository.countArtists(sourceCompositeKeys: nil)
        let allAlbumCount = try await repository.countAlbums(sourceCompositeKeys: nil)
        let allTrackCount = try await repository.countTracks(sourceCompositeKeys: nil)
        let sourceAArtistCount = try await repository.countArtists(sourceCompositeKeys: [sourceA])
        let sourceAAlbumCount = try await repository.countAlbums(sourceCompositeKeys: [sourceA])
        let sourceATrackCount = try await repository.countTracks(sourceCompositeKeys: [sourceA])
        let combinedArtistCount = try await repository.countArtists(sourceCompositeKeys: [sourceA, sourceB])
        let combinedAlbumCount = try await repository.countAlbums(sourceCompositeKeys: [sourceA, sourceB])
        let combinedTrackCount = try await repository.countTracks(sourceCompositeKeys: [sourceA, sourceB])
        let emptyArtistCount = try await repository.countArtists(sourceCompositeKeys: [])
        let emptyAlbumCount = try await repository.countAlbums(sourceCompositeKeys: [])
        let emptyTrackCount = try await repository.countTracks(sourceCompositeKeys: [])

        XCTAssertEqual(allArtistCount, 3)
        XCTAssertEqual(allAlbumCount, 3)
        XCTAssertEqual(allTrackCount, 3)
        XCTAssertEqual(sourceAArtistCount, 2)
        XCTAssertEqual(sourceAAlbumCount, 2)
        XCTAssertEqual(sourceATrackCount, 2)
        XCTAssertEqual(combinedArtistCount, 3)
        XCTAssertEqual(combinedAlbumCount, 3)
        XCTAssertEqual(combinedTrackCount, 3)
        XCTAssertEqual(emptyArtistCount, 0)
        XCTAssertEqual(emptyAlbumCount, 0)
        XCTAssertEqual(emptyTrackCount, 0)
    }

    func testSyncMetadataLookupsUseDirectSourceScope() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"
        let dateA = Date(timeIntervalSince1970: 1_000)
        let dateB = Date(timeIntervalSince1970: 2_000)
        let artistInputA = makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: dateA)

        try await repository.batchUpsertArtists([artistInputA], sourceCompositeKey: sourceA)
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: dateB)
        ], sourceCompositeKey: sourceB)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: dateA)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", dateModified: dateA, rating: 5)
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", dateModified: dateB, rating: 1)
        ], sourceCompositeKey: sourceB)

        let artistMetadata = try await repository.fetchArtistSyncMetadata(forSource: sourceA)
        let artistTimestamps = try await repository.fetchArtistTimestamps(forSource: sourceA)
        let albumTimestamps = try await repository.fetchAlbumTimestamps(forSource: sourceA)
        let trackTimestamps = try await repository.fetchTrackTimestamps(forSource: sourceA)
        let trackRatings = try await repository.fetchTrackRatings(forSource: sourceA)

        XCTAssertEqual(artistMetadata, ["artist": ArtistSyncMetadata(artistInputA)])
        XCTAssertEqual(artistTimestamps, ["artist": dateA])
        XCTAssertEqual(albumTimestamps, ["album": dateA])
        XCTAssertEqual(trackTimestamps, ["track": dateA])
        XCTAssertEqual(trackRatings, ["track": 5])
    }

    func testGenreCoverageAndCleanupUseDirectSourceScope() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album-a", thumbPath: nil, dateModified: nil, genreNames: "Rock")
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track-a", genreNames: "Rock")
        ], sourceCompositeKey: sourceA)
        _ = try await repository.upsertGenre(
            ratingKey: "genre-keep",
            key: "/library/sections/1/genre/keep",
            title: "Rock",
            sourceCompositeKey: sourceA
        )
        _ = try await repository.upsertGenre(
            ratingKey: "genre-drop",
            key: "/library/sections/1/genre/drop",
            title: "Dusty",
            sourceCompositeKey: sourceA
        )
        _ = try await repository.upsertGenre(
            ratingKey: "genre-drop",
            key: "/library/sections/2/genre/drop",
            title: "Dusty",
            sourceCompositeKey: sourceB
        )

        let fetchedStats = try await repository.fetchGenreCoverageStats(forSource: sourceA)
        let stats = try XCTUnwrap(fetchedStats)
        let removed = try await repository.removeOrphanedGenres(notIn: ["genre-keep"], forSource: sourceA)
        let genres = try await repository.fetchGenres()

        XCTAssertEqual(stats, GenreCoverageStats(
            albumCount: 1,
            albumsWithGenreNames: 1,
            trackCount: 1,
            tracksWithGenreNames: 1,
            genreCatalogCount: 2
        ))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(Set(genres.map { "\($0.sourceCompositeKey ?? "")|\($0.ratingKey ?? "")" }), [
            "\(sourceA)|genre-keep",
            "\(sourceB)|genre-drop"
        ])
    }

    func testCacheSummaryCountsUseMetadataAndSourceScopes() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "plex/account/server/library"

        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: "plex",
            accountId: "account",
            serverId: "server",
            libraryId: "library",
            displayName: "Library",
            accountName: "Account"
        )
        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track")
        ], sourceCompositeKey: sourceKey)
        _ = try await repository.upsertGenre(
            ratingKey: "genre",
            key: "/library/sections/1/genre/genre",
            title: "Genre",
            sourceCompositeKey: sourceKey
        )

        let metadataItemCount = try await repository.countLibraryMetadataItems()
        let sourceCount = try await repository.countMusicSources()

        XCTAssertEqual(metadataItemCount, 4)
        XCTAssertEqual(sourceCount, 1)
    }

    func testBatchUpsertsLinkSubsetRelationships() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "plex/account/server/library"

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist-1", thumbPath: nil, dateModified: nil),
            makeArtistInput(ratingKey: "artist-2", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(
                ratingKey: "album-2",
                thumbPath: nil,
                dateModified: nil,
                artistRatingKey: "artist-2"
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track-2", albumRatingKey: "album-2")
        ], sourceCompositeKey: sourceKey)

        let album = try await repository.fetchAlbum(ratingKey: "album-2", sourceCompositeKey: sourceKey)
        let track = try await repository.fetchTrack(ratingKey: "track-2", sourceCompositeKey: sourceKey)

        XCTAssertEqual(album?.artist?.ratingKey, "artist-2")
        XCTAssertEqual(track?.album?.ratingKey, "album-2")
    }

    func testBatchAlbumUpsertPreservesAndClearsReleaseFormatExplicitly() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "plex/account/server/library"

        try await repository.batchUpsertAlbums([
            makeAlbumInput(
                ratingKey: "single",
                thumbPath: nil,
                dateModified: nil,
                releaseFormat: "single",
                updatesReleaseFormat: true
            )
        ], sourceCompositeKey: sourceKey)
        var album = try await repository.fetchAlbum(ratingKey: "single", sourceCompositeKey: sourceKey)
        XCTAssertEqual(album?.releaseFormat, "single")

        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "single", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        album = try await repository.fetchAlbum(ratingKey: "single", sourceCompositeKey: sourceKey)
        XCTAssertEqual(album?.releaseFormat, "single")

        try await repository.batchUpsertAlbums([
            makeAlbumInput(
                ratingKey: "single",
                thumbPath: nil,
                dateModified: nil,
                updatesReleaseFormat: true
            )
        ], sourceCompositeKey: sourceKey)
        album = try await repository.fetchAlbum(ratingKey: "single", sourceCompositeKey: sourceKey)
        XCTAssertNil(album?.releaseFormat)
    }

    func testBatchUpsertsPersistAndPreserveItemActionCapabilities() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "apple-music:device:system:library"
        let original = Data("original-capabilities".utf8)
        let updated = Data("updated-capabilities".utf8)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil, actionCapabilitiesData: original)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, actionCapabilitiesData: original)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", actionCapabilitiesData: original)
        ], sourceCompositeKey: sourceKey)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track")
        ], sourceCompositeKey: sourceKey)

        var artist = try await repository.fetchArtist(ratingKey: "artist", sourceCompositeKey: sourceKey)
        var album = try await repository.fetchAlbum(ratingKey: "album", sourceCompositeKey: sourceKey)
        var track = try await repository.fetchTrack(ratingKey: "track", sourceCompositeKey: sourceKey)
        XCTAssertEqual(artist?.actionCapabilitiesData, original)
        XCTAssertEqual(album?.actionCapabilitiesData, original)
        XCTAssertEqual(track?.actionCapabilitiesData, original)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil, actionCapabilitiesData: updated)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, actionCapabilitiesData: updated)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", actionCapabilitiesData: updated)
        ], sourceCompositeKey: sourceKey)

        artist = try await repository.fetchArtist(ratingKey: "artist", sourceCompositeKey: sourceKey)
        album = try await repository.fetchAlbum(ratingKey: "album", sourceCompositeKey: sourceKey)
        track = try await repository.fetchTrack(ratingKey: "track", sourceCompositeKey: sourceKey)
        XCTAssertEqual(artist?.actionCapabilitiesData, updated)
        XCTAssertEqual(album?.actionCapabilitiesData, updated)
        XCTAssertEqual(track?.actionCapabilitiesData, updated)

        let artistMetadata = try await repository.fetchArtistSyncMetadata(forSource: sourceKey)
        let albumMetadata = try await repository.fetchAlbumSyncMetadata(forSource: sourceKey)
        let trackMetadata = try await repository.fetchTrackSyncMetadata(forSource: sourceKey)
        XCTAssertEqual(artistMetadata["artist"]?.actionCapabilitiesData, updated)
        XCTAssertEqual(albumMetadata["album"]?.actionCapabilitiesData, updated)
        XCTAssertEqual(trackMetadata["track"]?.actionCapabilitiesData, updated)
    }

    func testBatchUpsertsBackfillMissingDateAddedWithoutReplacingKnownDates() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "appleMusic/account/device/library"
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let laterDate = Date(timeIntervalSince1970: 2_000)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track")
        ], sourceCompositeKey: sourceKey)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil, dateAdded: originalDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, dateAdded: originalDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", dateAdded: originalDate)
        ], sourceCompositeKey: sourceKey)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil, dateAdded: laterDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, dateAdded: laterDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", dateAdded: laterDate)
        ], sourceCompositeKey: sourceKey)

        let artistMetadata = try await repository.fetchArtistSyncMetadata(forSource: sourceKey)
        let albumMetadata = try await repository.fetchAlbumSyncMetadata(forSource: sourceKey)
        let trackMetadata = try await repository.fetchTrackSyncMetadata(forSource: sourceKey)
        XCTAssertEqual(artistMetadata["artist"]?.dateAdded, originalDate)
        XCTAssertEqual(albumMetadata["album"]?.dateAdded, originalDate)
        XCTAssertEqual(trackMetadata["track"]?.dateAdded, originalDate)
    }

    func testFavoriteFetchHonorsExplicitProviderStateAndLegacyRatingFallback() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "appleMusic/account/device/library"
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "explicit-true", rating: 0, isFavorite: true),
            makeTrackInput(ratingKey: "explicit-false", rating: 10, isFavorite: false),
            makeTrackInput(ratingKey: "legacy-favorite", rating: 10),
            makeTrackInput(ratingKey: "legacy-not-favorite", rating: 0)
        ], sourceCompositeKey: sourceKey)

        let asyncIDs = Set(try await repository.fetchFavoriteTracks().map(\.ratingKey))
        let snapshotIDs = Set(try repository.fetchFavoriteTracksSnapshot().map(\.ratingKey))
        XCTAssertEqual(asyncIDs, ["explicit-true", "legacy-favorite"])
        XCTAssertEqual(snapshotIDs, asyncIDs)
    }

    func testAlbumUpsertPreservesKnownTrackCountWhenProviderOmitsIt() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "plex:account:server:library"
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, trackCount: 12)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: "/updated", dateModified: nil, trackCount: nil)
        ], sourceCompositeKey: sourceKey)

        let album = try await repository.fetchAlbum(ratingKey: "album", sourceCompositeKey: sourceKey)

        XCTAssertEqual(album?.trackCount, 12)
        XCTAssertEqual(album?.thumbPath, "/updated")
    }

    func testCompactSyncMetadataMatchesRepositoryMergeSemantics() {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let laterDate = Date(timeIntervalSince1970: 2_000)
        let album = makeAlbumInput(
            ratingKey: "album",
            thumbPath: "/art",
            dateModified: originalDate,
            dateAdded: originalDate,
            releaseFormat: "album",
            updatesReleaseFormat: true
        )
        let track = makeTrackInput(
            ratingKey: "track",
            dateModified: originalDate,
            rating: 10,
            dateAdded: originalDate,
            isFavorite: true
        )
        let artist = makeArtistInput(
            ratingKey: "artist",
            thumbPath: "/artist-art",
            dateModified: originalDate,
            dateAdded: originalDate
        )

        XCTAssertTrue(ArtistSyncMetadata(artist).matches(makeArtistInput(
            ratingKey: "artist",
            thumbPath: "/artist-art",
            dateModified: originalDate,
            dateAdded: laterDate
        )))
        XCTAssertFalse(ArtistSyncMetadata(artist).matches(makeArtistInput(
            ratingKey: "artist",
            thumbPath: "/artist-art",
            dateModified: originalDate,
            dateAdded: laterDate,
            updatesDateAdded: true
        )))

        XCTAssertTrue(AlbumSyncMetadata(album).matches(makeAlbumInput(
            ratingKey: "album",
            thumbPath: "/art",
            dateModified: originalDate,
            dateAdded: laterDate,
            releaseFormat: "ignored",
            updatesReleaseFormat: false
        )))
        XCTAssertFalse(AlbumSyncMetadata(album).matches(makeAlbumInput(
            ratingKey: "album",
            thumbPath: "/art",
            dateModified: originalDate,
            dateAdded: laterDate,
            releaseFormat: "album",
            updatesReleaseFormat: true,
            updatesDateAdded: true
        )))
        XCTAssertFalse(AlbumSyncMetadata(album).matches(makeAlbumInput(
            ratingKey: "album",
            thumbPath: "/art",
            dateModified: originalDate,
            dateAdded: laterDate,
            releaseFormat: "single",
            updatesReleaseFormat: true
        )))
        XCTAssertTrue(TrackSyncMetadata(track).matches(makeTrackInput(
            ratingKey: "track",
            dateModified: originalDate,
            rating: 10,
            dateAdded: laterDate
        )))
        XCTAssertFalse(TrackSyncMetadata(track).matches(makeTrackInput(
            ratingKey: "track",
            dateModified: originalDate,
            rating: 10,
            dateAdded: laterDate,
            updatesDateAdded: true
        )))
        XCTAssertFalse(TrackSyncMetadata(track).matches(makeTrackInput(
            ratingKey: "track",
            dateModified: originalDate,
            rating: 10,
            dateAdded: laterDate,
            isFavorite: false
        )))
    }

    func testAuthoritativeDateAddedInputsReplaceExistingDates() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceKey = "apple-music:device:system:library"
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let exactDate = Date(timeIntervalSince1970: 2_000)

        try await repository.batchUpsertArtists([
            makeArtistInput(ratingKey: "artist", thumbPath: nil, dateModified: nil, dateAdded: oldDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(ratingKey: "album", thumbPath: nil, dateModified: nil, dateAdded: oldDate)
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(ratingKey: "track", dateAdded: oldDate)
        ], sourceCompositeKey: sourceKey)

        try await repository.batchUpsertArtists([
            makeArtistInput(
                ratingKey: "artist",
                thumbPath: nil,
                dateModified: nil,
                dateAdded: exactDate,
                updatesDateAdded: true
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            makeAlbumInput(
                ratingKey: "album",
                thumbPath: nil,
                dateModified: nil,
                dateAdded: exactDate,
                updatesDateAdded: true
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            makeTrackInput(
                ratingKey: "track",
                dateAdded: exactDate,
                updatesDateAdded: true
            )
        ], sourceCompositeKey: sourceKey)

        let artist = try await repository.fetchArtist(
            ratingKey: "artist",
            sourceCompositeKey: sourceKey
        )
        let album = try await repository.fetchAlbum(
            ratingKey: "album",
            sourceCompositeKey: sourceKey
        )
        let track = try await repository.fetchTrack(
            ratingKey: "track",
            sourceCompositeKey: sourceKey
        )

        XCTAssertEqual(artist?.dateAdded, exactDate)
        XCTAssertEqual(album?.dateAdded, exactDate)
        XCTAssertEqual(track?.dateAdded, exactDate)
    }

    func testBatchUpsertGenresUpdatesOneSourceWithoutTouchingAnother() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"
        let key = "/library/genre/ambient"

        try await repository.batchUpsertGenres([
            GenreUpsertInput(ratingKey: "a", key: key, title: "Ambient"),
            GenreUpsertInput(ratingKey: "b", key: "/library/genre/electronic", title: "Electronic")
        ], sourceCompositeKey: sourceA)
        try await repository.batchUpsertGenres([
            GenreUpsertInput(ratingKey: "other", key: key, title: "Other Ambient")
        ], sourceCompositeKey: sourceB)
        try await repository.batchUpsertGenres([
            GenreUpsertInput(ratingKey: "a", key: key, title: "Ambient Music")
        ], sourceCompositeKey: sourceA)

        let genres = try await repository.fetchGenres()
        XCTAssertEqual(genres.count, 3)
        XCTAssertEqual(genres.first { $0.sourceCompositeKey == sourceA && $0.key == key }?.title, "Ambient Music")
        XCTAssertEqual(genres.first { $0.sourceCompositeKey == sourceB && $0.key == key }?.title, "Other Ambient")
    }

    private func makeAlbumInput(
        ratingKey: String,
        thumbPath: String?,
        dateModified: Date?,
        artistRatingKey: String? = nil,
        genreNames: String? = nil,
        dateAdded: Date? = nil,
        trackCount: Int? = 1,
        releaseFormat: String? = nil,
        updatesReleaseFormat: Bool = false,
        updatesDateAdded: Bool = false,
        actionCapabilitiesData: Data? = nil
    ) -> AlbumUpsertInput {
        AlbumUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            title: "Album \(ratingKey)",
            artistName: "Artist",
            albumArtist: "Artist",
            artistRatingKey: artistRatingKey,
            summary: nil,
            thumbPath: thumbPath,
            artPath: nil,
            year: 2024,
            trackCount: trackCount,
            dateAdded: dateAdded,
            dateModified: dateModified,
            rating: nil,
            genreNames: genreNames,
            releaseFormat: releaseFormat,
            updatesReleaseFormat: updatesReleaseFormat,
            updatesDateAdded: updatesDateAdded,
            actionCapabilitiesData: actionCapabilitiesData
        )
    }

    private func makeArtistInput(
        ratingKey: String,
        thumbPath: String?,
        dateModified: Date?,
        dateAdded: Date? = nil,
        updatesDateAdded: Bool = false,
        actionCapabilitiesData: Data? = nil
    ) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            name: "Artist \(ratingKey)",
            summary: nil,
            thumbPath: thumbPath,
            artPath: nil,
            dateAdded: dateAdded,
            dateModified: dateModified,
            updatesDateAdded: updatesDateAdded,
            actionCapabilitiesData: actionCapabilitiesData
        )
    }

    private func makeTrackInput(
        ratingKey: String,
        dateModified: Date? = nil,
        rating: Int? = nil,
        albumRatingKey: String? = nil,
        duration: Int = 180_000,
        genreNames: String? = nil,
        dateAdded: Date? = nil,
        isFavorite: Bool? = nil,
        updatesDateAdded: Bool = false,
        actionCapabilitiesData: Data? = nil
    ) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            title: "Track \(ratingKey)",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: albumRatingKey,
            trackNumber: 1,
            discNumber: 1,
            duration: duration,
            thumbPath: nil,
            streamKey: nil,
            streamId: nil,
            dateAdded: dateAdded,
            dateModified: dateModified,
            lastPlayed: nil,
            rating: rating,
            isFavorite: isFavorite,
            playCount: nil,
            genreNames: genreNames,
            updatesDateAdded: updatesDateAdded,
            actionCapabilitiesData: actionCapabilitiesData
        )
    }
}

private func seedArtwork(data: Data, at artworkURL: URL, identity: ArtworkIdentity) throws {
    try data.write(to: artworkURL)
    try JSONEncoder().encode(identity).write(
        to: ArtworkDownloadManager.identityURL(for: artworkURL),
        options: [.atomic]
    )
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
