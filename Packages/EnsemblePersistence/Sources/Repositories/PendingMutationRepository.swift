import CoreData
import Foundation

public protocol PendingMutationRepositoryProtocol: Sendable {
    func fetchPendingMutations() async throws -> [CDPendingMutation]
    func fetchAllMutations() async throws -> [CDPendingMutation]
    func enqueueMutation(id: String, type: CDPendingMutation.MutationType, payload: Data, sourceCompositeKey: String?) async throws
    func incrementRetryCount(id: String) async throws
    func markFailed(id: String) async throws
    func resetToRetry(id: String) async throws
    func deleteMutation(id: String) async throws
    func deleteAllMutations() async throws
    func countPendingMutations() async throws -> Int
}

public final class PendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Fetch all mutations in pending status, ordered by creation date (oldest first)
    public func fetchPendingMutations() async throws -> [CDPendingMutation] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "status == %@", CDPendingMutation.MutationStatus.pending.rawValue)
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                do {
                    let results = try context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all mutations (pending + failed), ordered by creation date descending (newest first)
    public func fetchAllMutations() async throws -> [CDPendingMutation] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                do {
                    let results = try context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueue a new mutation for later replay
    public func enqueueMutation(
        id: String,
        type: CDPendingMutation.MutationType,
        payload: Data,
        sourceCompositeKey: String?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let mutation = CDPendingMutation(context: context)
                mutation.id = id
                mutation.type = type.rawValue
                mutation.payload = payload
                mutation.createdAt = Date()
                mutation.retryCount = 0
                mutation.status = CDPendingMutation.MutationStatus.pending.rawValue
                mutation.sourceCompositeKey = sourceCompositeKey
                do {
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Increment the retry count for a mutation
    public func incrementRetryCount(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1
                do {
                    if let mutation = try context.fetch(request).first {
                        mutation.retryCount += 1
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Mark a mutation as permanently failed (exhausted retries)
    public func markFailed(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1
                do {
                    if let mutation = try context.fetch(request).first {
                        mutation.status = CDPendingMutation.MutationStatus.failed.rawValue
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reset a failed mutation back to pending so it can be retried
    public func resetToRetry(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1
                do {
                    if let mutation = try context.fetch(request).first {
                        mutation.status = CDPendingMutation.MutationStatus.pending.rawValue
                        mutation.retryCount = 0
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Delete a single mutation (e.g., after successful replay)
    public func deleteMutation(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                request.fetchLimit = 1
                do {
                    if let mutation = try context.fetch(request).first {
                        context.delete(mutation)
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Delete all pending and failed mutations
    public func deleteAllMutations() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                do {
                    let mutations = try context.fetch(request)
                    for mutation in mutations {
                        context.delete(mutation)
                    }
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Count pending (not failed) mutations
    public func countPendingMutations() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDPendingMutation.fetchRequest()
                request.predicate = NSPredicate(format: "status == %@", CDPendingMutation.MutationStatus.pending.rawValue)
                do {
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
