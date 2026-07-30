import Foundation
import os.signpost

/// Metadata describing how a home hub snapshot was resolved.
public struct HomeHubSnapshotMetadata: Sendable {
    public let currentSourceKey: String?
    public let currentSourceName: String
    public let fetchTaskCount: Int
    public let usedGlobalFallback: Bool
    public let networkFetchCompletedAt: Date?
    public let cacheCreatedAt: Date?
    public let cacheFetchedAt: Date?
    public let freshnessState: HomeFeedSnapshotFreshnessState?
    public let refreshReason: String?

    public init(
        currentSourceKey: String?,
        currentSourceName: String,
        fetchTaskCount: Int,
        usedGlobalFallback: Bool,
        networkFetchCompletedAt: Date?,
        cacheCreatedAt: Date? = nil,
        cacheFetchedAt: Date? = nil,
        freshnessState: HomeFeedSnapshotFreshnessState? = nil,
        refreshReason: String? = nil
    ) {
        self.currentSourceKey = currentSourceKey
        self.currentSourceName = currentSourceName
        self.fetchTaskCount = fetchTaskCount
        self.usedGlobalFallback = usedGlobalFallback
        self.networkFetchCompletedAt = networkFetchCompletedAt
        self.cacheCreatedAt = cacheCreatedAt
        self.cacheFetchedAt = cacheFetchedAt
        self.freshnessState = freshnessState
        self.refreshReason = refreshReason
    }
}

/// Ordered home hubs plus the metadata needed by Feed to coordinate refresh behavior.
public struct HomeHubSnapshot: Sendable {
    public let orderedHubs: [Hub]
    public let failedHubKeys: Set<String>
    public let metadata: HomeHubSnapshotMetadata

    public init(
        orderedHubs: [Hub],
        failedHubKeys: Set<String>,
        metadata: HomeHubSnapshotMetadata
    ) {
        self.orderedHubs = orderedHubs
        self.failedHubKeys = failedHubKeys
        self.metadata = metadata
    }
}

/// Loads, merges, orders, and caches Feed hub data without depending on UI state.
public protocol HomeHubLoaderProtocol: Sendable {
    @MainActor func loadCachedSnapshot() async throws -> HomeHubSnapshot
    @MainActor func loadSnapshot(applySavedOrder: Bool, hubCount: String) async -> HomeHubSnapshot?
    @MainActor func clearFailedHubKeys()
}

public final class HomeHubLoader: HomeHubLoaderProtocol, @unchecked Sendable {
    private struct SourceContext {
        let sourceKey: String?
        let sourceName: String
    }

    private struct ProviderHubResult: Sendable {
        let sourceKey: String
        let hubs: [Hub]
        let failedAll: Bool
        let failedSemanticKinds: Set<HubSemanticKind>

        var hasFailure: Bool { failedAll || !failedSemanticKinds.isEmpty }
    }

    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubRepository: HubRepositoryProtocol
    private let hubOrderManager: HubOrderManager

    private static let failedHubKeysKey = "failedHubKeys"
    static let feedOrderKey = "plex:feed:global"

    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        hubRepository: HubRepositoryProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager()
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubRepository = hubRepository
        self.hubOrderManager = hubOrderManager
    }

    @MainActor
    public func loadCachedSnapshot() async throws -> HomeHubSnapshot {
        let cachedSnapshot = try await hubRepository.fetchLatestHomeFeedSnapshot(sourceScopeKey: nil)
        let cached: [Hub]
        if let cachedSnapshot {
            cached = cachedSnapshot.hubs
        } else {
            cached = try await hubRepository.fetchHubs()
        }
        let sourceConfiguration = accountManager.sourceConfigurationSnapshot
        let sourceContext = currentSourceContext()
        let filtered = sourceConfiguration.hasAnySources || !sourceConfiguration.isAuthoritative
            ? Self.filterHubsToEnabledSources(cached, sourceConfiguration: sourceConfiguration)
            : cached
        let merged = Self.mergeAndGroupHubs(filtered)

        EnsembleLogger.debug(
            "🏠 Hub loader cache \(merged.isEmpty ? "miss" : "hit") count=\(merged.count)"
        )

        let orderedHubs = orderedSnapshot(
            from: merged,
            sourceContext: sourceContext,
            applySavedOrder: true,
            persistDefaultOrder: false
        )

        return HomeHubSnapshot(
            orderedHubs: orderedHubs,
            failedHubKeys: failedHubKeys,
            metadata: HomeHubSnapshotMetadata(
                currentSourceKey: sourceContext.sourceKey,
                currentSourceName: sourceContext.sourceName,
                fetchTaskCount: 0,
                usedGlobalFallback: false,
                networkFetchCompletedAt: nil,
                cacheCreatedAt: cachedSnapshot?.createdAt,
                cacheFetchedAt: cachedSnapshot?.fetchedAt,
                freshnessState: cachedSnapshot?.freshnessState,
                refreshReason: cachedSnapshot?.refreshReason
            )
        )
    }

    @MainActor
    public func loadSnapshot(applySavedOrder: Bool, hubCount: String) async -> HomeHubSnapshot? {
        let signpostID = OSSignpostID(log: HomeHubLoaderSignposts.log)
        os_signpost(.begin, log: HomeHubLoaderSignposts.log, name: HomeHubLoaderSignposts.loadSnapshot, signpostID: signpostID)
        defer {
            os_signpost(.end, log: HomeHubLoaderSignposts.log, name: HomeHubLoaderSignposts.loadSnapshot, signpostID: signpostID)
        }

        let sourceContext = currentSourceContext()
        let providerWork: [(registration: ConfiguredSourceProvider, lease: SourcePersistenceLease)] =
            syncCoordinator.configuredSourceProviderRegistrations.compactMap { registration in
            let sourceKey = registration.provider.sourceIdentifier.compositeKey
            guard let lease = syncCoordinator.beginSourcePersistenceWork(
                sourceKey: sourceKey,
                revision: registration.revision
            ) else { return nil }
            return (registration: registration, lease: lease)
            }
        defer {
            providerWork.forEach { syncCoordinator.finishSourcePersistenceWork($0.lease) }
        }

        guard !providerWork.isEmpty else {
            EnsembleLogger.debug("🏠 Hub loader skipped network fetch (no enabled sources)")
            return nil
        }

        EnsembleLogger.debug("🏠 Hub loader network fetch tasks=\(providerWork.count) count=\(hubCount)")

        var collectedHubs: [Hub] = []
        var updatedFailedHubKeys = Set<String>()
        var failedResults: [ProviderHubResult] = []

        await withTaskGroup(of: (index: Int, result: ProviderHubResult).self) { group in
            for (index, work) in providerWork.enumerated() {
                group.addTask {
                    let result = await Self.fetchHubs(
                        provider: work.registration.provider,
                        limit: Int(hubCount) ?? 12
                    )
                    return (index, result)
                }
            }

            var results = Array<ProviderHubResult?>(
                repeating: nil,
                count: providerWork.count
            )
            for await result in group {
                results[result.index] = result.result
            }

            for (index, result) in results.enumerated() {
                guard let result else { continue }
                let work = providerWork[index]
                let sourceKey = work.registration.provider.sourceIdentifier.compositeKey
                guard syncCoordinator.isSourcePersistenceWorkCurrent(
                    sourceKey: sourceKey,
                    revision: work.registration.revision,
                    lease: work.lease
                ) else {
                    EnsembleLogger.debug("🏠 Hub loader discarded stale provider result source=\(sourceKey)")
                    continue
                }
                collectedHubs.append(contentsOf: result.hubs)
                if result.hasFailure {
                    updatedFailedHubKeys.insert(result.sourceKey)
                    failedResults.append(result)
                }
            }
        }

        if !updatedFailedHubKeys.isEmpty,
           let cachedSnapshot = try? await hubRepository.fetchLatestHomeFeedSnapshot(sourceScopeKey: nil) {
            collectedHubs.append(contentsOf: Self.hubs(
                cachedSnapshot.hubs,
                retaining: failedResults
            ))
        }

        var validSourceKeys = currentSourceKeys(for: providerWork)
        collectedHubs = Self.filterHubs(collectedHubs, toSourceKeys: validSourceKeys)
        updatedFailedHubKeys.formIntersection(validSourceKeys)
        failedResults.removeAll { !validSourceKeys.contains($0.sourceKey) }
        persistFailedHubKeys(updatedFailedHubKeys)

        let mergedHubs = Self.mergeAndGroupHubs(collectedHubs)
        EnsembleLogger.debug(
            "🏠 Hub loader merged result count=\(mergedHubs.count)"
        )

        var orderedHubs = orderedSnapshot(
            from: mergedHubs,
            sourceContext: sourceContext,
            applySavedOrder: applySavedOrder,
            persistDefaultOrder: true
        )

        validSourceKeys = currentSourceKeys(for: providerWork)
        orderedHubs = Self.filterHubs(orderedHubs, toSourceKeys: validSourceKeys)
        updatedFailedHubKeys.formIntersection(validSourceKeys)
        persistFailedHubKeys(updatedFailedHubKeys)

        if orderedHubs.isEmpty {
            EnsembleLogger.debug("🏠 Hub loader skipped empty cache save to preserve last usable Feed cache")
        } else {
            let freshnessState: HomeFeedSnapshotFreshnessState = updatedFailedHubKeys.isEmpty ? .fresh : .stale
            let cacheSnapshot = HomeFeedCachedSnapshot(
                sourceScopeKey: nil,
                sourceName: sourceContext.sourceName,
                fetchedAt: Date(),
                refreshReason: updatedFailedHubKeys.isEmpty ? "network" : "partial-network",
                freshnessState: freshnessState,
                isLastGood: true,
                hubs: orderedHubs
            )
            do {
                try await hubRepository.saveHomeFeedSnapshot(cacheSnapshot)
                EnsembleLogger.debug("🏠 Hub loader last-good snapshot save count=\(cacheSnapshot.hubs.count)")
            } catch {
                EnsembleLogger.debug("🏠 Hub loader last-good snapshot save failed: \(error.localizedDescription)")
            }
        }

        validSourceKeys = currentSourceKeys(for: providerWork)
        orderedHubs = Self.filterHubs(orderedHubs, toSourceKeys: validSourceKeys)
        updatedFailedHubKeys.formIntersection(validSourceKeys)
        persistFailedHubKeys(updatedFailedHubKeys)

        return HomeHubSnapshot(
            orderedHubs: orderedHubs,
            failedHubKeys: updatedFailedHubKeys,
            metadata: HomeHubSnapshotMetadata(
                currentSourceKey: sourceContext.sourceKey,
                currentSourceName: sourceContext.sourceName,
                fetchTaskCount: providerWork.count,
                usedGlobalFallback: false,
                networkFetchCompletedAt: Date(),
                cacheCreatedAt: nil,
                cacheFetchedAt: nil,
                freshnessState: updatedFailedHubKeys.isEmpty ? .fresh : .stale,
                refreshReason: updatedFailedHubKeys.isEmpty ? "network" : "partial-network"
            )
        )
    }

    @MainActor
    private func currentSourceKeys(
        for providerWork: [(registration: ConfiguredSourceProvider, lease: SourcePersistenceLease)]
    ) -> Set<String> {
        Set(providerWork.compactMap { work in
            let sourceKey = work.registration.provider.sourceIdentifier.compositeKey
            return syncCoordinator.isSourcePersistenceWorkCurrent(
                sourceKey: sourceKey,
                revision: work.registration.revision,
                lease: work.lease
            ) ? sourceKey : nil
        })
    }

    @MainActor
    public func clearFailedHubKeys() {
        UserDefaults.standard.removeObject(forKey: Self.failedHubKeysKey)
        EnsembleLogger.debug("🏠 Hub loader cleared failed hub keys")
    }

    static func removeFailedHubKey(forSourceCompositeKey sourceCompositeKey: String) {
        let defaults = UserDefaults.standard
        var keys = Set(defaults.stringArray(forKey: failedHubKeysKey) ?? [])
        guard keys.remove(sourceCompositeKey) != nil else { return }
        if keys.isEmpty {
            defaults.removeObject(forKey: failedHubKeysKey)
        } else {
            defaults.set(Array(keys), forKey: failedHubKeysKey)
        }
    }

    private var failedHubKeys: Set<String> {
        let saved = UserDefaults.standard.stringArray(forKey: Self.failedHubKeysKey) ?? []
        return Set(saved)
    }

    private func persistFailedHubKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: Self.failedHubKeysKey)
        if keys.isEmpty {
            EnsembleLogger.debug("🏠 Hub loader failed key cache empty")
        } else {
            EnsembleLogger.debug("🏠 Hub loader failed key cache count=\(keys.count)")
        }
    }

    @MainActor
    private func currentSourceContext() -> SourceContext {
        let servers = accountManager.plexAccounts.flatMap(\.servers)
        let hasMultipleServers = servers.count > 1

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let enabledLibraries = server.libraries.filter(\.isEnabled)
                if !enabledLibraries.isEmpty {
                    let sourceName = hasMultipleServers ? "Editing Music (on \(server.name))" : "Editing Music"
                    return SourceContext(
                        sourceKey: "plex:\(account.id):\(server.id)",
                        sourceName: sourceName
                    )
                }
            }
        }

        return SourceContext(sourceKey: nil, sourceName: "Editing Music")
    }

    private static func fetchHubs(
        provider: MusicSourceSyncProvider,
        limit: Int
    ) async -> ProviderHubResult {
        let sourceKey = provider.sourceIdentifier.compositeKey
        do {
            let result = try await provider.getHomeHubResult(limit: limit)
            return ProviderHubResult(
                sourceKey: sourceKey,
                hubs: result.hubs,
                failedAll: false,
                failedSemanticKinds: result.failedSemanticKinds
            )
        } catch {
            EnsembleLogger.debug(
                "🏠 Hub loader provider fetch failed source=\(sourceKey): \(error.localizedDescription)"
            )
            return ProviderHubResult(
                sourceKey: sourceKey,
                hubs: [],
                failedAll: true,
                failedSemanticKinds: []
            )
        }
    }

    private func orderedSnapshot(
        from hubs: [Hub],
        sourceContext: SourceContext,
        applySavedOrder: Bool,
        persistDefaultOrder: Bool
    ) -> [Hub] {
        guard !hubs.isEmpty else { return [] }

        if hubOrderManager.loadOrder(for: Self.feedOrderKey) == nil,
           let legacySourceKey = sourceContext.sourceKey,
           let legacyOrder = hubOrderManager.loadOrder(for: legacySourceKey) {
            hubOrderManager.saveOrder(legacyOrder, for: Self.feedOrderKey)
        }
        migrateHubOrderIfNeeded(for: Self.feedOrderKey, currentHubs: hubs)

        if persistDefaultOrder {
            hubOrderManager.saveDefaultOrder(hubs.map(\.id), for: Self.feedOrderKey)
        }

        return applySavedOrder
            ? hubOrderManager.applyOrder(to: hubs, for: Self.feedOrderKey)
            : hubOrderManager.applyDefaultOrder(to: hubs, for: Self.feedOrderKey)
    }

    private static func filterHubsToEnabledSources(
        _ hubs: [Hub],
        sourceConfiguration: SourceConfigurationSnapshot
    ) -> [Hub] {
        return hubs.compactMap { hub in
            let enabledItems = hub.items.filter {
                sourceConfiguration.shouldPreserveSourceKey($0.sourceCompositeKey)
            }
            guard !enabledItems.isEmpty else { return nil }
            return Hub(
                id: hub.id,
                title: hub.title,
                type: hub.type,
                items: enabledItems,
                context: hub.context,
                semanticKind: hub.semanticKind,
                sourceScope: hub.sourceScope
            )
        }
    }

    private static func filterHubs(_ hubs: [Hub], toSourceKeys sourceKeys: Set<String>) -> [Hub] {
        hubs.compactMap { hub in
            let currentItems = hub.items.filter { sourceKeys.contains($0.sourceCompositeKey) }
            guard !currentItems.isEmpty else { return nil }
            return Hub(
                id: hub.id,
                title: hub.title,
                type: hub.type,
                items: currentItems,
                context: hub.context,
                semanticKind: hub.semanticKind,
                sourceScope: hub.sourceScope
            )
        }
    }

    private static func hubs(_ hubs: [Hub], retaining failedResults: [ProviderHubResult]) -> [Hub] {
        hubs.compactMap { hub in
            let items = hub.items.filter { item in
                failedResults.contains { failure in
                    failure.sourceKey == item.sourceCompositeKey
                        && (failure.failedAll || failure.failedSemanticKinds.contains(hub.semanticKind))
                }
            }
            guard !items.isEmpty else { return nil }
            return Hub(
                id: hub.id,
                title: hub.title,
                type: hub.type,
                items: items,
                context: hub.context,
                semanticKind: hub.semanticKind,
                sourceScope: hub.sourceScope
            )
        }
    }

    private func migrateHubOrderIfNeeded(for sourceKey: String, currentHubs: [Hub]) {
        guard let savedOrder = hubOrderManager.loadOrder(for: sourceKey) else { return }

        let currentIdSet = Set(currentHubs.map(\.id))
        let hasStaleIds = savedOrder.contains { !currentIdSet.contains($0) }
        guard hasStaleIds else { return }

        var typeOnlyLookup: [String: [String]] = [:]
        for hub in currentHubs {
            typeOnlyLookup[Self.migrationKey(for: hub.semanticKind), default: []].append(hub.id)
        }

        var remapping: [String: String] = [:]
        for savedId in savedOrder where !currentIdSet.contains(savedId) {
            let legacyKind = HubSemanticKind.legacy(hubID: savedId, title: "")
            if let candidates = typeOnlyLookup[Self.migrationKey(for: legacyKind)], candidates.count == 1 {
                remapping[savedId] = candidates[0]
            }
        }

        guard !remapping.isEmpty else { return }
        hubOrderManager.migrateOrder(remapping: remapping, for: sourceKey)
    }

    private static func migrationKey(for kind: HubSemanticKind) -> String {
        String(kind.rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    static func mergeAndGroupHubs(_ hubs: [Hub]) -> [Hub] {
        var hubGroups: [String: [Hub]] = [:]
        var groupOrder: [String] = []

        for hub in hubs {
            let scopeKey: String
            if hub.semanticKind.mergesAcrossSources {
                scopeKey = "global"
            } else if let serverKey = hub.sourceScope.serverCompositeKey {
                scopeKey = serverKey
            } else if let sourceKey = hub.sourceScope.sourceCompositeKey {
                scopeKey = sourceKey
            } else {
                scopeKey = "unscoped:\(hub.id)"
            }
            let groupingKey = "\(scopeKey)|\(hub.semanticKind.rawValue)"
            if hubGroups[groupingKey] == nil {
                hubGroups[groupingKey] = []
                groupOrder.append(groupingKey)
            }
            hubGroups[groupingKey]?.append(hub)
        }

        var mergedResults: [Hub] = []
        for key in groupOrder {
            guard let group = hubGroups[key] else { continue }

            let firstHub = group[0]
            let semanticKind = firstHub.semanticKind
            let normalizedTitle = semanticKind.displayTitle(fallback: firstHub.title)
            let mergesAcrossSources = semanticKind.mergesAcrossSources

            if group.count == 1, (!mergesAcrossSources || firstHub.id.contains(":merged:")) {
                let sourceScope: HubSourceScope
                if firstHub.id.contains(":merged:"), mergesAcrossSources {
                    sourceScope = .global
                } else if firstHub.id.contains(":merged:"),
                          let serverKey = firstHub.sourceScope.serverCompositeKey {
                    sourceScope = .server(serverKey)
                } else {
                    sourceScope = firstHub.sourceScope
                }
                mergedResults.append(
                    Hub(
                        id: firstHub.id,
                        title: normalizedTitle,
                        type: firstHub.type,
                        items: firstHub.items,
                        context: firstHub.context,
                        semanticKind: semanticKind,
                        sourceScope: sourceScope
                    )
                )
                continue
            }

            var itemsByKey: [String: HubItem] = [:]

            for hub in group {
                for item in hub.items {
                    let itemKey = Self.mergedHubItemKey(item)
                    if let existing = itemsByKey[itemKey],
                       !Self.isHigherPriority(item, than: existing, semanticKind: semanticKind) {
                        continue
                    }
                    itemsByKey[itemKey] = item
                }
            }

            var allItems = Array(itemsByKey.values)
            allItems.sort { Self.isHigherPriority($0, than: $1, semanticKind: semanticKind) }

            let mergedScope: HubSourceScope
            if mergesAcrossSources {
                mergedScope = .global
            } else if let serverKey = firstHub.sourceScope.serverCompositeKey {
                mergedScope = .server(serverKey)
            } else {
                mergedScope = firstHub.sourceScope
            }

            let mergedHub = Hub(
                id: "\(mergesAcrossSources ? Self.feedOrderKey : mergedScope.serverCompositeKey ?? mergedScope.sourceCompositeKey ?? "unscoped"):merged:\(semanticKind.rawValue):\(normalizedTitle)",
                title: normalizedTitle,
                type: firstHub.type,
                items: Array(allItems.prefix(40)),
                context: firstHub.context,
                semanticKind: semanticKind,
                sourceScope: mergedScope
            )
            mergedResults.append(mergedHub)
        }

        return mergedResults
    }

    private static func isHigherPriority(
        _ lhs: HubItem,
        than rhs: HubItem,
        semanticKind: HubSemanticKind
    ) -> Bool {
        let leftViewCount = lhs.viewCount ?? 0
        let rightViewCount = rhs.viewCount ?? 0
        if semanticKind == .mostPlayed, leftViewCount != rightViewCount {
            return leftViewCount > rightViewCount
        }

        let usesLastViewedAt = semanticKind == .recentlyPlayed || semanticKind == .mostPlayed
        let leftDate = usesLastViewedAt ? lhs.lastViewedAt ?? .distantPast : lhs.dateAdded ?? .distantPast
        let rightDate = usesLastViewedAt ? rhs.lastViewedAt ?? .distantPast : rhs.dateAdded ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return "\(lhs.sourceCompositeKey):\(lhs.id)" < "\(rhs.sourceCompositeKey):\(rhs.id)"
    }

    private static func mergedHubItemKey(_ item: HubItem) -> String {
        guard let source = MediaSourceIdentity.parse(item.sourceCompositeKey) else {
            return "\(item.sourceCompositeKey):\(item.id)"
        }
        return "\(source.type):\(source.serverId):\(source.libraryId ?? ""):\(item.id)"
    }
}

private enum HomeHubLoaderSignposts {
    static let log = OSLog(subsystem: "com.videogorl.ensemble", category: "startup-performance")
    static let loadSnapshot: StaticString = "Home Feed Snapshot"
}
