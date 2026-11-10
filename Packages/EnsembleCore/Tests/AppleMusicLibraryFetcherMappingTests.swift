import XCTest
import EnsemblePersistence
@testable import EnsembleCore

final class AppleMusicLibraryFetcherMappingTests: XCTestCase {
    func testAppleMusicLibrarySongUsesRelationshipIDs() throws {
        let data = Data(#"""
        {
            "data": [{
                "id": "i.library-song",
                "attributes": {
                    "name": "Maybe Man",
                    "artistName": "AJR",
                    "albumName": "The Maybe Man",
                    "playParams": { "catalogId": "1717532335" }
                },
                "relationships": {
                    "albums": { "data": [{ "id": "l.library-album" }] },
                    "artists": { "data": [{ "id": "r.library-artist" }] },
                    "catalog": { "data": [{ "id": "1717532335" }] }
                }
            }]
        }
        """#.utf8)

        let song = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data[0]

        XCTAssertEqual(song.artistKey, "apple-artist:r.library-artist")
        XCTAssertEqual(song.albumKey, "apple-album:l.library-album")
        XCTAssertEqual(song.catalogID, "1717532335")
        XCTAssertEqual(song.trackKey, "apple-library-catalog:1717532335")
    }


    func testAppleMusicNativeLibraryMetadataUsesExactLibraryRelationshipIDs() throws {
        let data = Data(#"""
        {
            "data": [{
                "id": "i.library-song",
                "attributes": {
                    "name": "Maybe Man",
                    "artistName": "AJR",
                    "albumName": "The Maybe Man",
                    "playParams": { "catalogId": "1717532335" }
                },
                "relationships": {
                    "albums": { "data": [{ "id": "l.library-album" }] },
                    "artists": { "data": [{ "id": "r.library-artist" }] }
                }
            }]
        }
        """#.utf8)
        let song = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data[0]
        let trackDate = Date(timeIntervalSince1970: 100)
        let albumDate = Date(timeIntervalSince1970: 200)
        let artistDate = Date(timeIntervalSince1970: 300)
        let lastPlayed = Date(timeIntervalSince1970: 400)
        let snapshot = NativeLibraryMetadataSnapshot(
            songs: [
                NativeLibrarySongMetadata(
                    itemID: song.id,
                    dateAdded: trackDate,
                    lastPlayed: lastPlayed,
                    playCount: 12
                )
            ],
            albums: [
                NativeLibraryDateMetadata(
                    itemID: try XCTUnwrap(song.albumLibraryID),
                    dateAdded: albumDate
                )
            ],
            artists: [
                NativeLibraryDateMetadata(
                    itemID: try XCTUnwrap(song.artistLibraryID),
                    dateAdded: artistDate
                )
            ],
            elapsedMilliseconds: 25
        )

        let track = AppleMusicLibraryFetcher.trackUpsertInput(
            song,
            metadata: snapshot.songsByID[song.id],
            isFavorite: false
        )
        let album = try XCTUnwrap(AppleMusicLibraryFetcher.albumUpsertInputs(
            from: [song],
            dateAddedByLibraryID: snapshot.albumDateAddedByID
        ).first)
        let artist = try XCTUnwrap(AppleMusicLibraryFetcher.artistUpsertInputs(
            from: [song],
            dateAddedByLibraryID: snapshot.artistDateAddedByID
        ).first)

        XCTAssertEqual(track.dateAdded, trackDate)
        XCTAssertEqual(track.lastPlayed, lastPlayed)
        XCTAssertEqual(track.playCount, 12)
        XCTAssertNil(track.dateModified)
        XCTAssertTrue(track.updatesDateAdded)
        XCTAssertEqual(album.dateAdded, albumDate)
        XCTAssertNil(album.dateModified)
        XCTAssertTrue(album.updatesDateAdded)
        XCTAssertEqual(artist.dateAdded, artistDate)
        XCTAssertNil(artist.dateModified)
        XCTAssertTrue(artist.updatesDateAdded)
        XCTAssertEqual(snapshot.elapsedMilliseconds, 25)
        XCTAssertEqual(
            AppleMusicLibraryFetcher.albumUpsertInputs(
                from: [song],
                songMetadataByLibraryID: snapshot.songsByID
            ).first?.dateAdded,
            trackDate
        )
        XCTAssertEqual(
            AppleMusicLibraryFetcher.artistUpsertInputs(
                from: [song],
                songMetadataByLibraryID: snapshot.songsByID
            ).first?.dateAdded,
            trackDate
        )

        let catalogIdentityOnly = NativeLibraryMetadataSnapshot(
            songs: [
                NativeLibrarySongMetadata(
                    itemID: try XCTUnwrap(song.catalogID),
                    dateAdded: trackDate,
                    lastPlayed: lastPlayed,
                    playCount: 12
                )
            ],
            albums: [],
            artists: [],
            elapsedMilliseconds: 0
        )
        XCTAssertNil(catalogIdentityOnly.songsByID[song.id])
        let unmatched = AppleMusicLibraryFetcher.trackUpsertInput(
            song,
            metadata: catalogIdentityOnly.songsByID[song.id],
            isFavorite: false
        )
        XCTAssertNil(unmatched.lastPlayed, "without native metadata the fetcher reports no play history and flags the track")
        XCTAssertNil(unmatched.playCount)
    }


    func testAppleMusicAlbumUpsertCountMatchesAuthoritativeLibrarySongs() throws {
        let data = Data(#"""
        {
            "data": [
                {
                    "id": "song-one",
                    "attributes": { "name": "One", "artistName": "Artist", "albumName": "Album" },
                    "relationships": {
                        "albums": { "data": [{ "id": "album" }] },
                        "artists": { "data": [{ "id": "artist" }] }
                    }
                },
                {
                    "id": "song-two",
                    "attributes": { "name": "Two", "artistName": "Artist", "albumName": "Album" },
                    "relationships": {
                        "albums": { "data": [{ "id": "album" }] },
                        "artists": { "data": [{ "id": "artist" }] }
                    }
                }
            ]
        }
        """#.utf8)
        let songs = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data

        let inputs = AppleMusicLibraryFetcher.albumUpsertInputs(from: songs)

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].trackCount, 2)
    }

}
