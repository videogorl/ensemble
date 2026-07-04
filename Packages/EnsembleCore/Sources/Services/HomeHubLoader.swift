import EnsembleAPI
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

    private struct FetchTask {
        let sourceKey: String
        let client: PlexAPIClient
        let sectionKey: String
    }

    private let accountManager: AccountManager
    private let hubRepository: HubRepositoryProtocol
    private let hubOrderManager: HubOrderManager

    private static let failedHubKeysKey = "failedHubKeys"

    public init(
        accountManager: AccountManager,
        hubRepository: HubRepositoryProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager()
    ) {
        self.accountManager = accountManager
        self.hubRepository = hubRepository
        self.hubOrderManager = hubOrderManager
    }

    @MainActor
    public func loadCachedSnapshot() async throws -> HomeHubSnapshot {
        let sourceContext = currentSourceContext()
        let enabledSourceKeys = enabledSourceCompositeKeys()
        let cachedSnapshot = try await hubRepository.fetchLatestHomeFeedSnapshot(sourceScopeKey: sourceContext.sourceKey)
        let cached: [Hub]
        if let cachedSnapshot {
            cached = cachedSnapshot.hubs
        } else {
            cached = try await hubRepository.fetchHubs()
        }
        let filtered = Self.filterHubsToEnabledSources(
            cached,
            enabledSourceCompositeKeys: enabledSourceKeys
        )

        EnsembleLogger.debug(
            "🏠 Hub loader cache \(filtered.isEmpty ? "miss" : "hit") count=\(filtered.count)"
        )

        let orderedHubs = orderedSnapshot(
            from: filtered,
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
        let fetchTasks = makeFetchTasks()

        guard !fetchTasks.isEmpty else {
            EnsembleLogger.debug("🏠 Hub loader skipped network fetch (no enabled libraries)")
            return nil
        }

        EnsembleLogger.debug("🏠 Hub loader network fetch tasks=\(fetchTasks.count) count=\(hubCount)")

        var collectedHubs: [Hub] = []
        var updatedFailedHubKeys = failedHubKeys

        await withTaskGroup(of: (hubs: [Hub], failedKeys: Set<String>).self) { group in
            for task in fetchTasks {
                group.addTask {
                    await Self.fetchSectionHubs(
                        task: task,
                        hubCount: hubCount
                    )
                }
            }

            for await result in group {
                collectedHubs.append(contentsOf: result.hubs)
                if !result.failedKeys.isEmpty {
                    updatedFailedHubKeys.formUnion(result.failedKeys)
                }
            }
        }

        persistFailedHubKeys(updatedFailedHubKeys)

        let usedGlobalFallback = collectedHubs.count < 3
        let finalHubs: [Hub]
        if usedGlobalFallback {
            finalHubs = await collectedHubs + fetchGlobalFallbackHubs(from: fetchTasks)
        } else {
            finalHubs = collectedHubs
        }

        let mergedHubs = mergeAndGroupHubs(finalHubs)
        EnsembleLogger.debug(
            "🏠 Hub loader merged result count=\(mergedHubs.count) fallback=\(usedGlobalFallback)"
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
                sourceScopeKey: sourceContext.sourceKey,
                sourceName: sourceContext.sourceName,
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: orderedHubs
            )
            Task.detached(priority: .background) { [hubRepository] in
                do {
                    try await hubRepository.saveHomeFeedSnapshot(cacheSnapshot)
                    EnsembleLogger.debug("🏠 Hub loader last-good snapshot save count=\(cacheSnapshot.hubs.count)")
                } catch {
                    EnsembleLogger.debug("🏠 Hub loader last-good snapshot save failed: \(error.localizedDescription)")
                }
            }
        }

        return HomeHubSnapshot(
            orderedHubs: orderedHubs,
            failedHubKeys: updatedFailedHubKeys,
            metadata: HomeHubSnapshotMetadata(
                currentSourceKey: sourceContext.sourceKey,
                currentSourceName: sourceContext.sourceName,
                fetchTaskCount: fetchTasks.count,
                usedGlobalFallback: usedGlobalFallback,
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
    private func makeFetchTasks() -> [FetchTask] {
        var tasks: [FetchTask] = []

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                for library in server.libraries where library.isEnabled {
                    tasks.append(
                        FetchTask(
                            sourceKey: "plex:\(account.id):\(server.id):\(library.key)",
                            client: client,
                            sectionKey: library.key
                        )
                    )
                }
            }
        }

        return tasks
    }

    @MainActor
    private func enabledSourceCompositeKeys() -> Set<String> {
        var keys = Set<String>()
        for account in accountManager.plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    keys.insert("plex:\(account.id):\(server.id):\(library.key)")
                }
            }
        }
        return keys
    }

    private static func fetchSectionHubs(
        task: FetchTask,
        hubCount: String
    ) async -> (hubs: [Hub], failedKeys: Set<String>) {
        var hubs: [Hub] = []
        var newFailedKeys = Set<String>()

        do {
            let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey, count: hubCount)

            await withTaskGroup(of: (hub: Hub?, failedKey: String?).self) { group in
                for plexHub in plexHubs {
                    group.addTask {
                        let hubId = "\(task.sourceKey):\(plexHub.id)"
                        var hubItems: [HubItem] = []

                        if let metadata = plexHub.metadata, !metadata.isEmpty {
                            let filteredMetadata = metadata.filter { item in
                                let type = item.type?.lowercased() ?? ""
                                return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                            }
                            hubItems = Array(filteredMetadata.prefix(12)).map {
                                HubItem(from: $0, sourceKey: task.sourceKey)
                            }
                        }

                        guard !hubItems.isEmpty else { return (hub: nil, failedKey: nil) }

                        return (
                            hub: Hub(
                                id: hubId,
                                title: plexHub.title,
                                type: plexHub.type ?? "mixed",
                                items: hubItems,
                                context: plexHub.context
                            ),
                            failedKey: nil
                        )
                    }
                }

                for await result in group {
                    if let hub = result.hub {
                        hubs.append(hub)
                    }
                    if let failedKey = result.failedKey {
                        newFailedKeys.insert(failedKey)
                    }
                }
            }
        } catch {
            EnsembleLogger.debug(
                "🏠 Hub loader section fetch failed source=\(task.sourceKey) section=\(task.sectionKey): \(error.localizedDescription)"
            )
        }

        return (hubs, newFailedKeys)
    }

    private func fetchGlobalFallbackHubs(from fetchTasks: [FetchTask]) async -> [Hub] {
        var handledServers = Set<String>()
        var serverTasks: [(sourceKey: String, client: PlexAPIClient)] = []

        for task in fetchTasks {
            guard let serverKey = MediaSourceIdentity.serverSourceKey(from: task.sourceKey) else { continue }
            if handledServers.insert(serverKey).inserted {
                serverTasks.append((task.sourceKey, task.client))
            }
        }

        return await withTaskGroup(of: [Hub].self) { group in
            var collected: [Hub] = []

            for task in serverTasks {
                group.addTask {
                    var hubs: [Hub] = []
                    do {
                        let globalHubs = try await task.client.getGlobalHubs()
                        for plexHub in globalHubs {
                            let hubType = plexHub.type?.lowercased() ?? ""
                            let isMusic = hubType.contains("artist")
                                || hubType.contains("album")
                                || hubType.contains("track")
                                || hubType.contains("playlist")
                                || hubType.contains("music")
                            guard isMusic else { continue }

                            let hubId = "\(task.sourceKey):global:\(plexHub.id)"
                            var hubItems: [HubItem] = []

                            if let metadata = plexHub.metadata, !metadata.isEmpty {
                                let filteredMetadata = metadata.filter { item in
                                    let type = item.type?.lowercased() ?? ""
                                    return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                                }
                                hubItems = Array(filteredMetadata.prefix(12)).map {
                                    HubItem(from: $0, sourceKey: task.sourceKey)
                                }
                            }

                            if !hubItems.isEmpty {
                                hubs.append(
                                    Hub(
                                        id: hubId,
                                        title: plexHub.title,
                                        type: plexHub.type ?? "mixed",
                                        items: hubItems,
                                        context: plexHub.context
                                    )
                                )
                            }
                        }
                    } catch {
                        EnsembleLogger.debug(
                            "🏠 Hub loader global fallback failed source=\(task.sourceKey): \(error.localizedDescription)"
                        )
                    }
                    return hubs
                }
            }

            for await hubs in group {
                collected.append(contentsOf: hubs)
            }

            return collected
        }
    }

    private func orderedSnapshot(
        from hubs: [Hub],
        sourceContext: SourceContext,
        applySavedOrder: Bool,
        persistDefaultOrder: Bool
    ) -> [Hub] {
        guard !hubs.isEmpty else { return [] }

        if let sourceKey = sourceContext.sourceKey, persistDefaultOrder {
            let defaultHubs = hubOrderManager.hubs(for: sourceKey, in: hubs)
            hubOrderManager.saveDefaultOrder(defaultHubs.map(\.id), for: sourceKey)
            migrateHubOrderIfNeeded(for: sourceKey, currentHubs: defaultHubs)
        }

        guard let sourceKey = sourceContext.sourceKey else { return hubs }

        let serverHubs = hubOrderManager.hubs(for: sourceKey, in: hubs)
        let orderedServerHubs = applySavedOrder
            ? hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
            : hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)

        return hubOrderManager.replacingHubs(
            for: sourceKey,
            in: hubs,
            with: orderedServerHubs
        )
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

    private func mergeAndGroupHubs(_ hubs: [Hub]) -> [Hub] {
        func serverKey(_ hubId: String) -> String {
            MediaSourceIdentity.serverSourceKey(from: hubId) ?? "global"
        }

        var hubGroups: [String: [Hub]] = [:]
        var groupOrder: [String] = []

        for hub in hubs {
            let groupingKey = "\(serverKey(hub.id))|\(Self.hubTypeIdentifier(from: hub.id))|\(Self.normalizeHubTitle(hub.title))"
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

            if group.count == 1 {
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

            var allItems: [HubItem] = []
            var seenItems = Set<String>()

            for hub in group {
                for item in hub.items {
                    let itemKey = "\(item.id):\(item.sourceCompositeKey)"
                    if seenItems.insert(itemKey).inserted {
                        allItems.append(item)
                    }
                }
            }

            allItems.sort { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }

            let mergedHub = Hub(
                id: "\(serverKey(firstHub.id)):merged:\(Self.hubTypeIdentifier(from: firstHub.id)):\(normalizedTitle)",
                title: normalizedTitle,
                type: firstHub.type,
                items: Array(allItems.prefix(40)),
                context: firstHub.context
            )
            mergedResults.append(mergedHub)
        }

        return mergedResults
    }
}

private enum HomeHubLoaderSignposts {
    static let log = OSLog(subsystem: "com.videogorl.ensemble", category: "startup-performance")
    static let loadSnapshot: StaticString = "Home Feed Snapshot"
}
