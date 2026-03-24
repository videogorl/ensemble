import CoreData
import Foundation
import EnsemblePersistence

public protocol HubRepositoryProtocol: Sendable {
    func fetchHubs() async throws -> [Hub]
    func saveHubs(_ hubs: [Hub]) async throws
    func deleteAllHubs() async throws
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
                let request = CDHub.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
                do {
                    let cdHubs = try context.fetch(request)
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
                    // Clear existing hubs before saving new ones
                    let hubsRequest = CDHub.fetchRequest()
                    let existingHubs = try context.fetch(hubsRequest)
                    for hub in existingHubs {
                        context.delete(hub)
                    }

                    // Deduplicate by ID before inserting — guards against the caller
                    // accidentally passing duplicate hubs and against concurrent saves
                    // writing the same hubs via separate background contexts.
                    var seen = Set<String>()
                    let uniqueHubs = hubs.filter { seen.insert($0.id).inserted }

                    // Add new hubs
                    for (hubIndex, hub) in uniqueHubs.enumerated() {
                        let cdHub = CDHub(context: context)
                        cdHub.id = hub.id
                        cdHub.title = hub.title
                        cdHub.type = hub.type
                        cdHub.order = Int16(hubIndex)
                        
                        let itemsSet = NSMutableOrderedSet()
                        for (itemIndex, item) in hub.items.enumerated() {
                            let cdItem = CDHubItem(context: context)
                            cdItem.id = item.id
                            cdItem.type = item.type
                            cdItem.title = item.title
                            cdItem.subtitle = item.subtitle
                            cdItem.thumbPath = item.thumbPath
                            cdItem.sourceCompositeKey = item.sourceCompositeKey
                            cdItem.order = Int16(itemIndex)
                            cdItem.hub = cdHub
                            itemsSet.add(cdItem)
                        }
                        cdHub.items = itemsSet
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
                    let hubsRequest = CDHub.fetchRequest()
                    let existingHubs = try context.fetch(hubsRequest)
                    for hub in existingHubs {
                        context.delete(hub)
                    }
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
