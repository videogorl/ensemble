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

    func testPlexHubAlbumMapperPreservesSourceIdentityForRelatedAlbums() throws {
        let data = Data("""
        {
            "ratingKey": "album-2",
            "key": "/library/metadata/album-2",
            "type": "album",
            "title": "Related Album",
            "parentRatingKey": "artist-2",
            "parentTitle": "Artist Two",
            "thumb": "/library/metadata/album-2/thumb",
            "leafCount": 9
        }
        """.utf8)
        let hubAlbum = try JSONDecoder().decode(PlexHubMetadata.self, from: data)

        let album = Album(from: hubAlbum, sourceKey: "plex:account:server:library")

        XCTAssertEqual(album.sourceCompositeKey, "plex:account:server:library")
        XCTAssertEqual(album.artistRatingKey, "artist-2")
        XCTAssertEqual(album.sourceScopedID, "plex:account:server:library||album-2")
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
}
