import XCTest
@testable import EnsemblePersistence

final class ExternalDeviceSyncRepositoryTests: XCTestCase {
    func testDeviceAndMapsRoundTrip() async throws {
        let repository = ExternalDeviceSyncRepository(coreDataStack: .inMemory())

        let device = try await repository.upsertDevice(
            deviceID: "device-1",
            displayName: "Felicity's iPod",
            modelIdentifier: "classic",
            mountPath: "/Volumes/iPod",
            totalCapacity: 1_000,
            freeCapacity: 250,
            isSupported: true,
            supportMessage: nil,
            automaticSyncEnabled: true
        )

        XCTAssertEqual(device.id, "device-1")
        XCTAssertTrue(device.automaticSyncEnabled)

        let trackMap = try await repository.upsertTrackMap(
            deviceID: "device-1",
            ipodPersistentID: "track-db-id",
            ipodPath: "iPod_Control/Music/F00/A.mp3",
            ipodName: "Track",
            plexRatingKey: "42",
            sourceCompositeKey: "plex:account:server:library",
            lastImportedPlayCount: 3,
            lastImportedRating: 8
        )
        let playlistMap = try await repository.upsertPlaylistMap(
            deviceID: "device-1",
            ipodPersistentID: "playlist-db-id",
            ipodName: "Playlist",
            plexRatingKey: "77",
            sourceCompositeKey: "plex:account:server:library"
        )

        let maps = try await repository.fetchMaps(deviceID: "device-1", kind: nil)
        XCTAssertEqual(Set(maps.map(\.id)), [trackMap.id, playlistMap.id])

        try await repository.updateImportCheckpoint(
            mapID: trackMap.id,
            playCount: 5,
            rating: 10
        )
        let updatedTrackMap = try await repository.fetchMaps(deviceID: "device-1", kind: .track).first
        XCTAssertEqual(updatedTrackMap?.lastImportedPlayCount, 5)
        XCTAssertEqual(updatedTrackMap?.lastImportedRating, 10)
    }

    func testSyncRunUpdatesDeviceLastSync() async throws {
        let repository = ExternalDeviceSyncRepository(coreDataStack: .inMemory())
        _ = try await repository.upsertDevice(
            deviceID: "device-1",
            displayName: "iPod",
            modelIdentifier: nil,
            mountPath: "/Volumes/iPod",
            totalCapacity: 100,
            freeCapacity: 50,
            isSupported: true,
            supportMessage: nil,
            automaticSyncEnabled: nil
        )

        let finishedAt = Date()
        let run = try await repository.recordSyncRun(
            deviceID: "device-1",
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            status: "completed",
            importedRatings: 1,
            importedPlays: 2,
            importedPlaylists: 3,
            exportedTracks: 4,
            exportedPlaylists: 5,
            discardedItems: 6,
            errorMessage: nil
        )

        XCTAssertEqual(run.importedPlays, 2)
        let latestRun = try await repository.latestSyncRun(deviceID: "device-1")
        let devices = try await repository.fetchDevices()
        XCTAssertEqual(latestRun?.id, run.id)
        XCTAssertEqual(devices.first?.lastSyncAt, finishedAt)
    }
}
