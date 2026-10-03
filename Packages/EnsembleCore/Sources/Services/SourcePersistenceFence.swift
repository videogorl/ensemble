import Foundation

struct SourceProviderRevision: Equatable, Sendable {
    let sourceConfiguration: UInt64
    let providerRegistration: UInt64
}

struct ConfiguredSourceProvider: Sendable {
    let provider: MusicSourceSyncProvider
    let revision: SourceProviderRevision
}

struct SourcePersistenceLease: Hashable, Sendable {
    let sourceKey: String
    fileprivate let id: UUID
}

/// Opaque access to the shared source fence for persistence work that lives
/// outside sync execution, such as detached durable artwork writes.
struct SourcePersistenceWorkHandle: Sendable {
    let leases: [SourcePersistenceLease]
}

/// Keeps source cleanup ordered after every provider write that was already in flight.
/// A cleanup fence also rejects new work until its final purge completes.
@MainActor
final class SourcePersistenceFence {
    private var activeLeaseIDs: [String: Set<UUID>] = [:]
    private var cleanupDepth: [String: Int] = [:]
    private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(sourceKey: String) -> SourcePersistenceLease? {
        let scopeKeys = persistenceScopeKeys(for: sourceKey)
        guard scopeKeys.allSatisfy({ cleanupDepth[$0] == nil }) else { return nil }
        let lease = SourcePersistenceLease(sourceKey: sourceKey, id: UUID())
        for scopeKey in scopeKeys {
            activeLeaseIDs[scopeKey, default: []].insert(lease.id)
        }
        return lease
    }

    func isCurrent(_ lease: SourcePersistenceLease) -> Bool {
        persistenceScopeKeys(for: lease.sourceKey).allSatisfy {
            cleanupDepth[$0] == nil && activeLeaseIDs[$0]?.contains(lease.id) == true
        }
    }

    func finish(_ lease: SourcePersistenceLease) {
        for scopeKey in persistenceScopeKeys(for: lease.sourceKey) {
            activeLeaseIDs[scopeKey]?.remove(lease.id)
            guard activeLeaseIDs[scopeKey]?.isEmpty != false else { continue }
            activeLeaseIDs.removeValue(forKey: scopeKey)
            let waiters = idleWaiters.removeValue(forKey: scopeKey) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func beginCleanup(sourceKey: String) async {
        await beginCleanup(sourceKeys: [sourceKey])
    }

    func beginCleanup(sourceKeys: Set<String>) async {
        let orderedKeys = sourceKeys.sorted()
        for sourceKey in orderedKeys {
            cleanupDepth[sourceKey, default: 0] += 1
        }
        for sourceKey in orderedKeys where activeLeaseIDs[sourceKey]?.isEmpty == false {
            await withCheckedContinuation { continuation in
                idleWaiters[sourceKey, default: []].append(continuation)
            }
        }
    }

    func finishCleanup(sourceKey: String) {
        finishCleanup(sourceKeys: [sourceKey])
    }

    func finishCleanup(sourceKeys: Set<String>) {
        for sourceKey in sourceKeys {
            finishSingleCleanup(sourceKey: sourceKey)
        }
    }

    private func finishSingleCleanup(sourceKey: String) {
        guard let depth = cleanupDepth[sourceKey] else { return }
        if depth > 1 {
            cleanupDepth[sourceKey] = depth - 1
        } else {
            cleanupDepth.removeValue(forKey: sourceKey)
        }
    }

    private func persistenceScopeKeys(for sourceKey: String) -> Set<String> {
        guard let identity = MediaSourceIdentity.parse(sourceKey),
              !identity.isServerScoped,
              identity.sourceType.capabilities.playlistsAreServerScoped else {
            return [sourceKey]
        }
        return [sourceKey, identity.serverSourceKey]
    }
}
