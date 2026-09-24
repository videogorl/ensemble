import CoreData
import Foundation

public struct PendingMutationRecord: Sendable {
    public let id: String
    public let mutationType: CDPendingMutation.MutationType
    public let payload: Data
    public let sourceCompositeKey: String?
    public let retryCount: Int16
    public let status: CDPendingMutation.MutationStatus

    public init(
        id: String,
        mutationType: CDPendingMutation.MutationType,
        payload: Data,
        sourceCompositeKey: String?,
        retryCount: Int16,
        status: CDPendingMutation.MutationStatus
    ) {
        self.id = id
        self.mutationType = mutationType
        self.payload = payload
        self.sourceCompositeKey = sourceCompositeKey
        self.retryCount = retryCount
        self.status = status
    }
}

public protocol PendingMutationRepositoryProtocol: Sendable {
    func fetchPendingMutations() async throws -> [CDPendingMutation]
    func fetchPendingMutationRecords() async throws -> [PendingMutationRecord]
    func fetchAllMutations() async throws -> [CDPendingMutation]
    func fetchAllMutationRecords() async throws -> [PendingMutationRecord]
    func enqueueMutation(id: String, type: CDPendingMutation.MutationType, payload: Data, sourceCompositeKey: String?) async throws
    func incrementRetryCount(id: String) async throws
    func markFailed(id: String) async throws
    func resetToRetry(id: String) async throws
    func deleteMutation(id: String) async throws
    func deleteMutations(forSourceCompositeKey sourceCompositeKey: String) async throws
    func deleteAllMutations() async throws
    func countPendingMutations() async throws -> Int
}

public extension PendingMutationRepositoryProtocol {
    func fetchPendingMutationRecords() async throws -> [PendingMutationRecord] {
        try await fetchPendingMutations().map(PendingMutationRecord.init)
    }

    func fetchAllMutationRecords() async throws -> [PendingMutationRecord] {
        try await fetchAllMutations().map(PendingMutationRecord.init)
    }

    func deleteMutations(forSourceCompositeKey sourceCompositeKey: String) async throws {
        for mutation in try await fetchAllMutations()
        where mutation.sourceCompositeKey == sourceCompositeKey || mutation.sourceCompositeKey == nil {
            try await deleteMutation(id: mutation.id)
        }
    }
}

public final class PendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Fetch all mutations in pending status, ordered by creation date (oldest first)
    public func fetchPendingMutations() async throws -> [CDPendingMutation] {
        try await coreDataStack.performViewContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", CDPendingMutation.MutationStatus.pending.rawValue)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request)
        }
    }

    public func fetchPendingMutationRecords() async throws -> [PendingMutationRecord] {
        try await coreDataStack.performViewContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", CDPendingMutation.MutationStatus.pending.rawValue)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request).map(PendingMutationRecord.init)
        }
    }

    /// Fetch all mutations (pending + failed), ordered by creation date descending (newest first)
    public func fetchAllMutations() async throws -> [CDPendingMutation] {
        try await coreDataStack.performViewContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request)
        }
    }

    public func fetchAllMutationRecords() async throws -> [PendingMutationRecord] {
        try await coreDataStack.performViewContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request).map(PendingMutationRecord.init)
        }
    }

    /// Enqueue a new mutation for later replay
    public func enqueueMutation(
        id: String,
        type: CDPendingMutation.MutationType,
        payload: Data,
        sourceCompositeKey: String?
    ) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let mutation = CDPendingMutation(context: context)
            mutation.id = id
            mutation.type = type.rawValue
            mutation.payload = payload
            mutation.createdAt = Date()
            mutation.retryCount = 0
            mutation.status = CDPendingMutation.MutationStatus.pending.rawValue
            mutation.sourceCompositeKey = sourceCompositeKey
            try context.save()
        }
    }

    /// Increment the retry count for a mutation
    public func incrementRetryCount(id: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            if let mutation = try context.fetch(request).first {
                mutation.retryCount += 1
                try context.save()
            }
        }
    }

    /// Mark a mutation as permanently failed (exhausted retries)
    public func markFailed(id: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            if let mutation = try context.fetch(request).first {
                mutation.status = CDPendingMutation.MutationStatus.failed.rawValue
                try context.save()
            }
        }
    }

    /// Reset a failed mutation back to pending so it can be retried
    public func resetToRetry(id: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            if let mutation = try context.fetch(request).first {
                mutation.status = CDPendingMutation.MutationStatus.pending.rawValue
                mutation.retryCount = 0
                try context.save()
            }
        }
    }

    /// Delete a single mutation (e.g., after successful replay)
    public func deleteMutation(id: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            if let mutation = try context.fetch(request).first {
                context.delete(mutation)
                try context.save()
            }
        }
    }

    /// Delete one source's pending and failed mutations, plus invalid unscoped rows.
    public func deleteMutations(forSourceCompositeKey sourceCompositeKey: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey),
                NSPredicate(format: "sourceCompositeKey == nil")
            ])
            for mutation in try context.fetch(request) {
                context.delete(mutation)
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    /// Delete all pending and failed mutations
    public func deleteAllMutations() async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPendingMutation.fetchRequest()
            let mutations = try context.fetch(request)
            for mutation in mutations {
                context.delete(mutation)
            }
            try context.save()
        }
    }

    /// Count pending (not failed) mutations
    public func countPendingMutations() async throws -> Int {
        try await coreDataStack.performViewContext { context in
            let request = CDPendingMutation.fetchRequest()
            request.predicate = NSPredicate(format: "status == %@", CDPendingMutation.MutationStatus.pending.rawValue)
            return try context.count(for: request)
        }
    }
}

private extension PendingMutationRecord {
    init(_ mutation: CDPendingMutation) {
        self.init(
            id: mutation.id,
            mutationType: mutation.mutationType,
            payload: mutation.payload,
            sourceCompositeKey: mutation.sourceCompositeKey,
            retryCount: mutation.retryCount,
            status: mutation.mutationStatus
        )
    }
}
