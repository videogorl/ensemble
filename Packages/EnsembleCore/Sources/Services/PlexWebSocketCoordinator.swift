import Combine
import EnsembleAPI
import Foundation

struct PlexLibraryChange: Hashable, Sendable {
    enum Kind: Int, Sendable {
        case artist = 8
        case album = 9
        case track = 10
    }

    let ratingKey: String
    let kind: Kind
    let state: Int

    var isDeletion: Bool { state == 9 }
}

/// Coordinates WebSocket connections to all active Plex servers.
///
/// Creates/destroys `PlexWebSocketManager` instances per connected server and routes
/// incoming events to the appropriate subsystems:
/// - Library updates trigger incremental sync
/// - Server shutdown/disconnect triggers health check
/// - Connection health signals reset health check TTL
///
/// Lifecycle: start on foreground, stop on background.
@MainActor
public final class PlexWebSocketCoordinator: ObservableObject {
    /// Published so UI can show real-time connection status if desired.
    @Published public private(set) var connectedServerKeys: Set<String> = []

    /// Per-server library scan progress (0-100). Key is serverKey (accountId:serverId).
    /// Populated on scan "started"/"updated" activity events, cleared on "ended".
    @Published public private(set) var serverScanProgress: [String: Int] = [:]

    private let accountManager: AccountManager
    private let networkMonitor: NetworkMonitor
    private let clientIdentifier: String

    /// Called when a library update notification arrives.
    /// SyncCoordinator wires this to trigger incremental sync for the affected section.
    var onLibraryUpdate: ((String, String, Set<PlexLibraryChange>) async -> Void)?

    /// Called when a playlist update notification arrives. Parameter: serverKey (accountId:serverId).
    /// SyncCoordinator wires this to trigger playlist-only sync for the affected server.
    public var onPlaylistUpdate: ((String) async -> Void)?

    /// Called when a server goes offline (WebSocket disconnect or shutdown notification).
    /// Parameter: serverKey (accountId:serverId).
    public var onServerOffline: ((String) async -> Void)?

    /// Called when any message arrives from a server (implicit health signal).
    /// Parameter: serverKey (accountId:serverId).
    public var onServerHealthy: ((String) async -> Void)?

    /// Called when album/artist artwork may have changed on the server.
    /// Parameters: (ratingKey: String, artworkType: "album" | "artist").
    public var onArtworkInvalidation: ((String, String) async -> Void)?

    /// Called when PMS download queue activity completes (media.download ended).
    /// Used by OfflineDownloadService to restart its queue when PMS finishes preparing downloads.
    public var onDownloadQueueCompleted: (() async -> Void)?
    /// Called when the aggregate WebSocket availability changes.
    /// True means at least one server currently has an active WebSocket manager.
    public var onConnectionAvailabilityChanged: ((Bool) async -> Void)?

    private final class ConnectionSlot {
        let accountId: String
        let serverId: String
        let client: PlexAPIClient
        var observationTask: Task<Void, Never>?
        var manager: PlexWebSocketManager?
        var eventTask: Task<Void, Never>?
        var revision: UInt64?
        var routingGeneration: UInt64?
        var url: String?

        init(accountId: String, serverId: String, client: PlexAPIClient) {
            self.accountId = accountId
            self.serverId = serverId
            self.client = client
        }
    }

    private var slots: [String: ConnectionSlot] = [:]
    private var accountObserver: AnyCancellable?
    private var networkObserver: AnyCancellable?
    private var isActive = false

    // Debounce library/playlist update triggers to avoid spamming sync for batch updates
    private let pendingLibraryUpdates = DebouncedTaskRegistry<String>()
    private var pendingLibraryChanges: [String: Set<PlexLibraryChange>] = [:]
    private let pendingPlaylistUpdates = DebouncedTaskRegistry<String>()
    private let pendingDownloadCompletions = DebouncedTaskRegistry<String>()
    private let libraryUpdateDebounce: TimeInterval = 3.0
    private let playlistUpdateDebounce: TimeInterval = 5.0
    private let downloadCompletionDebounce: TimeInterval = 3.0
    private let recentLibrarySyncCooldown: TimeInterval = 10.0
    private var activeLibrarySyncs: Set<String> = []
    private var lastLibrarySyncCompletion: [String: Date] = [:]

    // Debounce settings-changed events per server to coalesce rapid bursts
    private let pendingSettingsUpdates = DebouncedTaskRegistry<String>()
    private let settingsUpdateDebounce: TimeInterval = 5.0

    public init(
        accountManager: AccountManager,
        networkMonitor: NetworkMonitor,
        clientIdentifier: String
    ) {
        self.accountManager = accountManager
        self.networkMonitor = networkMonitor
        self.clientIdentifier = clientIdentifier
    }

    // MARK: - Lifecycle

    /// Start WebSocket connections to all active servers. Call on foreground.
    public func start() {
        guard !isActive else { return }
        isActive = true

        EnsembleLogger.debug("🔌 WebSocketCoordinator: Starting — accounts=\(accountManager.plexAccounts.count)")

        subscribeToNetworkChanges()

        if networkMonitor.networkState != .offline {
            refreshConnections()
        } else {
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Delaying start — network is \(networkMonitor.networkState.description)")
            applyConnectedState(Set())
        }

        // Observe account changes to add/remove connections
        accountObserver = accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshConnections()
            }
    }

    /// Stop all WebSocket connections. Call on background.
    public func stop() {
        guard isActive else { return }
        isActive = false

        EnsembleLogger.debug("🔌 WebSocketCoordinator: Stopping")

        accountObserver?.cancel()
        accountObserver = nil
        networkObserver?.cancel()
        networkObserver = nil
        for key in Array(slots.keys) {
            removeSlot(for: key)
        }
        applyConnectedState(Set())

        // Cancel pending debounced updates
        pendingLibraryUpdates.cancelAll()
        pendingLibraryChanges.removeAll()
        activeLibrarySyncs.removeAll()
        lastLibrarySyncCompletion.removeAll()
        pendingPlaylistUpdates.cancelAll()
        pendingDownloadCompletions.cancelAll()
        pendingSettingsUpdates.cancelAll()
    }

    // MARK: - Connection Management

    /// Sync WebSocket managers with current account/server configuration.
    private func refreshConnections() {
        guard isActive else { return }
        guard networkMonitor.networkState != .offline else {
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Skipping refresh — network is \(networkMonitor.networkState.description)")
            disconnectManagersForOffline()
            return
        }

        var activeKeys = Set<String>()

        for account in accountManager.plexAccounts {
            for server in account.servers {
                // Only connect to servers that have at least one enabled library
                let hasEnabledLibrary = server.libraries.contains { $0.isEnabled }
                guard hasEnabledLibrary else { continue }

                let serverKey = "\(account.id):\(server.id)"
                activeKeys.insert(serverKey)

                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else { continue }
                if slots[serverKey]?.client.instanceID == client.instanceID { continue }
                removeSlot(for: serverKey)

                let slot = ConnectionSlot(accountId: account.id, serverId: server.id, client: client)
                slots[serverKey] = slot
                slot.observationTask = Task { [weak self, weak slot] in
                    let stream = await client.connectionSnapshots()
                    guard let self, let slot, self.isCurrentSlot(slot, for: serverKey) else { return }
                    for await snapshot in stream {
                        guard self.isCurrentSlot(slot, for: serverKey) else { break }
                        await self.updateManager(for: slot, serverKey: serverKey, snapshot: snapshot)
                    }
                }
            }
        }

        // Remove managers for servers that are no longer active
        let staleKeys = Set(slots.keys).subtracting(activeKeys)
        for key in staleKeys {
            removeSlot(for: key)
        }
    }

    private func updateManager(for slot: ConnectionSlot, serverKey: String, snapshot: PlexConnectionSnapshot) async {
        if snapshot.availability == .retired {
            removeSlot(for: serverKey)
            return
        }
        if slot.revision != snapshot.revision || slot.routingGeneration != snapshot.routingGeneration
            || slot.url != snapshot.endpoint?.url || snapshot.availability == .unavailable {
            stopManager(in: slot, for: serverKey)
        }
        guard snapshot.availability != .unavailable else { return }

        let connection: PlexServerConnection
        do {
            connection = try await slot.client.getServerConnection(expectedRevision: snapshot.revision)
        } catch {
            return
        }
        guard isCurrentSlot(slot, for: serverKey),
              connection.revision == snapshot.revision,
              connection.routingGeneration == snapshot.routingGeneration,
              !connection.isDeviceOffline,
              let url = snapshot.endpoint?.url else { return }
        if slot.manager != nil, slot.revision == connection.revision,
           slot.routingGeneration == connection.routingGeneration, slot.url == url { return }

        stopManager(in: slot, for: serverKey)
        let manager = PlexWebSocketManager(
            serverURL: url,
            token: connection.token,
            serverName: connection.name,
            clientIdentifier: clientIdentifier
        )
        slot.manager = manager
        slot.revision = connection.revision
        slot.routingGeneration = connection.routingGeneration
        slot.url = url
        slot.eventTask = Task { [weak self, weak slot] in
            let stream = await manager.events()
            guard let self, let slot,
                  await self.isCurrentManager(manager, in: slot, for: serverKey, connection: connection, url: url) else { return }
            await manager.start()
            guard await self.isCurrentManager(manager, in: slot, for: serverKey, connection: connection, url: url) else {
                await manager.stop()
                return
            }
            self.applyConnectedState(self.connectedServerKeys.union([serverKey]))

            for await event in stream {
                guard await self.isCurrentManager(manager, in: slot, for: serverKey, connection: connection, url: url) else { break }
                if case .connectionHealthy = event {
                    await slot.client.recordServerActivity(
                        expectedRevision: connection.revision,
                        expectedRoutingGeneration: connection.routingGeneration
                    )
                    guard await self.isCurrentManager(manager, in: slot, for: serverKey, connection: connection, url: url) else { break }
                }
                await self.handleEvent(event, from: serverKey) {
                    await self.isCurrentManager(manager, in: slot, for: serverKey, connection: connection, url: url)
                }
            }
        }
    }

    private func isCurrentSlot(_ slot: ConnectionSlot, for serverKey: String) -> Bool {
        guard isActive, !Task.isCancelled, slots[serverKey] === slot,
              let account = accountManager.plexAccounts.first(where: { $0.id == slot.accountId }),
              let server = account.servers.first(where: { $0.id == slot.serverId }),
              server.libraries.contains(where: \.isEnabled) else { return false }
        return accountManager.makeAPIClient(accountId: slot.accountId, serverId: slot.serverId)?.instanceID == slot.client.instanceID
    }

    private func isCurrentManager(
        _ manager: PlexWebSocketManager,
        in slot: ConnectionSlot,
        for serverKey: String,
        connection: PlexServerConnection,
        url: String
    ) async -> Bool {
        guard isCurrentSlot(slot, for: serverKey), slot.manager === manager else { return false }
        let snapshot = await slot.client.currentConnectionSnapshot()
        return isCurrentSlot(slot, for: serverKey) && slot.manager === manager
            && snapshot.revision == connection.revision
            && snapshot.routingGeneration == connection.routingGeneration
            && snapshot.endpoint?.url == url
            && snapshot.availability != .retired && snapshot.availability != .unavailable
    }

    private func stopManager(in slot: ConnectionSlot, for serverKey: String) {
        slot.eventTask?.cancel()
        slot.eventTask = nil
        if let manager = slot.manager {
            Task { await manager.stop() }
        }
        slot.manager = nil
        slot.revision = nil
        slot.routingGeneration = nil
        slot.url = nil
        applyConnectedState(connectedServerKeys.subtracting([serverKey]))
    }

    private func removeSlot(for serverKey: String) {
        if let slot = slots.removeValue(forKey: serverKey) {
            slot.observationTask?.cancel()
            stopManager(in: slot, for: serverKey)
        }
        pendingLibraryUpdates.cancel { $0.hasPrefix("\(serverKey):") }
        pendingLibraryChanges = pendingLibraryChanges.filter { !$0.key.hasPrefix("\(serverKey):") }
        activeLibrarySyncs = activeLibrarySyncs.filter { !$0.hasPrefix("\(serverKey):") }
        lastLibrarySyncCompletion = lastLibrarySyncCompletion.filter { !$0.key.hasPrefix("\(serverKey):") }
        pendingPlaylistUpdates.cancel(key: serverKey)
        pendingDownloadCompletions.cancel(key: serverKey)
        pendingSettingsUpdates.cancel(key: serverKey)
        serverScanProgress.removeValue(forKey: serverKey)
    }

    private func disconnectManagersForOffline() {
        guard !slots.isEmpty || !connectedServerKeys.isEmpty else { return }

        EnsembleLogger.debug("🔌 WebSocketCoordinator: Disconnecting managers while network is \(networkMonitor.networkState.description)")
        for key in Array(slots.keys) {
            removeSlot(for: key)
        }
        applyConnectedState(Set())
    }

    // MARK: - Event Routing

    private func handleEvent(
        _ event: PlexServerEvent,
        from serverKey: String,
        isCurrent: (() async -> Bool)? = nil
    ) async {
        switch event {
        case .libraryUpdate(let sectionID, let itemID, let type, let state):
            // Playlist changes (type 15) trigger a playlist-only sync for the server
            if type == 15 {
                let actionableStates = [0, 5, 9]
                guard actionableStates.contains(state) else { return }
                debouncedPlaylistUpdate(serverKey: serverKey)
                return
            }

            // Album metadata update (type=9, state=5) may include artwork changes
            if type == 9 && state == 5 {
                let ratingKey = String(itemID)
                await onArtworkInvalidation?(ratingKey, "album")
                guard await isCurrent?() ?? true else { return }
            }

            // Artist metadata update (type=8, state=5) may include artwork changes
            if type == 8 && state == 5 {
                let ratingKey = String(itemID)
                await onArtworkInvalidation?(ratingKey, "artist")
                guard await isCurrent?() ?? true else { return }
            }

            let actionableStates = [0, 5, 9]
            guard let kind = PlexLibraryChange.Kind(rawValue: type),
                  actionableStates.contains(state) else { return }

            let sectionKey = String(sectionID)
            debouncedLibraryUpdate(
                sectionKey: sectionKey,
                serverKey: serverKey,
                change: PlexLibraryChange(ratingKey: String(itemID), kind: kind, state: state)
            )

        case .activityUpdate(let event, let type, let progress):
            // Track library scan progress for UI display
            if type.contains("library.refresh") || type.contains("library.update") {
                switch event {
                case "started", "updated":
                    // Only publish when progress changes by >=5% or on first report.
                    // During library scans, PMS sends updates every ~10ms — throttle to
                    // cut ~95% of objectWillChange events on this singleton.
                    let oldProgress = serverScanProgress[serverKey] ?? -1
                    if abs(progress - oldProgress) >= 5 || oldProgress < 0 {
                        serverScanProgress[serverKey] = progress
                    }
                case "ended":
                    serverScanProgress.removeValue(forKey: serverKey)
                    EnsembleLogger.debug("🔌 WebSocketCoordinator: Library scan completed for \(serverKey)")
                    // Find enabled libraries for this server and trigger incremental sync
                    triggerSyncForServer(serverKey: serverKey)
                default:
                    break
                }
            }

            // PMS download queue item finished — notify the download service
            // after the activity burst so it can restart idle workers once.
            if type.contains("media.download") && event == "ended" {
                pendingDownloadCompletions.schedule(key: serverKey, delay: downloadCompletionDebounce) { [weak self] in
                    await self?.onDownloadQueueCompleted?()
                }
            }

        case .serverShutdown:
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Server shutdown for \(serverKey)")
            // Mark server offline immediately
            await onServerOffline?(serverKey)

        case .settingsUpdate:
            // Server settings changed — debounce to coalesce rapid bursts (e.g. 5 events in 3s)
            debouncedSettingsUpdate(serverKey: serverKey)

        case .connectionHealthy:
            // Reset health check TTL — no need to probe this server
            await onServerHealthy?(serverKey)
        }
    }

    /// Debounce library update triggers to coalesce batch updates from the server.
    private func debouncedLibraryUpdate(
        sectionKey: String,
        serverKey: String,
        change: PlexLibraryChange? = nil
    ) {
        let debounceKey = "\(serverKey):\(sectionKey)"
        if let change {
            pendingLibraryChanges[debounceKey, default: []] = pendingLibraryChanges[debounceKey, default: []]
                .filter { $0.ratingKey != change.ratingKey || $0.kind != change.kind }
            pendingLibraryChanges[debounceKey, default: []].insert(change)
        }

        pendingLibraryUpdates.schedule(key: debounceKey, delay: libraryUpdateDebounce) { [weak self] in
            guard let self else { return }
            let hasConcreteChanges = self.pendingLibraryChanges[debounceKey]?.isEmpty == false
            guard self.shouldTriggerLibrarySync(
                for: debounceKey,
                hasConcreteChanges: hasConcreteChanges
            ) else {
                if hasConcreteChanges, self.activeLibrarySyncs.contains(debounceKey) {
                    self.debouncedLibraryUpdate(sectionKey: sectionKey, serverKey: serverKey)
                }
                return
            }
            defer {
                if !Task.isCancelled { self.finishLibrarySync(for: debounceKey) }
            }
            let changes = self.pendingLibraryChanges.removeValue(forKey: debounceKey) ?? []

            EnsembleLogger.debug("🔌 WebSocketCoordinator: Triggering incremental sync for section \(sectionKey) (items=\(changes.count))")

            if let onLibraryUpdate = self.onLibraryUpdate {
                await onLibraryUpdate(sectionKey, serverKey, changes)
            } else {
                EnsembleLogger.error("🔌 WebSocketCoordinator: onLibraryUpdate callback is nil — sync not triggered!")
            }
        }
    }

    /// Debounce playlist update triggers to coalesce batch updates from the server.
    /// Uses a longer debounce than library updates because playlist mutations often
    /// emit several timeline events in quick succession (add item, reorder, etc.).
    private func debouncedPlaylistUpdate(serverKey: String) {
        pendingPlaylistUpdates.schedule(key: serverKey, delay: playlistUpdateDebounce) { [weak self] in
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Triggering playlist sync for server \(serverKey)")

            if let onPlaylistUpdate = self?.onPlaylistUpdate {
                await onPlaylistUpdate(serverKey)
            }
        }
    }

    /// Debounce settings-changed events to avoid processing rapid bursts.
    /// Only logs once per server within the debounce window.
    private func debouncedSettingsUpdate(serverKey: String) {
        pendingSettingsUpdates.schedule(key: serverKey, delay: settingsUpdateDebounce) {
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Settings changed for \(serverKey) (debounced)")
        }
    }

    private func subscribeToNetworkChanges() {
        networkObserver?.cancel()
        networkObserver = networkMonitor.$networkState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.isActive else { return }
                if state != .offline {
                    EnsembleLogger.debug("🔌 WebSocketCoordinator: Network restored — refreshing connections")
                    self.refreshConnections()
                } else {
                    self.disconnectManagersForOffline()
                }
            }
    }

    /// Trigger incremental sync for all enabled libraries on a server.
    private func triggerSyncForServer(serverKey: String) {
        let parts = serverKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let accountId = String(parts[0])
        let serverId = String(parts[1])
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else { return }
        let sectionKeys = Set(server.libraries.filter(\.isEnabled).map(\.key))

        for sectionKey in sectionKeys.sorted() {
            debouncedLibraryUpdate(sectionKey: sectionKey, serverKey: serverKey)
        }
    }

    private func shouldTriggerLibrarySync(
        for debounceKey: String,
        hasConcreteChanges: Bool
    ) -> Bool {
        if activeLibrarySyncs.contains(debounceKey) {
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Skipping section sync for \(debounceKey) — already in flight")
            return false
        }

        if !hasConcreteChanges,
           let lastCompletion = lastLibrarySyncCompletion[debounceKey],
           Date().timeIntervalSince(lastCompletion) < recentLibrarySyncCooldown {
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Skipping section sync for \(debounceKey) — completed recently")
            return false
        }

        activeLibrarySyncs.insert(debounceKey)
        return true
    }

    private func finishLibrarySync(for debounceKey: String) {
        activeLibrarySyncs.remove(debounceKey)
        lastLibrarySyncCompletion[debounceKey] = Date()
    }

    internal func setConnectedStateForTesting(_ serverKeys: Set<String>) {
        applyConnectedState(serverKeys)
    }

    internal func handleEventForTesting(_ event: PlexServerEvent, from serverKey: String) async {
        await handleEvent(event, from: serverKey)
    }

    private func applyConnectedState(_ newValue: Set<String>) {
        guard newValue != connectedServerKeys else { return }

        let previousHasConnections = !connectedServerKeys.isEmpty
        connectedServerKeys = newValue
        let hasConnections = !newValue.isEmpty

        guard previousHasConnections != hasConnections else { return }
        Task { [weak self] in
            guard let self, !self.connectedServerKeys.isEmpty == hasConnections else { return }
            await self.onConnectionAvailabilityChanged?(hasConnections)
        }
    }
}
