import CoreData
import Foundation
import EnsemblePersistence

public enum HomeFeedSnapshotFreshnessState: String, Sendable, Codable, Equatable {
    case fresh
    case stale
    case failed
}

public struct HomeFeedCachedSnapshot: Sendable, Equatable {
    public static let currentSchemaVersion: Int16 = 1

    public let id: String
    public let sourceScopeKey: String?
    public let sourceName: String?
    public let createdAt: Date
    public let fetchedAt: Date?
    public let refreshReason: String
    public let freshnessState: HomeFeedSnapshotFreshnessState
    public let schemaVersion: Int16
    public let isLastGood: Bool
    public let hubs: [Hub]

    public init(
        id: String = UUID().uuidString,
        sourceScopeKey: String?,
        sourceName: String?,
        createdAt: Date = Date(),
        fetchedAt: Date?,
        refreshReason: String,
        freshnessState: HomeFeedSnapshotFreshnessState,
        schemaVersion: Int16 = Self.currentSchemaVersion,
        isLastGood: Bool,
        hubs: [Hub]
    ) {
        self.id = id
        self.sourceScopeKey = sourceScopeKey
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.fetchedAt = fetchedAt
        self.refreshReason = refreshReason
        self.freshnessState = freshnessState
        self.schemaVersion = schemaVersion
        self.isLastGood = isLastGood
        self.hubs = hubs
    }
}

public protocol HubRepositoryProtocol: Sendable {
    func fetchHubs() async throws -> [Hub]
    func saveHubs(_ hubs: [Hub]) async throws
    func deleteHubs(forSourceCompositeKey sourceKey: String) async throws
    func deleteAllHubs() async throws
    func fetchLatestHomeFeedSnapshot(sourceScopeKey: String?) async throws -> HomeFeedCachedSnapshot?
    func saveHomeFeedSnapshot(_ snapshot: HomeFeedCachedSnapshot) async throws
    func markHomeFeedSnapshotLastGood(id: String, freshnessState: HomeFeedSnapshotFreshnessState) async throws
    func deleteHomeFeedSnapshots(sourceScopeKey: String?) async throws
}

public final class HubRepository: HubRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchHubs() async throws -> [Hub] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    if let snapshot = try Self.fetchLatestSnapshot(in: context, sourceScopeKey: nil) {
                        continuation.resume(returning: snapshot.hubs)
                        return
                    }

                    let cdHubs = try Self.fetchLegacyHubs(in: context)
                    var seen = Set<String>()
                    // Deduplicate by hub ID — concurrent saveHubs calls can race and
                    // insert the same hubs twice via separate background contexts.
                    let hubs = cdHubs.compactMap { cdHub -> Hub? in
                        let hub = Hub(from: cdHub)
                        guard seen.insert(hub.id).inserted else { return nil }
                        return hub
                    }
                    continuation.resume(returning: hubs)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func saveHubs(_ hubs: [Hub]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    try Self.deleteSnapshots(in: context, sourceScopeKey: nil)
                    try Self.deleteLegacyHubs(in: context)

                    // Deduplicate by ID before inserting — guards against the caller
                    // accidentally passing duplicate hubs and against concurrent saves
                    // writing the same hubs via separate background contexts.
                    var seen = Set<String>()
                    let uniqueHubs = hubs.filter { seen.insert($0.id).inserted }

                    // Add new hubs
                    for (hubIndex, hub) in uniqueHubs.enumerated() {
                        _ = Self.insertHub(hub, order: hubIndex, in: context)
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllHubs() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    try Self.deleteSnapshots(in: context, sourceScopeKey: nil)
                    try Self.deleteLegacyHubs(in: context)
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteHubs(forSourceCompositeKey sourceKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let hubs = try context.fetch(CDHub.fetchRequest())
                    for hub in hubs {
                        let items = hub.itemsArray
                        let sourceItems = items.filter { $0.sourceCompositeKey == sourceKey }
                        for item in sourceItems {
                            context.delete(item)
                        }
                        if sourceItems.count == items.count {
                            context.delete(hub)
                        }
                    }
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchLatestHomeFeedSnapshot(sourceScopeKey: String?) async throws -> HomeFeedCachedSnapshot? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    continuation.resume(returning: try Self.fetchLatestSnapshot(in: context, sourceScopeKey: sourceScopeKey))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func saveHomeFeedSnapshot(_ snapshot: HomeFeedCachedSnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    try Self.deleteSnapshots(in: context, sourceScopeKey: snapshot.sourceScopeKey)

                    let cdSnapshot = CDHomeFeedSnapshot(context: context)
                    cdSnapshot.id = snapshot.id
                    cdSnapshot.sourceScopeKey = snapshot.sourceScopeKey
                    cdSnapshot.sourceName = snapshot.sourceName
                    cdSnapshot.createdAt = snapshot.createdAt
                    cdSnapshot.fetchedAt = snapshot.fetchedAt
                    cdSnapshot.refreshReason = snapshot.refreshReason
                    cdSnapshot.freshnessState = snapshot.freshnessState.rawValue
                    cdSnapshot.schemaVersion = snapshot.schemaVersion
                    cdSnapshot.isLastGood = snapshot.isLastGood

                    var seen = Set<String>()
                    let uniqueHubs = snapshot.hubs.filter { seen.insert($0.id).inserted }
                    let hubsSet = NSMutableOrderedSet()
                    for (hubIndex, hub) in uniqueHubs.enumerated() {
                        let cdHub = Self.insertHub(hub, order: hubIndex, in: context)
                        cdHub.snapshot = cdSnapshot
                        hubsSet.add(cdHub)
                    }
                    cdSnapshot.hubs = hubsSet

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func markHomeFeedSnapshotLastGood(id: String, freshnessState: HomeFeedSnapshotFreshnessState) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDHomeFeedSnapshot.fetchRequest()
                    request.fetchLimit = 1
                    request.predicate = NSPredicate(format: "id == %@", id)

                    guard let snapshot = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    snapshot.isLastGood = true
                    snapshot.freshnessState = freshnessState.rawValue
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteHomeFeedSnapshots(sourceScopeKey: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    try Self.deleteSnapshots(in: context, sourceScopeKey: sourceScopeKey)
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchLatestSnapshot(
        in context: NSManagedObjectContext,
        sourceScopeKey: String?
    ) throws -> HomeFeedCachedSnapshot? {
        let request = CDHomeFeedSnapshot.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [
            NSSortDescriptor(key: "isLastGood", ascending: false),
            NSSortDescriptor(key: "fetchedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false),
        ]
        if let sourceScopeKey {
            request.predicate = NSPredicate(format: "sourceScopeKey == %@", sourceScopeKey)
        }

        guard let cdSnapshot = try context.fetch(request).first else { return nil }
        return HomeFeedCachedSnapshot(from: cdSnapshot)
    }

    private static func fetchLegacyHubs(in context: NSManagedObjectContext) throws -> [CDHub] {
        let request = CDHub.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        request.predicate = NSPredicate(format: "snapshot == nil")
        return try context.fetch(request)
    }

    private static func deleteLegacyHubs(in context: NSManagedObjectContext) throws {
        let hubsRequest = CDHub.fetchRequest()
        let existingHubs = try context.fetch(hubsRequest)
        for hub in existingHubs {
            context.delete(hub)
        }
    }

    private static func deleteSnapshots(in context: NSManagedObjectContext, sourceScopeKey: String?) throws {
        let request = CDHomeFeedSnapshot.fetchRequest()
        if let sourceScopeKey {
            request.predicate = NSPredicate(format: "sourceScopeKey == %@", sourceScopeKey)
        }
        let snapshots = try context.fetch(request)
        for snapshot in snapshots {
            context.delete(snapshot)
        }
    }

    private static func insertHub(_ hub: Hub, order: Int, in context: NSManagedObjectContext) -> CDHub {
        let cdHub = CDHub(context: context)
        cdHub.id = hub.id
        cdHub.title = hub.title
        cdHub.type = hub.type
        cdHub.context = hub.context
        cdHub.order = Int16(clamping: order)
        cdHub.semanticKind = hub.semanticKind.rawValue
        cdHub.sourceScopeSourceCompositeKey = hub.sourceScope.sourceCompositeKey
        cdHub.sourceScopeServerCompositeKey = hub.sourceScope.serverCompositeKey

        let itemsSet = NSMutableOrderedSet()
        for (itemIndex, item) in hub.items.enumerated() {
            let cdItem = CDHubItem(context: context)
            cdItem.id = item.id
            cdItem.key = item.track?.key ?? item.album?.key ?? item.artist?.key ?? item.playlist?.key
            cdItem.type = item.type
            cdItem.title = item.title
            cdItem.subtitle = item.subtitle
            cdItem.thumbPath = item.thumbPath
            cdItem.sourceCompositeKey = item.sourceCompositeKey
            cdItem.year = item.year.map(NSNumber.init(value:))
            cdItem.addedAt = item.addedAt
            cdItem.lastViewedAt = item.lastViewedAt
            cdItem.viewCount = item.viewCount.map(NSNumber.init(value:))
            cdItem.order = Int16(clamping: itemIndex)
            cdItem.hub = cdHub
            itemsSet.add(cdItem)
        }
        cdHub.items = itemsSet
        return cdHub
    }
}

private extension HomeFeedCachedSnapshot {
    init(from cd: CDHomeFeedSnapshot) {
        self.init(
            id: cd.id,
            sourceScopeKey: cd.sourceScopeKey,
            sourceName: cd.sourceName,
            createdAt: cd.createdAt ?? Date.distantPast,
            fetchedAt: cd.fetchedAt,
            refreshReason: cd.refreshReason ?? "unknown",
            freshnessState: HomeFeedSnapshotFreshnessState(rawValue: cd.freshnessState ?? "") ?? .stale,
            schemaVersion: cd.schemaVersion,
            isLastGood: cd.isLastGood,
            hubs: cd.hubsArray.map { Hub(from: $0) }
        )
    }
}
