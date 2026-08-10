import EnsembleAPI
import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class ModelMappersTests: XCTestCase {
    func testPlexAlbumMapperPreservesSourceIdentityForAPIFallbackAlbums() throws {
        let data = Data("""
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "parentRatingKey": "artist-1",
            "title": "Album One",
            "parentTitle": "Artist One",
            "thumb": "/library/metadata/album-1/thumb",
            "year": 2026,
            "leafCount": 12
        }
        """.utf8)
        let plexAlbum = try JSONDecoder().decode(PlexAlbum.self, from: data)

        let album = Album(from: plexAlbum, sourceKey: "plex:account:server:library")

        XCTAssertEqual(album.sourceCompositeKey, "plex:account:server:library")
        XCTAssertEqual(album.artistRatingKey, "artist-1")
        XCTAssertEqual(album.sourceScopedID, "plex:account:server:library||album-1")
    }

    func testPlexHubAlbumMapperPreservesSourceIdentityAndOrderingMetadata() throws {
        let data = Data("""
        {
            "ratingKey": "album-2",
            "key": "/library/metadata/album-2",
            "type": "album",
            "title": "Related Album",
            "parentRatingKey": "artist-2",
            "parentTitle": "Artist Two",
            "thumb": "/library/metadata/album-2/thumb",
            "leafCount": 9,
            "addedAt": 100,
            "lastViewedAt": 200,
            "viewCount": 3
        }
        """.utf8)
        let hubAlbum = try JSONDecoder().decode(PlexHubMetadata.self, from: data)

        let album = Album(from: hubAlbum, sourceKey: "plex:account:server:library")
        let hubItem = HubItem(from: hubAlbum, sourceKey: "plex:account:server:library")

        XCTAssertEqual(album.sourceCompositeKey, "plex:account:server:library")
        XCTAssertEqual(album.artistRatingKey, "artist-2")
        XCTAssertEqual(album.sourceScopedID, "plex:account:server:library||album-2")
        XCTAssertEqual(hubItem.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(hubItem.lastViewedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(hubItem.viewCount, 3)
    }

    func testTrackMapperReadsPersistedStreamId() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

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
            streamId: 789,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: 0,
            playCount: 0
        )

        try await repository.batchUpsertTracks([input], sourceCompositeKey: sourceKey)

        let fetchedTrack = try await repository.fetchTrack(
            ratingKey: "track-1",
            sourceCompositeKey: sourceKey
        )
        let cdTrack = try XCTUnwrap(fetchedTrack)
        let track = Track(from: cdTrack)

        XCTAssertEqual(track.streamId, 789)
    }

    func testTrackMapperUsesCompletedQualityAndPlayableQualityDuringUpgrade() throws {
        let stack = CoreDataStack.inMemory()
        let context = stack.viewContext

        let completedTrack = CDTrack(context: context)
        completedTrack.ratingKey = "completed"
        completedTrack.key = "/completed"
        completedTrack.title = "Completed"
        completedTrack.localFilePath = "legacy.mp3"
        let completedDownload = CDDownload(context: context)
        completedDownload.status = CDDownload.Status.completed.rawValue
        completedDownload.quality = "medium"
        completedDownload.track = completedTrack

        let upgradingTrack = CDTrack(context: context)
        upgradingTrack.ratingKey = "upgrading"
        upgradingTrack.key = "/upgrading"
        upgradingTrack.title = "Upgrading"
        upgradingTrack.localFilePath = "upgrading_low.mp3"
        let upgradingDownload = CDDownload(context: context)
        upgradingDownload.status = CDDownload.Status.pending.rawValue
        upgradingDownload.quality = "high"
        upgradingDownload.track = upgradingTrack

        let completed = Track(from: completedTrack, downloadedFilenames: ["legacy.mp3"])
        let upgrading = Track(from: upgradingTrack, downloadedFilenames: ["upgrading_low.mp3"])

        XCTAssertEqual(completed.downloadedQuality, "medium")
        XCTAssertEqual(upgrading.downloadedQuality, "low")
    }

    func testAlbumMapperUsesPersistedTrackCountWithoutRealizingTracks() async throws {
        let stack = CoreDataStack.inMemory()
        let sourceKey = "plex/account/server/library"
        try await stack.performBackgroundContext { context in
            let album = CDAlbum(context: context)
            album.ratingKey = "album"
            album.key = "/album"
            album.title = "Album"
            album.trackCount = 12
            album.sourceCompositeKey = sourceKey

            let track = CDTrack(context: context)
            track.ratingKey = "track"
            track.key = "/track"
            track.title = "Track"
            track.sourceCompositeKey = sourceKey
            track.album = album
            try context.save()
        }
        stack.viewContext.performAndWait { stack.viewContext.reset() }

        let repository = LibraryRepository(coreDataStack: stack)
        let fetchedAlbum = try await repository.fetchAlbum(
            ratingKey: "album",
            sourceCompositeKey: sourceKey
        )
        let fetched = try XCTUnwrap(fetchedAlbum)
        XCTAssertTrue(fetched.hasFault(forRelationshipNamed: "tracks"))

        let mapped = Album(from: fetched)
        let mappedFromInventory = Album(from: fetched, trackCount: 1)

        XCTAssertEqual(mapped.trackCount, 12)
        XCTAssertEqual(mappedFromInventory.trackCount, 1)
        XCTAssertTrue(fetched.hasFault(forRelationshipNamed: "tracks"))
    }

    func testMediaMappersRestorePersistedItemActionCapabilities() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "future-provider:account:server:library"
        let capabilities = MusicItemActionCapabilities([
            .download: .readOnly(reason: "Downloads require server permission."),
            .editMetadata: .available,
        ])
        let data = try XCTUnwrap(capabilities.persistenceData)

        try await repository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist",
                key: "/artist",
                name: "Artist",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: nil,
                actionCapabilitiesData: data
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            AlbumUpsertInput(
                ratingKey: "album",
                key: "/album",
                title: "Album",
                artistName: "Artist",
                albumArtist: "Artist",
                artistRatingKey: nil,
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                year: nil,
                trackCount: 1,
                dateAdded: nil,
                dateModified: nil,
                rating: nil,
                actionCapabilitiesData: data
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            TrackUpsertInput(
                ratingKey: "track",
                key: "/track",
                title: "Track",
                artistName: "Artist",
                albumName: "Album",
                albumRatingKey: nil,
                trackNumber: 1,
                discNumber: 1,
                duration: 180_000,
                thumbPath: nil,
                streamKey: nil,
                dateAdded: nil,
                dateModified: nil,
                lastPlayed: nil,
                rating: nil,
                playCount: nil,
                actionCapabilitiesData: data
            )
        ], sourceCompositeKey: sourceKey)

        let fetchedArtist = try await repository.fetchArtist(ratingKey: "artist", sourceCompositeKey: sourceKey)
        let fetchedAlbum = try await repository.fetchAlbum(ratingKey: "album", sourceCompositeKey: sourceKey)
        let fetchedTrack = try await repository.fetchTrack(ratingKey: "track", sourceCompositeKey: sourceKey)
        let artist = try XCTUnwrap(fetchedArtist)
        let album = try XCTUnwrap(fetchedAlbum)
        let track = try XCTUnwrap(fetchedTrack)

        XCTAssertEqual(Artist(from: artist).actionCapabilities, capabilities)
        XCTAssertEqual(Album(from: album).actionCapabilities, capabilities)
        XCTAssertEqual(Track(from: track).actionCapabilities, capabilities)

        let emptyCapabilities = MusicItemActionCapabilities([:])
        let emptyData = try XCTUnwrap(emptyCapabilities.persistenceData)
        try await repository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist",
                key: "/artist",
                name: "Artist",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: nil,
                actionCapabilitiesData: emptyData
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums([
            AlbumUpsertInput(
                ratingKey: "album",
                key: "/album",
                title: "Album",
                artistName: "Artist",
                albumArtist: "Artist",
                artistRatingKey: nil,
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                year: nil,
                trackCount: 1,
                dateAdded: nil,
                dateModified: nil,
                rating: nil,
                actionCapabilitiesData: emptyData
            )
        ], sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks([
            TrackUpsertInput(
                ratingKey: "track",
                key: "/track",
                title: "Track",
                artistName: "Artist",
                albumName: "Album",
                albumRatingKey: nil,
                trackNumber: 1,
                discNumber: 1,
                duration: 180_000,
                thumbPath: nil,
                streamKey: nil,
                dateAdded: nil,
                dateModified: nil,
                lastPlayed: nil,
                rating: nil,
                playCount: nil,
                actionCapabilitiesData: emptyData
            )
        ], sourceCompositeKey: sourceKey)

        let clearedArtist = try await repository.fetchArtist(ratingKey: "artist", sourceCompositeKey: sourceKey)
        let clearedAlbum = try await repository.fetchAlbum(ratingKey: "album", sourceCompositeKey: sourceKey)
        let clearedTrack = try await repository.fetchTrack(ratingKey: "track", sourceCompositeKey: sourceKey)
        XCTAssertEqual(Artist(from: try XCTUnwrap(clearedArtist)).actionCapabilities, emptyCapabilities)
        XCTAssertEqual(Album(from: try XCTUnwrap(clearedAlbum)).actionCapabilities, emptyCapabilities)
        XCTAssertEqual(Track(from: try XCTUnwrap(clearedTrack)).actionCapabilities, emptyCapabilities)
    }
}
