import CoreData
import Foundation

public struct OfflineTrackReference: Hashable, Sendable {
    public let trackRatingKey: String
    public let trackSourceCompositeKey: String

    public init(trackRatingKey: String, trackSourceCompositeKey: String) {
        self.trackRatingKey = trackRatingKey
        self.trackSourceCompositeKey = trackSourceCompositeKey
    }

    public var membershipID: String {
        "\(trackSourceCompositeKey)|\(trackRatingKey)"
    }
}

public protocol OfflineDownloadTargetRepositoryProtocol: Sendable {
    func fetchTargets() async throws -> [CDOfflineDownloadTarget]
    func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget?

    func upsertTarget(
        key: String,
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?,
        displayName: String?
    ) async throws -> CDOfflineDownloadTarget

    func updateTarget(
        key: String,
        status: CDOfflineDownloadTarget.Status,
        totalTrackCount: Int,
        completedTrackCount: Int,
        progress: Float,
        lastError: String?
    ) async throws

    func deleteTarget(key: String) async throws

    /// Delete all targets and their memberships.
    func deleteAllTargets() async throws

    func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership]
    func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference]

    func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws

    func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool
    func membershipCount(for reference: OfflineTrackReference) async throws -> Int

    /// Returns the total duration (in milliseconds) of all unique tracks across all download targets.
    func totalTrackDurationMs() async throws -> Int64
}

public final class OfflineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchTargets() async throws -> [CDOfflineDownloadTarget] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDOfflineDownloadTarget.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                do {
                    let targets = try context.fetch(request)
                    continuation.resume(returning: targets)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDOfflineDownloadTarget.fetchRequest()
                request.predicate = NSPredicate(format: "key == %@", key)
                request.fetchLimit = 1
                do {
                    let target = try context.fetch(request).first
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertTarget(
        key: String,
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?,
        displayName: String?
    ) async throws -> CDOfflineDownloadTarget {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDOfflineDownloadTarget.fetchRequest()
                    request.predicate = NSPredicate(format: "key == %@", key)
                    let existing = try context.fetch(request).first
                    let target = existing ?? CDOfflineDownloadTarget(context: context)

                    target.key = key
                    target.targetKind = kind
                    target.ratingKey = ratingKey
                    target.sourceCompositeKey = sourceCompositeKey
                    target.displayName = displayName
                    target.updatedAt = Date()
                    if target.createdAt == nil {
                        target.createdAt = Date()
                    }
                    if target.status == nil {
                        target.targetStatus = .pending
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDOfflineDownloadTarget.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "key == %@", key)
                        mainRequest.fetchLimit = 1
                        if let target = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: target)
                        } else {
                            continuation.resume(throwing: NSError(domain: "OfflineDownloadTargetRepository", code: 1))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateTarget(
        key: String,
        status: CDOfflineDownloadTarget.Status,
        totalTrackCount: Int,
        completedTrackCount: Int,
        progress: Float,
        lastError: String?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDOfflineDownloadTarget.fetchRequest()
                    request.predicate = NSPredicate(format: "key == %@", key)
                    request.fetchLimit = 1

                    if let target = try context.fetch(request).first {
                        target.targetStatus = status
                        target.totalTrackCount = Int32(totalTrackCount)
                        target.completedTrackCount = Int32(completedTrackCount)
                        target.progress = progress
                        target.lastError = lastError
                        target.updatedAt = Date()
                        try context.save()
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteTarget(key: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDOfflineDownloadTarget.fetchRequest()
                    request.predicate = NSPredicate(format: "key == %@", key)
                    request.fetchLimit = 1
                    if let target = try context.fetch(request).first {
                        context.delete(target)
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllTargets() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Delete all memberships
                    let membershipRequest = CDOfflineDownloadMembership.fetchRequest()
                    let memberships = try context.fetch(membershipRequest)
                    for membership in memberships {
                        context.delete(membership)
                    }

                    // Delete all targets
                    let targetRequest = CDOfflineDownloadTarget.fetchRequest()
                    let targets = try context.fetch(targetRequest)
                    for target in targets {
                        context.delete(target)
                    }

                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDOfflineDownloadMembership.fetchRequest()
                request.predicate = NSPredicate(format: "targetKey == %@", targetKey)
                request.sortDescriptors = [NSSortDescriptor(key: "trackRatingKey", ascending: true)]
                do {
                    let memberships = try context.fetch(request)
                    continuation.resume(returning: memberships)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] {
        let memberships = try await fetchMemberships(targetKey: targetKey)
        return memberships.map {
            OfflineTrackReference(
                trackRatingKey: $0.trackRatingKey,
                trackSourceCompositeKey: $0.trackSourceCompositeKey
            )
        }
    }

    public func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                // Use merge-by-property policy to handle concurrent writes from
                // different targets referencing the same CDTrack objects.
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

                do {
                    try self.performReplaceMemberships(
                        targetKey: targetKey,
                        trackReferences: trackReferences,
                        context: context
                    )
                    continuation.resume()
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && (error.code == NSManagedObjectMergeError || error.code == NSManagedObjectConstraintMergeError) {
                    // Single retry on merge conflict
                    context.rollback()
                    do {
                        try self.performReplaceMemberships(
                            targetKey: targetKey,
                            trackReferences: trackReferences,
                            context: context
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Core membership replacement logic, extracted for retry support.
    private func performReplaceMemberships(
        targetKey: String,
        trackReferences: [OfflineTrackReference],
        context: NSManagedObjectContext
    ) throws {
        let targetRequest = CDOfflineDownloadTarget.fetchRequest()
        targetRequest.predicate = NSPredicate(format: "key == %@", targetKey)
        targetRequest.fetchLimit = 1

        guard let target = try context.fetch(targetRequest).first else {
            throw NSError(domain: "OfflineDownloadTargetRepository", code: 2)
        }

        let membershipRequest = CDOfflineDownloadMembership.fetchRequest()
        membershipRequest.predicate = NSPredicate(format: "targetKey == %@", targetKey)
        let existingMemberships = try context.fetch(membershipRequest)
        let existingByID = Dictionary(uniqueKeysWithValues: existingMemberships.map { ($0.id, $0) })

        let normalizedReferences = Array(Set(trackReferences)).sorted {
            if $0.trackSourceCompositeKey != $1.trackSourceCompositeKey {
                return $0.trackSourceCompositeKey < $1.trackSourceCompositeKey
            }
            return $0.trackRatingKey < $1.trackRatingKey
        }

        let incomingMembershipIDs = Set(
            normalizedReferences.map { self.membershipID(targetKey: targetKey, reference: $0) }
        )

        for membership in existingMemberships where !incomingMembershipIDs.contains(membership.id) {
            context.delete(membership)
        }

        // Cache track resolutions within this call to avoid repeated fetches
        // for the same track referenced by multiple memberships
        var trackCache: [String: CDTrack?] = [:]

        for reference in normalizedReferences {
            let id = self.membershipID(targetKey: targetKey, reference: reference)
            let membership = existingByID[id] ?? CDOfflineDownloadMembership(context: context)
            membership.id = id
            membership.targetKey = targetKey
            membership.trackRatingKey = reference.trackRatingKey
            membership.trackSourceCompositeKey = reference.trackSourceCompositeKey
            membership.createdAt = membership.createdAt ?? Date()
            membership.target = target

            let cacheKey = "\(reference.trackRatingKey):\(reference.trackSourceCompositeKey)"
            if let cached = trackCache[cacheKey] {
                membership.track = cached
            } else {
                let resolved = try self.resolveTrack(reference: reference, in: context)
                trackCache[cacheKey] = resolved
                membership.track = resolved
            }
        }

        target.updatedAt = Date()
        try context.save()
    }

    public func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool {
        try await membershipCount(for: reference) > 0
    }

    public func membershipCount(for reference: OfflineTrackReference) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDOfflineDownloadMembership.fetchRequest()
                request.predicate = NSPredicate(
                    format: "trackRatingKey == %@ AND trackSourceCompositeKey == %@",
                    reference.trackRatingKey,
                    reference.trackSourceCompositeKey
                )
                do {
                    let count = try context.count(for: request)
                    continuation.resume(returning: count)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolveTrack(reference: OfflineTrackReference, in context: NSManagedObjectContext) throws -> CDTrack? {
        let request = CDTrack.fetchRequest()
        request.predicate = NSPredicate(
            format: "ratingKey == %@ AND sourceCompositeKey == %@",
            reference.trackRatingKey,
            reference.trackSourceCompositeKey
        )
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    public func totalTrackDurationMs() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    // Get distinct track ratingKey+source pairs to avoid counting shared tracks multiple times
                    let membershipRequest = CDOfflineDownloadMembership.fetchRequest()
                    let memberships = try context.fetch(membershipRequest)

                    var seenTrackKeys = Set<String>()
                    var totalDuration: Int64 = 0

                    for membership in memberships {
                        let trackKey = "\(membership.trackSourceCompositeKey)|\(membership.trackRatingKey)"
                        guard !seenTrackKeys.contains(trackKey) else { continue }
                        seenTrackKeys.insert(trackKey)

                        // Look up the track's duration
                        if let track = membership.track {
                            totalDuration += track.duration
                        }
                    }

                    continuation.resume(returning: totalDuration)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func membershipID(targetKey: String, reference: OfflineTrackReference) -> String {
        "\(targetKey)|\(reference.trackSourceCompositeKey)|\(reference.trackRatingKey)"
    }
}
