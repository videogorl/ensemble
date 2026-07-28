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
        let sourceContext = currentSourceContext()
        let enabledSourceKeys = enabledSourceCompositeKeys()
        let cachedSnapshot = try await hubRepository.fetchLatestHomeFeedSnapshot(sourceScopeKey: nil)
        let cached: [Hub]
        if let cachedSnapshot {
            cached = cachedSnapshot.hubs
        } else {
            cached = try await hubRepository.fetchHubs()
        }
        let filtered = accountManager.isSourceConfigurationAuthoritative && accountManager.hasAnySources
            ? Self.filterHubsToEnabledSources(cached, enabledSourceCompositeKeys: enabledSourceKeys)
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
        let providers = syncCoordinator.configuredSourceProviders

        guard !providers.isEmpty else {
            EnsembleLogger.debug("🏠 Hub loader skipped network fetch (no enabled sources)")
            return nil
        }

        EnsembleLogger.debug("🏠 Hub loader network fetch tasks=\(providers.count) count=\(hubCount)")

        var collectedHubs: [Hub] = []
        var updatedFailedHubKeys = Set<String>()

        await withTaskGroup(of: (index: Int, hubs: [Hub], failedKeys: Set<String>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let result = await Self.fetchHubs(provider: provider, limit: Int(hubCount) ?? 12)
                    return (index, result.hubs, result.failedKeys)
                }
            }

            var results = Array<(hubs: [Hub], failedKeys: Set<String>)?>(
                repeating: nil,
                count: providers.count
            )
            for await result in group {
                results[result.index] = (result.hubs, result.failedKeys)
            }

            for result in results.compactMap({ $0 }) {
                collectedHubs.append(contentsOf: result.hubs)
                if !result.failedKeys.isEmpty {
                    updatedFailedHubKeys.formUnion(result.failedKeys)
                }
            }
        }

        persistFailedHubKeys(updatedFailedHubKeys)

        let mergedHubs = Self.mergeAndGroupHubs(collectedHubs)
        EnsembleLogger.debug(
            "🏠 Hub loader merged result count=\(mergedHubs.count)"
        )

        let orderedHubs = orderedSnapshot(
            from: mergedHubs,
            sourceContext: sourceContext,
            applySavedOrder: applySavedOrder,
            persistDefaultOrder: true
        )

        if orderedHubs.isEmpty {
            EnsembleLogger.debug("🏠 Hub loader skipped empty cache save to preserve last usable Feed cache")
        } else {
            let cacheSnapshot = HomeFeedCachedSnapshot(
                sourceScopeKey: nil,
                sourceName: sourceContext.sourceName,
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
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

        return HomeHubSnapshot(
            orderedHubs: orderedHubs,
            failedHubKeys: updatedFailedHubKeys,
            metadata: HomeHubSnapshotMetadata(
                currentSourceKey: sourceContext.sourceKey,
                currentSourceName: sourceContext.sourceName,
                fetchTaskCount: providers.count,
                usedGlobalFallback: false,
                networkFetchCompletedAt: Date(),
                cacheCreatedAt: nil,
                cacheFetchedAt: nil,
                freshnessState: .fresh,
                refreshReason: "network"
            )
        )
    }

    @MainActor
    public func clearFailedHubKeys() {
        UserDefaults.standard.removeObject(forKey: Self.failedHubKeysKey)
        EnsembleLogger.debug("🏠 Hub loader cleared failed hub keys")
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

    @MainActor
    private func enabledSourceCompositeKeys() -> Set<String> {
        Set(accountManager.enabledSources().map(\.compositeKey))
    }

    private static func fetchHubs(
        provider: MusicSourceSyncProvider,
        limit: Int
    ) async -> (hubs: [Hub], failedKeys: Set<String>) {
        do {
            return (try await provider.getHomeHubs(limit: limit), [])
        } catch {
            EnsembleLogger.debug(
                "🏠 Hub loader provider fetch failed source=\(provider.sourceIdentifier.compositeKey): \(error.localizedDescription)"
            )
            return ([], [provider.sourceIdentifier.compositeKey])
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
        enabledSourceCompositeKeys: Set<String>
    ) -> [Hub] {
        guard !enabledSourceCompositeKeys.isEmpty else { return [] }
        return hubs.compactMap { hub in
            let enabledItems = hub.items.filter { enabledSourceCompositeKeys.contains($0.sourceCompositeKey) }
            guard !enabledItems.isEmpty else { return nil }
            return Hub(id: hub.id, title: hub.title, type: hub.type, items: enabledItems, context: hub.context)
        }
    }

    private static func normalizeHubTitle(_ title: String) -> String {
        let stripPrefixes = ["Recently Added", "Recently Played", "Most Played"]
        for prefix in stripPrefixes {
            if title.hasPrefix(prefix), let range = title.range(of: " in ", options: .backwards) {
                return String(title[..<range.lowerBound])
            }
        }
        return title
    }

    private static func hubTypeIdentifier(from hubId: String) -> String {
        let components = hubId.split(separator: ":")
        if components.count >= 5 {
            let hubIdentifier = components[4...].joined(separator: ":")
            if let lastDot = hubIdentifier.lastIndex(of: ".") {
                let suffix = hubIdentifier[hubIdentifier.index(after: lastDot)...]
                if suffix.allSatisfy(\.isNumber) {
                    return String(hubIdentifier[..<lastDot])
                }
            }
            return hubIdentifier
        }
        return hubId
    }

    private static func mergesAcrossServers(_ hubType: String) -> Bool {
        hubType == "music.recent.added"
            || hubType == "music.recent.played"
            || hubType == "music.popular"
    }

    private static func rawHubType(from hubId: String) -> String {
        let components = hubId.split(separator: ":")
        guard components.count >= 5 else { return hubId }

        if components[3] == "merged" {
            return String(components[4])
        }

        return hubTypeIdentifier(from: hubId)
    }

    private func migrateHubOrderIfNeeded(for sourceKey: String, currentHubs: [Hub]) {
        guard let savedOrder = hubOrderManager.loadOrder(for: sourceKey) else { return }

        let currentIdSet = Set(currentHubs.map(\.id))
        let hasStaleIds = savedOrder.contains { !currentIdSet.contains($0) }
        guard hasStaleIds else { return }

        var typeAndTitleLookup: [String: String] = [:]
        var typeOnlyLookup: [String: [String]] = [:]
        for hub in currentHubs {
            let rawType = Self.rawHubType(from: hub.id)
            let title = Self.normalizeHubTitle(hub.title)
            typeAndTitleLookup["\(rawType)|\(title)"] = hub.id
            typeOnlyLookup[rawType, default: []].append(hub.id)
        }

        var remapping: [String: String] = [:]
        for savedId in savedOrder where !currentIdSet.contains(savedId) {
            let rawType = Self.rawHubType(from: savedId)

            let components = savedId.split(separator: ":")
            if components.count >= 6, components[3] == "merged" {
                let titleFromId = components[5...].joined(separator: ":")
                let key = "\(rawType)|\(titleFromId)"
                if let currentId = typeAndTitleLookup[key] {
                    remapping[savedId] = currentId
                    continue
                }
            }

            if let candidates = typeOnlyLookup[rawType], candidates.count == 1 {
                remapping[savedId] = candidates[0]
            }
        }

        guard !remapping.isEmpty else { return }
        hubOrderManager.migrateOrder(remapping: remapping, for: sourceKey)
    }

    static func mergeAndGroupHubs(_ hubs: [Hub]) -> [Hub] {
        func serverKey(_ hubId: String) -> String {
            MediaSourceIdentity.serverSourceKey(from: hubId) ?? "global"
        }

        var hubGroups: [String: [Hub]] = [:]
        var groupOrder: [String] = []

        for hub in hubs {
            let hubType = Self.hubTypeIdentifier(from: hub.id)
            let groupingKey = "\(Self.mergesAcrossServers(hubType) ? "global" : serverKey(hub.id))|\(hubType)|\(Self.normalizeHubTitle(hub.title))"
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
            let normalizedTitle = Self.normalizeHubTitle(firstHub.title)
            let hubType = Self.hubTypeIdentifier(from: firstHub.id)
            let mergesAcrossServers = Self.mergesAcrossServers(hubType)

            if group.count == 1, (!mergesAcrossServers || firstHub.id.contains(":merged:")) {
                mergedResults.append(
                    Hub(
                        id: firstHub.id,
                        title: normalizedTitle,
                        type: firstHub.type,
                        items: firstHub.items,
                        context: firstHub.context
                    )
                )
                continue
            }

            var itemsByKey: [String: HubItem] = [:]

            for hub in group {
                for item in hub.items {
                    let itemKey = Self.mergedHubItemKey(item)
                    if let existing = itemsByKey[itemKey],
                       !Self.isHigherPriority(item, than: existing, hubType: hubType) {
                        continue
                    }
                    itemsByKey[itemKey] = item
                }
            }

            var allItems = Array(itemsByKey.values)
            allItems.sort { Self.isHigherPriority($0, than: $1, hubType: hubType) }

            let mergedHub = Hub(
                id: "\(mergesAcrossServers ? Self.feedOrderKey : serverKey(firstHub.id)):merged:\(hubType):\(normalizedTitle)",
                title: normalizedTitle,
                type: firstHub.type,
                items: Array(allItems.prefix(40)),
                context: firstHub.context
            )
            mergedResults.append(mergedHub)
        }

        return mergedResults
    }

    private static func isHigherPriority(_ lhs: HubItem, than rhs: HubItem, hubType: String) -> Bool {
        let leftViewCount = lhs.viewCount ?? 0
        let rightViewCount = rhs.viewCount ?? 0
        if hubType == "music.popular", leftViewCount != rightViewCount {
            return leftViewCount > rightViewCount
        }

        let usesLastViewedAt = hubType == "music.recent.played" || hubType == "music.popular"
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
