import CoreData
import XCTest
@testable import EnsemblePersistence

final class CoreDataMigrationTests: XCTestCase {
    func testEnsemble9StoreMigratesToEnsemble10WithItemCapabilitiesUnset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ensemble-v9-v10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Legacy.sqlite")
        let modelDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CoreData/Compiled/SwiftPMEnsemble.momd", isDirectory: true)
        let version9 = try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent("Ensemble 9.mom")
        ))
        let version10 = try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent("Ensemble 10.mom")
        ))

        let legacyContainer = try await loadContainer(model: version9, storeURL: storeURL)
        let legacyContext = legacyContainer.viewContext
        let artist = NSEntityDescription.insertNewObject(forEntityName: "CDArtist", into: legacyContext)
        artist.setValue("artist-1", forKey: "ratingKey")
        artist.setValue("/library/metadata/artist-1", forKey: "key")
        artist.setValue("Legacy Artist", forKey: "name")

        let album = NSEntityDescription.insertNewObject(forEntityName: "CDAlbum", into: legacyContext)
        album.setValue("album-1", forKey: "ratingKey")
        album.setValue("/library/metadata/album-1", forKey: "key")
        album.setValue("Legacy Album", forKey: "title")

        let track = NSEntityDescription.insertNewObject(forEntityName: "CDTrack", into: legacyContext)
        track.setValue("track-1", forKey: "ratingKey")
        track.setValue("/library/metadata/track-1", forKey: "key")
        track.setValue("Legacy Track", forKey: "title")
        try legacyContext.save()
        try detachStores(from: legacyContainer)

        let migratedContainer = try await loadContainer(model: version10, storeURL: storeURL)
        let context = migratedContainer.viewContext
        let migratedArtist = try XCTUnwrap(try context.fetch(fetchRequest("CDArtist")).first)
        let migratedAlbum = try XCTUnwrap(try context.fetch(fetchRequest("CDAlbum")).first)
        let migratedTrack = try XCTUnwrap(try context.fetch(fetchRequest("CDTrack")).first)
        XCTAssertEqual(migratedArtist.value(forKey: "name") as? String, "Legacy Artist")
        XCTAssertEqual(migratedAlbum.value(forKey: "title") as? String, "Legacy Album")
        XCTAssertEqual(migratedTrack.value(forKey: "title") as? String, "Legacy Track")
        XCTAssertNil(migratedArtist.value(forKey: "actionCapabilitiesData"))
        XCTAssertNil(migratedAlbum.value(forKey: "actionCapabilitiesData"))
        XCTAssertNil(migratedTrack.value(forKey: "actionCapabilitiesData"))
    }

    func testEnsemble8StoreMigratesToEnsemble9WithNormalizedFieldsUnset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ensemble-v8-v9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Legacy.sqlite")
        let modelDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CoreData/Compiled/SwiftPMEnsemble.momd", isDirectory: true)
        let version8 = try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent("Ensemble 8.mom")
        ))
        let version9 = try XCTUnwrap(NSManagedObjectModel(
            contentsOf: modelDirectory.appendingPathComponent("Ensemble 9.mom")
        ))

        let legacyContainer = try await loadContainer(model: version8, storeURL: storeURL)
        let legacyContext = legacyContainer.viewContext
        let track = NSEntityDescription.insertNewObject(forEntityName: "CDTrack", into: legacyContext)
        track.setValue("track-1", forKey: "ratingKey")
        track.setValue("/library/metadata/track-1", forKey: "key")
        track.setValue("Legacy Song", forKey: "title")
        track.setValue(10, forKey: "rating")

        let playlist = NSEntityDescription.insertNewObject(forEntityName: "CDPlaylist", into: legacyContext)
        playlist.setValue("playlist-1", forKey: "ratingKey")
        playlist.setValue("/playlists/playlist-1", forKey: "key")
        playlist.setValue("Legacy Playlist", forKey: "title")
        playlist.setValue(1, forKey: "trackCount")

        let hub = NSEntityDescription.insertNewObject(forEntityName: "CDHub", into: legacyContext)
        hub.setValue("hub-1", forKey: "id")
        hub.setValue("Recently Played", forKey: "title")
        hub.setValue("album", forKey: "type")
        let hubItem = NSEntityDescription.insertNewObject(forEntityName: "CDHubItem", into: legacyContext)
        hubItem.setValue("album-1", forKey: "id")
        hubItem.setValue("album", forKey: "type")
        hubItem.setValue("Legacy Album", forKey: "title")
        hubItem.setValue("plex:account:server:library", forKey: "sourceCompositeKey")
        hubItem.setValue(hub, forKey: "hub")
        hub.setValue(NSOrderedSet(object: hubItem), forKey: "items")
        try legacyContext.save()
        try detachStores(from: legacyContainer)

        let migratedContainer = try await loadContainer(model: version9, storeURL: storeURL)
        let context = migratedContainer.viewContext
        let migratedTrack = try XCTUnwrap(try context.fetch(fetchRequest("CDTrack")).first)
        XCTAssertEqual(migratedTrack.value(forKey: "title") as? String, "Legacy Song")
        XCTAssertEqual(migratedTrack.value(forKey: "rating") as? Int16, 10)
        XCTAssertNil(migratedTrack.value(forKey: "isFavorite"))

        let migratedPlaylist = try XCTUnwrap(try context.fetch(fetchRequest("CDPlaylist")).first)
        XCTAssertEqual(migratedPlaylist.value(forKey: "title") as? String, "Legacy Playlist")
        XCTAssertNil(migratedPlaylist.value(forKey: "canAddItems"))
        XCTAssertNil(migratedPlaylist.value(forKey: "canRename"))
        XCTAssertNil(migratedPlaylist.value(forKey: "canReorder"))
        XCTAssertNil(migratedPlaylist.value(forKey: "canDelete"))
        XCTAssertNil(migratedPlaylist.value(forKey: "actionUnavailableReason"))
        XCTAssertNil(migratedPlaylist.value(forKey: "fallbackArtworkPath"))
        XCTAssertNil(migratedPlaylist.value(forKey: "fallbackArtworkRatingKey"))
        XCTAssertNil(migratedPlaylist.value(forKey: "fallbackArtworkSourceCompositeKey"))

        let migratedHub = try XCTUnwrap(try context.fetch(fetchRequest("CDHub")).first)
        XCTAssertEqual(migratedHub.value(forKey: "title") as? String, "Recently Played")
        XCTAssertNil(migratedHub.value(forKey: "semanticKind"))
        XCTAssertNil(migratedHub.value(forKey: "sourceScopeSourceCompositeKey"))
        XCTAssertNil(migratedHub.value(forKey: "sourceScopeServerCompositeKey"))
        let migratedHubItem = try XCTUnwrap(try context.fetch(fetchRequest("CDHubItem")).first)
        XCTAssertNil(migratedHubItem.value(forKey: "key"))
        XCTAssertNil(migratedHubItem.value(forKey: "year"))
        XCTAssertNil(migratedHubItem.value(forKey: "addedAt"))
        XCTAssertNil(migratedHubItem.value(forKey: "lastViewedAt"))
        XCTAssertNil(migratedHubItem.value(forKey: "viewCount"))
    }

    private func loadContainer(
        model: NSManagedObjectModel,
        storeURL: URL
    ) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "EnsembleMigrationTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions = [description]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return container
    }

    private func detachStores(from container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    private func fetchRequest(_ entityName: String) -> NSFetchRequest<NSManagedObject> {
        NSFetchRequest<NSManagedObject>(entityName: entityName)
    }
}
