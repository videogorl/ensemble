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
                    let hubs = cdHubs.map { Hub(from: $0) }
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
                    
                    // Add new hubs
                    for (hubIndex, hub) in hubs.enumerated() {
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
