import CoreData
import Foundation

public final class CoreDataStack: @unchecked Sendable {
    public static let shared = CoreDataStack(inMemory: false)

    public let persistentContainer: NSPersistentContainer

    public var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    private init(inMemory: Bool) {
        let model = Self.loadManagedObjectModel()

        persistentContainer = NSPersistentContainer(name: "Ensemble", managedObjectModel: model)

        // Configure the store description up-front for either on-disk or in-memory usage.
        let description = persistentContainer.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
            description.url = URL(fileURLWithPath: "/dev/null")
        }
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        persistentContainer.persistentStoreDescriptions = [description]

        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load CoreData store: \(error)")
            }
        }

        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // Ensure objects are always refetched from store (not cached)
        // This fixes stale data after background sync operations
        viewContext.stalenessInterval = 0
    }

    /// Create an in-memory stack for testing/previews
    public static func inMemory() -> CoreDataStack {
        CoreDataStack(inMemory: true)
    }

    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    public func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                #if DEBUG
                EnsembleLogger.debug("CoreData save error: \(error)")
                #endif
            }
        }
    }

    public func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        persistentContainer.performBackgroundTask { context in
            // Match the merge policy used by viewContext and newBackgroundContext()
            // so concurrent writes from download workers, sync, and target progress
            // refresh resolve automatically instead of throwing merge conflicts.
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            block(context)
        }
    }

    /// Refresh all objects in the view context to ensure they reflect the latest store data.
    /// Call this after background sync operations to ensure UI sees updated data.
    public func refreshViewContext() {
        viewContext.perform {
            self.viewContext.refreshAllObjects()
        }
    }

    /// Load the CoreData model from the module bundle with resilient fallbacks.
    /// SwiftPM can expose either compiled `.momd` resources or nested resource paths depending on tooling.
    private static func loadManagedObjectModel() -> NSManagedObjectModel {
        let bundle = Bundle.module

        let directCandidates: [URL?] = [
            bundle.url(forResource: "Ensemble", withExtension: "momd"),
            bundle.url(forResource: "Ensemble", withExtension: "mom"),
            bundle.url(forResource: "SwiftPMEnsemble", withExtension: "momd"),
            bundle.url(forResource: "SwiftPMEnsemble", withExtension: "mom"),
            bundle.url(forResource: "Ensemble", withExtension: "momd", subdirectory: "Compiled"),
            bundle.url(forResource: "Ensemble", withExtension: "mom", subdirectory: "Compiled"),
            bundle.url(forResource: "SwiftPMEnsemble", withExtension: "momd", subdirectory: "Compiled"),
            bundle.url(forResource: "SwiftPMEnsemble", withExtension: "mom", subdirectory: "Compiled"),
        ]

        let resourceRootCandidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("Ensemble.momd"),
            bundle.resourceURL?.appendingPathComponent("Ensemble.mom"),
            bundle.resourceURL?.appendingPathComponent("SwiftPMEnsemble.momd"),
            bundle.resourceURL?.appendingPathComponent("SwiftPMEnsemble.mom"),
            bundle.resourceURL?.appendingPathComponent("Compiled/Ensemble.momd"),
            bundle.resourceURL?.appendingPathComponent("Compiled/Ensemble.mom"),
            bundle.resourceURL?.appendingPathComponent("Compiled/SwiftPMEnsemble.momd"),
            bundle.resourceURL?.appendingPathComponent("Compiled/SwiftPMEnsemble.mom"),
        ]

        for candidate in (directCandidates + resourceRootCandidates).compactMap({ $0 }) {
            if let model = NSManagedObjectModel(contentsOf: candidate) {
                return model
            }
        }

        if let mergedModel = NSManagedObjectModel.mergedModel(from: [bundle]) {
            return mergedModel
        }

        fatalError("Failed to load CoreData model from Bundle.module (\(bundle.bundleURL.path))")
    }
}
