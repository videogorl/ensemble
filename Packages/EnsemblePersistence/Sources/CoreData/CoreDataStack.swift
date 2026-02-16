import CoreData
import Foundation

public final class CoreDataStack: @unchecked Sendable {
    public static let shared = CoreDataStack()

    public let persistentContainer: NSPersistentContainer

    public var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    private init() {
        // Load the model from the bundle
        guard let modelURL = Bundle.module.url(forResource: "Ensemble", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load CoreData model")
        }

        persistentContainer = NSPersistentContainer(name: "Ensemble", managedObjectModel: model)

        // Configure for lightweight migration
        let description = persistentContainer.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load CoreData store: \(error)")
            }
        }

        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Create an in-memory stack for testing/previews
    public static func inMemory() -> CoreDataStack {
        let stack = CoreDataStack()
        return stack
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
                print("CoreData save error: \(error)")
            }
        }
    }

    public func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        persistentContainer.performBackgroundTask(block)
    }
}
