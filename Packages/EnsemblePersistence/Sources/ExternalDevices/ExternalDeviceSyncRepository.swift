import CoreData
import Foundation

public struct ExternalDeviceRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let modelIdentifier: String?
    public let mountPath: String?
    public let totalCapacity: Int64
    public let freeCapacity: Int64
    public let isSupported: Bool
    public let supportMessage: String?
    public let automaticSyncEnabled: Bool
    public let lastSeenAt: Date?
    public let lastSyncAt: Date?

    public init(
        id: String,
        displayName: String,
        modelIdentifier: String?,
        mountPath: String?,
        totalCapacity: Int64,
        freeCapacity: Int64,
        isSupported: Bool,
        supportMessage: String?,
        automaticSyncEnabled: Bool,
        lastSeenAt: Date?,
        lastSyncAt: Date?
    ) {
        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.mountPath = mountPath
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.isSupported = isSupported
        self.supportMessage = supportMessage
        self.automaticSyncEnabled = automaticSyncEnabled
        self.lastSeenAt = lastSeenAt
        self.lastSyncAt = lastSyncAt
    }
}

public struct ExternalDeviceMapRecord: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case track
        case playlist
    }

    public let id: String
    public let kind: Kind
    public let deviceID: String
    public let ipodPersistentID: String?
    public let ipodPath: String?
    public let ipodName: String?
    public let plexRatingKey: String?
    public let sourceCompositeKey: String?
    public let lastImportedPlayCount: Int
    public let lastImportedRating: Int
    public let lastImportedAt: Date?

    public init(
        id: String,
        kind: Kind,
        deviceID: String,
        ipodPersistentID: String?,
        ipodPath: String?,
        ipodName: String?,
        plexRatingKey: String?,
        sourceCompositeKey: String?,
        lastImportedPlayCount: Int,
        lastImportedRating: Int,
        lastImportedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.deviceID = deviceID
        self.ipodPersistentID = ipodPersistentID
        self.ipodPath = ipodPath
        self.ipodName = ipodName
        self.plexRatingKey = plexRatingKey
        self.sourceCompositeKey = sourceCompositeKey
        self.lastImportedPlayCount = lastImportedPlayCount
        self.lastImportedRating = lastImportedRating
        self.lastImportedAt = lastImportedAt
    }
}

public struct ExternalDeviceSyncRunRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let deviceID: String
    public let startedAt: Date
    public let finishedAt: Date
    public let status: String
    public let importedRatings: Int
    public let importedPlays: Int
    public let importedPlaylists: Int
    public let exportedTracks: Int
    public let exportedPlaylists: Int
    public let discardedItems: Int
    public let errorMessage: String?

    public init(
        id: String,
        deviceID: String,
        startedAt: Date,
        finishedAt: Date,
        status: String,
        importedRatings: Int,
        importedPlays: Int,
        importedPlaylists: Int,
        exportedTracks: Int,
        exportedPlaylists: Int,
        discardedItems: Int,
        errorMessage: String?
    ) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.importedRatings = importedRatings
        self.importedPlays = importedPlays
        self.importedPlaylists = importedPlaylists
        self.exportedTracks = exportedTracks
        self.exportedPlaylists = exportedPlaylists
        self.discardedItems = discardedItems
        self.errorMessage = errorMessage
    }
}

public protocol ExternalDeviceSyncRepositoryProtocol: Sendable {
    func fetchDevices() async throws -> [ExternalDeviceRecord]
    func upsertDevice(
        deviceID: String,
        displayName: String,
        modelIdentifier: String?,
        mountPath: String?,
        totalCapacity: Int64,
        freeCapacity: Int64,
        isSupported: Bool,
        supportMessage: String?,
        automaticSyncEnabled: Bool?
    ) async throws -> ExternalDeviceRecord
    func fetchMaps(deviceID: String, kind: ExternalDeviceMapRecord.Kind?) async throws -> [ExternalDeviceMapRecord]
    func upsertTrackMap(
        deviceID: String,
        ipodPersistentID: String,
        ipodPath: String?,
        ipodName: String?,
        plexRatingKey: String,
        sourceCompositeKey: String,
        lastImportedPlayCount: Int?,
        lastImportedRating: Int?
    ) async throws -> ExternalDeviceMapRecord
    func upsertPlaylistMap(
        deviceID: String,
        ipodPersistentID: String,
        ipodName: String?,
        plexRatingKey: String,
        sourceCompositeKey: String
    ) async throws -> ExternalDeviceMapRecord
    func updateImportCheckpoint(
        mapID: String,
        playCount: Int?,
        rating: Int?
    ) async throws
    func recordSyncRun(
        deviceID: String,
        startedAt: Date,
        finishedAt: Date,
        status: String,
        importedRatings: Int,
        importedPlays: Int,
        importedPlaylists: Int,
        exportedTracks: Int,
        exportedPlaylists: Int,
        discardedItems: Int,
        errorMessage: String?
    ) async throws -> ExternalDeviceSyncRunRecord
    func latestSyncRun(deviceID: String) async throws -> ExternalDeviceSyncRunRecord?
}

public final class ExternalDeviceSyncRepository: ExternalDeviceSyncRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchDevices() async throws -> [ExternalDeviceRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDExternalDevice.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "lastSeenAt", ascending: false),
                    NSSortDescriptor(key: "displayName", ascending: true)
                ]
                do {
                    continuation.resume(returning: try context.fetch(request).map(Self.mapDevice))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertDevice(
        deviceID: String,
        displayName: String,
        modelIdentifier: String?,
        mountPath: String?,
        totalCapacity: Int64,
        freeCapacity: Int64,
        isSupported: Bool,
        supportMessage: String?,
        automaticSyncEnabled: Bool?
    ) async throws -> ExternalDeviceRecord {
        try await withCheckedThrowingContinuation { continuation in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDExternalDevice.fetchRequest()
                request.predicate = NSPredicate(format: "deviceID == %@", deviceID)
                do {
                    let device = try context.fetch(request).first ?? CDExternalDevice(context: context)
                    device.deviceID = deviceID
                    device.displayName = displayName
                    device.modelIdentifier = modelIdentifier
                    device.mountPath = mountPath
                    device.totalCapacity = totalCapacity
                    device.freeCapacity = freeCapacity
                    device.isSupported = isSupported
                    device.supportMessage = supportMessage
                    if let automaticSyncEnabled {
                        device.automaticSyncEnabled = automaticSyncEnabled
                    } else if device.lastSeenAt == nil {
                        device.automaticSyncEnabled = true
                    }
                    device.lastSeenAt = Date()
                    try context.save()

                    let objectID = device.objectID
                    self.coreDataStack.viewContext.perform {
                        do {
                            guard let refreshed = try self.coreDataStack.viewContext.existingObject(with: objectID) as? CDExternalDevice else {
                                continuation.resume(throwing: NSError(domain: "ExternalDeviceSyncRepository", code: 1))
                                return
                            }
                            continuation.resume(returning: Self.mapDevice(refreshed))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchMaps(deviceID: String, kind: ExternalDeviceMapRecord.Kind? = nil) async throws -> [ExternalDeviceMapRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDExternalDeviceSyncMap.fetchRequest()
                if let kind {
                    request.predicate = NSPredicate(format: "deviceID == %@ AND kind == %@", deviceID, kind.rawValue)
                } else {
                    request.predicate = NSPredicate(format: "deviceID == %@", deviceID)
                }
                request.sortDescriptors = [
                    NSSortDescriptor(key: "kind", ascending: true),
                    NSSortDescriptor(key: "ipodName", ascending: true)
                ]
                do {
                    continuation.resume(returning: try context.fetch(request).map(Self.mapSyncMap))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertTrackMap(
        deviceID: String,
        ipodPersistentID: String,
        ipodPath: String?,
        ipodName: String?,
        plexRatingKey: String,
        sourceCompositeKey: String,
        lastImportedPlayCount: Int? = nil,
        lastImportedRating: Int? = nil
    ) async throws -> ExternalDeviceMapRecord {
        try await upsertMap(
            kind: .track,
            deviceID: deviceID,
            ipodPersistentID: ipodPersistentID,
            ipodPath: ipodPath,
            ipodName: ipodName,
            plexRatingKey: plexRatingKey,
            sourceCompositeKey: sourceCompositeKey,
            lastImportedPlayCount: lastImportedPlayCount,
            lastImportedRating: lastImportedRating
        )
    }

    public func upsertPlaylistMap(
        deviceID: String,
        ipodPersistentID: String,
        ipodName: String?,
        plexRatingKey: String,
        sourceCompositeKey: String
    ) async throws -> ExternalDeviceMapRecord {
        try await upsertMap(
            kind: .playlist,
            deviceID: deviceID,
            ipodPersistentID: ipodPersistentID,
            ipodPath: nil,
            ipodName: ipodName,
            plexRatingKey: plexRatingKey,
            sourceCompositeKey: sourceCompositeKey,
            lastImportedPlayCount: nil,
            lastImportedRating: nil
        )
    }

    public func updateImportCheckpoint(
        mapID: String,
        playCount: Int?,
        rating: Int?
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDExternalDeviceSyncMap.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", mapID)
                do {
                    guard let map = try context.fetch(request).first else {
                        continuation.resume(returning: ())
                        return
                    }
                    if let playCount {
                        map.lastImportedPlayCount = Int32(max(playCount, 0))
                    }
                    if let rating {
                        map.lastImportedRating = Int16(max(0, min(rating, 10)))
                    }
                    map.lastImportedAt = Date()
                    map.updatedAt = Date()
                    try context.save()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func recordSyncRun(
        deviceID: String,
        startedAt: Date,
        finishedAt: Date,
        status: String,
        importedRatings: Int,
        importedPlays: Int,
        importedPlaylists: Int,
        exportedTracks: Int,
        exportedPlaylists: Int,
        discardedItems: Int,
        errorMessage: String?
    ) async throws -> ExternalDeviceSyncRunRecord {
        try await withCheckedThrowingContinuation { continuation in
            self.coreDataStack.performBackgroundTask { context in
                do {
                    let run = CDExternalDeviceSyncRun(context: context)
                    run.id = UUID().uuidString
                    run.deviceID = deviceID
                    run.startedAt = startedAt
                    run.finishedAt = finishedAt
                    run.status = status
                    run.importedRatings = Int32(max(importedRatings, 0))
                    run.importedPlays = Int32(max(importedPlays, 0))
                    run.importedPlaylists = Int32(max(importedPlaylists, 0))
                    run.exportedTracks = Int32(max(exportedTracks, 0))
                    run.exportedPlaylists = Int32(max(exportedPlaylists, 0))
                    run.discardedItems = Int32(max(discardedItems, 0))
                    run.errorMessage = errorMessage

                    let deviceRequest = CDExternalDevice.fetchRequest()
                    deviceRequest.predicate = NSPredicate(format: "deviceID == %@", deviceID)
                    if let device = try context.fetch(deviceRequest).first {
                        device.lastSyncAt = finishedAt
                    }

                    try context.save()
                    continuation.resume(returning: Self.mapSyncRun(run))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func latestSyncRun(deviceID: String) async throws -> ExternalDeviceSyncRunRecord? {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDExternalDeviceSyncRun.fetchRequest()
                request.predicate = NSPredicate(format: "deviceID == %@", deviceID)
                request.sortDescriptors = [NSSortDescriptor(key: "finishedAt", ascending: false)]
                request.fetchLimit = 1
                do {
                    continuation.resume(returning: try context.fetch(request).first.map(Self.mapSyncRun))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func upsertMap(
        kind: ExternalDeviceMapRecord.Kind,
        deviceID: String,
        ipodPersistentID: String,
        ipodPath: String?,
        ipodName: String?,
        plexRatingKey: String,
        sourceCompositeKey: String,
        lastImportedPlayCount: Int?,
        lastImportedRating: Int?
    ) async throws -> ExternalDeviceMapRecord {
        let id = Self.mapID(deviceID: deviceID, kind: kind, ipodPersistentID: ipodPersistentID)
        return try await withCheckedThrowingContinuation { continuation in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDExternalDeviceSyncMap.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                do {
                    let map = try context.fetch(request).first ?? CDExternalDeviceSyncMap(context: context)
                    map.id = id
                    map.kind = kind.rawValue
                    map.deviceID = deviceID
                    map.ipodPersistentID = ipodPersistentID
                    map.ipodPath = ipodPath
                    map.ipodName = ipodName
                    map.plexRatingKey = plexRatingKey
                    map.sourceCompositeKey = sourceCompositeKey
                    if let lastImportedPlayCount {
                        map.lastImportedPlayCount = Int32(max(lastImportedPlayCount, 0))
                    }
                    if let lastImportedRating {
                        map.lastImportedRating = Int16(max(0, min(lastImportedRating, 10)))
                    }
                    map.updatedAt = Date()
                    try context.save()

                    let objectID = map.objectID
                    self.coreDataStack.viewContext.perform {
                        do {
                            guard let refreshed = try self.coreDataStack.viewContext.existingObject(with: objectID) as? CDExternalDeviceSyncMap else {
                                continuation.resume(throwing: NSError(domain: "ExternalDeviceSyncRepository", code: 2))
                                return
                            }
                            continuation.resume(returning: Self.mapSyncMap(refreshed))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func mapID(
        deviceID: String,
        kind: ExternalDeviceMapRecord.Kind,
        ipodPersistentID: String
    ) -> String {
        [deviceID, kind.rawValue, ipodPersistentID].joined(separator: "|")
    }

    private static func mapDevice(_ device: CDExternalDevice) -> ExternalDeviceRecord {
        ExternalDeviceRecord(
            id: device.deviceID,
            displayName: device.displayName ?? "iPod",
            modelIdentifier: device.modelIdentifier,
            mountPath: device.mountPath,
            totalCapacity: device.totalCapacity,
            freeCapacity: device.freeCapacity,
            isSupported: device.isSupported,
            supportMessage: device.supportMessage,
            automaticSyncEnabled: device.automaticSyncEnabled,
            lastSeenAt: device.lastSeenAt,
            lastSyncAt: device.lastSyncAt
        )
    }

    private static func mapSyncMap(_ map: CDExternalDeviceSyncMap) -> ExternalDeviceMapRecord {
        ExternalDeviceMapRecord(
            id: map.id,
            kind: ExternalDeviceMapRecord.Kind(rawValue: map.kind) ?? .track,
            deviceID: map.deviceID,
            ipodPersistentID: map.ipodPersistentID,
            ipodPath: map.ipodPath,
            ipodName: map.ipodName,
            plexRatingKey: map.plexRatingKey,
            sourceCompositeKey: map.sourceCompositeKey,
            lastImportedPlayCount: Int(map.lastImportedPlayCount),
            lastImportedRating: Int(map.lastImportedRating),
            lastImportedAt: map.lastImportedAt
        )
    }

    private static func mapSyncRun(_ run: CDExternalDeviceSyncRun) -> ExternalDeviceSyncRunRecord {
        ExternalDeviceSyncRunRecord(
            id: run.id,
            deviceID: run.deviceID,
            startedAt: run.startedAt ?? .distantPast,
            finishedAt: run.finishedAt ?? .distantPast,
            status: run.status ?? "unknown",
            importedRatings: Int(run.importedRatings),
            importedPlays: Int(run.importedPlays),
            importedPlaylists: Int(run.importedPlaylists),
            exportedTracks: Int(run.exportedTracks),
            exportedPlaylists: Int(run.exportedPlaylists),
            discardedItems: Int(run.discardedItems),
            errorMessage: run.errorMessage
        )
    }
}
