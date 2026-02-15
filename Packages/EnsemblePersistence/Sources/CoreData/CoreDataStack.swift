import CoreData
import Foundation

public final class CoreDataStack: @unchecked Sendable {
    public static let shared = CoreDataStack()

    /// App Group identifier for sharing CoreData between main app and extensions
    public static let appGroupIdentifier = "group.com.videogorl.ensemble"

    public let persistentContainer: NSPersistentContainer

    public var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    /// URL to the shared App Group container, if available
    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// URL for the persistent store (uses shared container if available)
    private static var storeURL: URL {
        if let sharedURL = sharedContainerURL {
            return sharedURL.appendingPathComponent("Ensemble.sqlite")
        }
        // Fallback to default location (shouldn't happen in production)
        return NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("Ensemble.sqlite")
    }

    private init() {
        // Load the model from the bundle
        guard let modelURL = Bundle.module.url(forResource: "Ensemble", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load CoreData model")
        }

        persistentContainer = NSPersistentContainer(name: "Ensemble", managedObjectModel: model)

        // Configure persistent store to use shared App Group container
        let storeDescription = NSPersistentStoreDescription(url: Self.storeURL)
        storeDescription.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        storeDescription.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        persistentContainer.persistentStoreDescriptions = [storeDescription]

        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load CoreData store: \(error)")
            }
            print("CoreData store loaded at: \(description.url?.path ?? "unknown")")
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
