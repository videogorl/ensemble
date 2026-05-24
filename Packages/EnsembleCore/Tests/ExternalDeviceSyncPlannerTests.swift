import EnsemblePersistence
@testable import EnsembleCore
import XCTest

final class ExternalDeviceSyncPlannerTests: XCTestCase {
    func testMappedOnlyImportDiscardsUnmappedTracksAndUsesPlayDeltas() {
        let planner = ExternalDeviceSyncPlanner()
        let snapshot = makeSnapshot(
            tracks: [
                IPodTrackSnapshot(
                    persistentID: "mapped",
                    filePath: "iPod_Control/Music/F00/mapped.mp3",
                    title: "Mapped",
                    ratingStars: 4,
                    totalPlayCount: 12,
                    recentPlayCount: 2,
                    lastPlayed: nil
                ),
                IPodTrackSnapshot(
                    persistentID: "unmapped",
                    filePath: "iPod_Control/Music/F00/unmapped.mp3",
                    title: "Unmapped",
                    ratingStars: 5,
                    totalPlayCount: 1,
                    recentPlayCount: 1,
                    lastPlayed: nil
                )
            ],
            playlists: []
        )

        let plan = planner.planImport(
            snapshot: snapshot,
            trackMaps: [
                makeTrackMap(
                    ipodID: "mapped",
                    ratingKey: "plex-track",
                    sourceKey: "plex:account:server:library",
                    playCount: 10,
                    rating: 0
                )
            ],
            playlistMaps: []
        )

        XCTAssertEqual(plan.ratingUpdates.map(\.plexRating), [8])
        XCTAssertEqual(plan.playDeltas.map(\.delta), [2])
        XCTAssertEqual(plan.playDeltas.map(\.checkpointPlayCount), [12])
        XCTAssertEqual(plan.discardedItemCount, 1)
    }

    func testTotalPlayCountDeltaFallsBackWhenRecentPlayCountMissing() {
        let planner = ExternalDeviceSyncPlanner()
        let snapshot = makeSnapshot(
            tracks: [
                IPodTrackSnapshot(
                    persistentID: "mapped",
                    filePath: nil,
                    title: "Mapped",
                    ratingStars: 0,
                    totalPlayCount: 13,
                    recentPlayCount: 0,
                    lastPlayed: nil
                )
            ],
            playlists: []
        )

        let plan = planner.planImport(
            snapshot: snapshot,
            trackMaps: [
                makeTrackMap(
                    ipodID: "mapped",
                    ratingKey: "plex-track",
                    sourceKey: "plex:account:server:library",
                    playCount: 10,
                    rating: 0
                )
            ],
            playlistMaps: []
        )

        XCTAssertEqual(plan.playDeltas.map(\.delta), [3])
        XCTAssertEqual(plan.playDeltas.map(\.checkpointPlayCount), [13])
    }

    func testPlaylistImportKeepsOnlyMappedMembersForExistingPlaylist() {
        let planner = ExternalDeviceSyncPlanner()
        let snapshot = makeSnapshot(
            tracks: [
                IPodTrackSnapshot(persistentID: "a", filePath: nil, title: "A", ratingStars: 0, totalPlayCount: 0, recentPlayCount: 0, lastPlayed: nil),
                IPodTrackSnapshot(persistentID: "b", filePath: nil, title: "B", ratingStars: 0, totalPlayCount: 0, recentPlayCount: 0, lastPlayed: nil)
            ],
            playlists: [
                IPodPlaylistSnapshot(
                    persistentID: "playlist",
                    name: "Mapped Playlist",
                    trackPersistentIDs: ["a", "b", "missing"],
                    isOnTheGo: false
                )
            ]
        )

        let plan = planner.planImport(
            snapshot: snapshot,
            trackMaps: [
                makeTrackMap(ipodID: "a", ratingKey: "plex-a", sourceKey: "plex:account:server:library"),
                makeTrackMap(ipodID: "b", ratingKey: "plex-b", sourceKey: "plex:account:server:library")
            ],
            playlistMaps: [
                makePlaylistMap(ipodID: "playlist", ratingKey: "plex-playlist", sourceKey: "plex:account:server:library")
            ]
        )

        XCTAssertEqual(plan.playlistUpdates.count, 1)
        XCTAssertEqual(plan.playlistUpdates[0].trackReferences.map(\.ratingKey), ["plex-a", "plex-b"])
        XCTAssertEqual(plan.discardedItemCount, 1)
        XCTAssertEqual(
            plan.playlistUpdates[0].action,
            .updateExisting(playlistRatingKey: "plex-playlist", sourceCompositeKey: "plex:account:server:library")
        )
    }

    func testOnTheGoPlaylistCreatesOnlyWhenAllMembersAreMappedToOneSource() {
        let planner = ExternalDeviceSyncPlanner()
        let snapshot = makeSnapshot(
            tracks: [
                IPodTrackSnapshot(persistentID: "a", filePath: nil, title: "A", ratingStars: 0, totalPlayCount: 0, recentPlayCount: 0, lastPlayed: nil)
            ],
            playlists: [
                IPodPlaylistSnapshot(
                    persistentID: "otg",
                    name: "On-The-Go 1",
                    trackPersistentIDs: ["a"],
                    isOnTheGo: true
                )
            ]
        )

        let plan = planner.planImport(
            snapshot: snapshot,
            trackMaps: [
                makeTrackMap(ipodID: "a", ratingKey: "plex-a", sourceKey: "plex:account:server:library")
            ],
            playlistMaps: []
        )

        XCTAssertEqual(plan.playlistUpdates.count, 1)
        XCTAssertEqual(
            plan.playlistUpdates[0].action,
            .create(title: "On-The-Go 1", sourceCompositeKey: "plex:account:server:library")
        )
    }

    func testIPodStarsClampToPlexRatingScale() {
        XCTAssertEqual(ExternalDeviceSyncPlanner.plexRating(fromIPodStars: -1), 0)
        XCTAssertEqual(ExternalDeviceSyncPlanner.plexRating(fromIPodStars: 3), 6)
        XCTAssertEqual(ExternalDeviceSyncPlanner.plexRating(fromIPodStars: 9), 10)
    }

    private func makeSnapshot(
        tracks: [IPodTrackSnapshot],
        playlists: [IPodPlaylistSnapshot]
    ) -> IPodLibrarySnapshot {
        IPodLibrarySnapshot(
            device: IPodDeviceSnapshot(
                deviceID: "device",
                name: "iPod",
                modelIdentifier: nil,
                mountURL: URL(fileURLWithPath: "/Volumes/iPod"),
                totalCapacity: 1_000,
                freeCapacity: 500,
                supportState: .supported
            ),
            tracks: tracks,
            playlists: playlists
        )
    }

    private func makeTrackMap(
        ipodID: String,
        ratingKey: String,
        sourceKey: String,
        playCount: Int = 0,
        rating: Int = 0
    ) -> ExternalDeviceMapRecord {
        ExternalDeviceMapRecord(
            id: "device|track|\(ipodID)",
            kind: .track,
            deviceID: "device",
            ipodPersistentID: ipodID,
            ipodPath: nil,
            ipodName: nil,
            plexRatingKey: ratingKey,
            sourceCompositeKey: sourceKey,
            lastImportedPlayCount: playCount,
            lastImportedRating: rating,
            lastImportedAt: nil
        )
    }

    private func makePlaylistMap(
        ipodID: String,
        ratingKey: String,
        sourceKey: String
    ) -> ExternalDeviceMapRecord {
        ExternalDeviceMapRecord(
            id: "device|playlist|\(ipodID)",
            kind: .playlist,
            deviceID: "device",
            ipodPersistentID: ipodID,
            ipodPath: nil,
            ipodName: nil,
            plexRatingKey: ratingKey,
            sourceCompositeKey: sourceKey,
            lastImportedPlayCount: 0,
            lastImportedRating: 0,
            lastImportedAt: nil
        )
    }
}
