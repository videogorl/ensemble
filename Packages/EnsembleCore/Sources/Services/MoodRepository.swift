import EnsemblePersistence
import Foundation

private final class MoodSaveCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func commit(_ operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        try operation()
    }
}

/// Repository for managing cached mood data
public final class MoodRepository: @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack) {
        self.coreDataStack = coreDataStack
    }

    public func fetchMoods() async throws -> [Mood] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDMood.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                
                do {
                    let results = try context.fetch(request)
                    let moods = results.map { Mood(from: $0) }
                    continuation.resume(returning: moods)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func saveMoods(_ moods: [Mood]) async throws {
        let cancellationGate = MoodSaveCancellationGate()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                coreDataStack.performBackgroundTask { context in
                    do {
                        // Clear existing moods
                        let deleteRequest = CDMood.fetchRequest()
                        let deleteResults = try context.fetch(deleteRequest)
                        for mood in deleteResults {
                            context.delete(mood)
                        }

                        // Save new moods
                        for mood in moods {
                            let cdMood = CDMood(context: context)
                            cdMood.id = mood.id
                            cdMood.key = mood.key
                            cdMood.title = mood.title
                            cdMood.sourceCompositeKey = mood.sourceCompositeKey
                        }

                        try cancellationGate.commit {
                            try context.save()
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationGate.cancel()
        }
    }

    public func deleteAllMoods() async throws {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let deleteRequest = CDMood.fetchRequest()
                    let deleteResults = try context.fetch(deleteRequest)
                    for mood in deleteResults {
                        context.delete(mood)
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

// MARK: - CoreData Model Extensions

extension Mood {
    init(from cdMood: CDMood) {
        self.init(
            id: cdMood.id,
            key: cdMood.key,
            title: cdMood.title,
            sourceCompositeKey: cdMood.sourceCompositeKey
        )
    }
}
