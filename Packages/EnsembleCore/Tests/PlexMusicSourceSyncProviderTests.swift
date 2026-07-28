import EnsembleAPI
import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class PlexMusicSourceSyncProviderTests: XCTestCase {
    private struct IncrementalItem: Equatable {
        let ratingKey: String
        let updatedAt: Int?
        let marker: String
        let ratingChanged: Bool
    }

    func testIncrementalChangeSelectionDeduplicatesAndLetsUpdatedItemWin() {
        let added = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "added", ratingChanged: false)
        let updated = IncrementalItem(ratingKey: "1", updatedAt: 101, marker: "updated", ratingChanged: false)

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [added],
            updated: [updated],
            existingTimestamps: ["1": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.uniqueCount, 1)
        XCTAssertEqual(changes.changedItems, [updated])
    }

    func testIncrementalChangeSelectionSkipsUnchangedAndMissingServerTimestampWhenLocalExists() {
        let unchanged = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "unchanged", ratingChanged: false)
        let missingTimestampExisting = IncrementalItem(
            ratingKey: "2",
            updatedAt: nil,
            marker: "missing-existing",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [unchanged, missingTimestampExisting],
            updated: [],
            existingTimestamps: [
                "1": Date(timeIntervalSince1970: 100),
                "2": Date(timeIntervalSince1970: 50)
            ],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertTrue(changes.changedItems.isEmpty)
    }

    func testIncrementalChangeSelectionSyncsMissingTimestampWhenLocalIsAbsent() {
        let missingTimestampNew = IncrementalItem(
            ratingKey: "new",
            updatedAt: nil,
            marker: "missing-new",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [missingTimestampNew],
            updated: [],
            existingTimestamps: [:],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.changedItems, [missingTimestampNew])
    }

    func testIncrementalChangeSelectionAllowsAdditionalChangePredicate() {
        let ratingOnly = IncrementalItem(
            ratingKey: "track",
            updatedAt: 100,
            marker: "rating",
            ratingChanged: true
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [],
            updated: [ratingOnly],
            existingTimestamps: ["track": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt },
            hasAdditionalChange: { $0.ratingChanged }
        )

        XCTAssertEqual(changes.changedItems, [ratingOnly])
    }

    func testArtistChangeSelectionUsesMetadataWhenPlexTimestampIsStale() {
        let staleDate = Date(timeIntervalSince1970: 100)
        let unchanged = makeArtistInput(ratingKey: "unchanged", name: "Unchanged", dateModified: staleDate)
        let oldRenamed = makeArtistInput(ratingKey: "renamed", name: "Janelle Mon�e", dateModified: staleDate)
        let renamed = makeArtistInput(ratingKey: "renamed", name: "Janelle Monáe", dateModified: staleDate)
        let newArtist = makeArtistInput(ratingKey: "new", name: "New Artist", dateModified: nil)

        let changes = PlexMusicSourceSyncProvider.changedArtistInputs(
            [unchanged, renamed, newArtist],
            existingMetadata: [
                unchanged.ratingKey: ArtistSyncMetadata(unchanged),
                oldRenamed.ratingKey: ArtistSyncMetadata(oldRenamed)
            ]
        )

        XCTAssertEqual(changes.map(\.ratingKey), ["renamed", "new"])
    }

    func testTrackUpsertInputPreservesPlexTrackMetadata() throws {
        let data = Data("""
        {
            "ratingKey": "track-1",
            "key": "/library/metadata/track-1",
            "parentRatingKey": "album-1",
            "grandparentRatingKey": "artist-1",
            "title": "Track One",
            "parentTitle": "Album One",
            "grandparentTitle": "Album Artist",
            "originalTitle": "Track Artist",
            "index": 3,
            "parentIndex": 2,
            "duration": 181000,
            "parentThumb": "/library/metadata/album-1/thumb",
            "addedAt": 100,
            "updatedAt": 200,
            "lastViewedAt": 300,
            "lastRatedAt": 400,
            "userRating": 8,
            "viewCount": 5,
            "Media": [
                {
                    "id": 10,
                    "Part": [
                        {
                            "id": 20,
                            "key": "/library/parts/20/file.flac",
                            "Stream": [
                                { "id": 30, "streamType": 2, "codec": "flac" }
                            ]
                        }
                    ]
                }
            ]
        }
        """.utf8)
        let track = try JSONDecoder().decode(PlexTrack.self, from: data)

        let input = PlexMusicSourceSyncProvider.trackUpsertInput(from: track, genreNames: "Rock, Pop")

        XCTAssertEqual(input.ratingKey, "track-1")
        XCTAssertEqual(input.key, "/library/metadata/track-1")
        XCTAssertEqual(input.title, "Track One")
        XCTAssertEqual(input.artistName, "Track Artist")
        XCTAssertEqual(input.albumName, "Album One")
        XCTAssertEqual(input.albumRatingKey, "album-1")
        XCTAssertEqual(input.trackNumber, 3)
        XCTAssertEqual(input.discNumber, 2)
        XCTAssertEqual(input.duration, 181_000)
        XCTAssertEqual(input.thumbPath, "/library/metadata/album-1/thumb")
        XCTAssertEqual(input.streamKey, "/library/parts/20/file.flac")
        XCTAssertEqual(input.streamId, 30)
        XCTAssertEqual(input.dateAdded, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(input.dateModified, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(input.lastPlayed, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(input.lastRatedAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(input.rating, 8)
        XCTAssertEqual(input.playCount, 5)
        XCTAssertEqual(input.genreNames, "Rock, Pop")
    }

    func testAlbumUpsertInputPersistsAuthoritativeLeafCount() throws {
        let data = Data("""
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "title": "Album One",
            "parentTitle": "Artist One",
            "leafCount": 12
        }
        """.utf8)
        let album = try JSONDecoder().decode(PlexAlbum.self, from: data)

        let input = PlexMusicSourceSyncProvider.albumUpsertInput(from: album)

        XCTAssertEqual(input.trackCount, 12)
    }

    func testAlbumTrackCountCanBeDerivedWhenSectionAlbumOmitsLeafCount() throws {
        let album = try JSONDecoder().decode(PlexAlbum.self, from: Data(#"""
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "title": "Album One"
        }
        """#.utf8))
        let tracks = try JSONDecoder().decode([PlexTrack].self, from: Data(#"""
        [
            { "ratingKey": "track-1", "key": "/track-1", "title": "One", "parentRatingKey": "album-1" },
            { "ratingKey": "track-2", "key": "/track-2", "title": "Two", "parentRatingKey": "album-1" },
            { "ratingKey": "track-3", "key": "/track-3", "title": "Three", "parentRatingKey": "album-2" }
        ]
        """#.utf8))

        let counts = PlexMusicSourceSyncProvider.trackCountsByAlbumRatingKey(tracks)
        let input = PlexMusicSourceSyncProvider.albumUpsertInput(
            from: album,
            trackCount: counts[album.ratingKey]
        )

        XCTAssertEqual(input.trackCount, 2)
    }

    func testPlaylistOrphanCheckRunsWhenPlaylistsChanged() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 1,
                lastCheckedAt: Date().timeIntervalSince1970,
                now: Date()
            )
        )
    }

    func testPlaylistOrphanCheckSkipsRecentUnchangedCleanup() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 0,
                lastCheckedAt: 900,
                now: now,
                interval: 200
            )
        )
    }

    func testPlaylistOrphanCheckRunsWhenUnchangedCleanupIsStale() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 0,
                lastCheckedAt: 700,
                now: now,
                interval: 200
            )
        )
    }

    func testPlaylistTrackSyncSkipsUnchangedPlaylist() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesChangedPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 101,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesNewPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: nil
            )
        )
    }

    func testPlaylistTrackSyncSkipsExistingPlaylistWhenServerUpdatedAtIsMissing() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: nil,
                existingModifiedAt: Date.distantPast
            )
        )
    }

    func testPlaylistTrackSyncRepairsEmptyLocalBodyWhenServerHasTracks() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 0
            )
        )
    }

    func testPlaylistTrackSyncPreservesPartialLocalBodyUntilServerChanges() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 3
            )
        )
    }

    func testPlaylistTrackSyncDoesNotRepairCompleteBodyWhenItemIDsAreMissing() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 12
            )
        )
    }

    func testPlaylistTrackSyncDoesNotRepairIntentionallyEmptyPlaylist() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 0,
                localMembershipCount: 0
            )
        )
    }

    private func makeArtistInput(
        ratingKey: String,
        name: String,
        dateModified: Date?
    ) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)/children",
            name: name,
            summary: "Summary",
            thumbPath: "/library/metadata/\(ratingKey)/thumb/100",
            artPath: "/library/metadata/\(ratingKey)/art/100",
            dateAdded: nil,
            dateModified: dateModified
        )
    }
}
