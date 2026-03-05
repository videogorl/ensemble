import Combine
import EnsembleAPI
import Foundation

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

    private let accountManager: AccountManager
    private let connectionRegistry: ServerConnectionRegistry
    private let serverHealthChecker: ServerHealthChecker

    /// Called when a library update notification arrives. Parameters: (sectionKey: String).
    /// SyncCoordinator wires this to trigger incremental sync for the affected section.
    public var onLibraryUpdate: ((String) async -> Void)?

    /// Called when a server goes offline (WebSocket disconnect or shutdown notification).
    /// Parameter: serverKey (accountId:serverId).
    public var onServerOffline: ((String) async -> Void)?

    /// Called when any message arrives from a server (implicit health signal).
    /// Parameter: serverKey (accountId:serverId).
    public var onServerHealthy: ((String) async -> Void)?

    private var managers: [String: PlexWebSocketManager] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var accountObserver: AnyCancellable?
    private var isActive = false

    // Debounce library update triggers to avoid spamming sync for batch updates
    private var pendingLibraryUpdates: [String: Task<Void, Never>] = [:]
    private let libraryUpdateDebounce: TimeInterval = 3.0

    public init(
        accountManager: AccountManager,
        connectionRegistry: ServerConnectionRegistry,
        serverHealthChecker: ServerHealthChecker
    ) {
        self.accountManager = accountManager
        self.connectionRegistry = connectionRegistry
        self.serverHealthChecker = serverHealthChecker
    }

    // MARK: - Lifecycle

    /// Start WebSocket connections to all active servers. Call on foreground.
    public func start() {
        guard !isActive else { return }
        isActive = true

        EnsembleLogger.info("🔌 WebSocketCoordinator: Starting — accounts=\(accountManager.plexAccounts.count)")

        // Connect to current servers
        refreshConnections()

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

        #if DEBUG
        EnsembleLogger.debug("🔌 WebSocketCoordinator: Stopping")
        #endif

        accountObserver?.cancel()
        accountObserver = nil

        // Stop all managers
        for (key, _) in managers {
            removeManager(for: key)
        }
        managers.removeAll()
        connectedServerKeys.removeAll()

        // Cancel pending debounced updates
        for (_, task) in pendingLibraryUpdates {
            task.cancel()
        }
        pendingLibraryUpdates.removeAll()
    }

    // MARK: - Connection Management

    /// Sync WebSocket managers with current account/server configuration.
    private func refreshConnections() {
        guard isActive else { return }

        var activeKeys = Set<String>()

        for account in accountManager.plexAccounts {
            for server in account.servers {
                // Only connect to servers that have at least one enabled library
                let hasEnabledLibrary = server.libraries.contains { $0.isEnabled }
                guard hasEnabledLibrary else { continue }

                let serverKey = "\(account.id):\(server.id)"
                activeKeys.insert(serverKey)

                // Skip if already connected
                if managers[serverKey] != nil { continue }

                // Get the current endpoint URL from the registry (or fall back to server config)
                Task {
                    let url = await connectionRegistry.currentURL(for: serverKey) ?? server.url
                    await self.addManager(for: serverKey, url: url, token: server.token, name: server.name)
                }
            }
        }

        // Remove managers for servers that are no longer active
        let staleKeys = Set(managers.keys).subtracting(activeKeys)
        for key in staleKeys {
            removeManager(for: key)
            managers.removeValue(forKey: key)
            connectedServerKeys.remove(key)
        }
    }

    private func addManager(for serverKey: String, url: String, token: String, name: String) {
        let manager = PlexWebSocketManager(serverURL: url, token: token, serverName: name)
        managers[serverKey] = manager

        // Start receiving events
        let eventTask = Task { [weak self] in
            let stream = await manager.events()
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                await self.handleEvent(event, from: serverKey)
            }
        }
        eventTasks[serverKey] = eventTask

        // Start the connection
        Task {
            await manager.start()
            await MainActor.run {
                connectedServerKeys.insert(serverKey)
            }
        }

        EnsembleLogger.info("🔌 WebSocketCoordinator: Added manager for \(serverKey) (\(name)) url=\(url)")
    }

    private func removeManager(for serverKey: String) {
        eventTasks[serverKey]?.cancel()
        eventTasks.removeValue(forKey: serverKey)

        if let manager = managers[serverKey] {
            Task { await manager.stop() }
        }

        pendingLibraryUpdates[serverKey]?.cancel()
        pendingLibraryUpdates.removeValue(forKey: serverKey)
    }

    // MARK: - Event Routing

    private func handleEvent(_ event: PlexServerEvent, from serverKey: String) async {
        switch event {
        case .libraryUpdate(let sectionID, _, let type, let state):
            // Only trigger sync for music types (8=artist, 9=album, 10=track) and
            // completed states (5=processed, 9=deleted, 0=created)
            let musicTypes = [8, 9, 10]
            let actionableStates = [0, 5, 9]
            guard musicTypes.contains(type) && actionableStates.contains(state) else {
                EnsembleLogger.info("🔌 WebSocketCoordinator: Ignoring non-actionable library update type=\(type) state=\(state) from \(serverKey)")
                return
            }

            let sectionKey = String(sectionID)
            EnsembleLogger.info("🔌 WebSocketCoordinator: Actionable library update sectionKey=\(sectionKey) type=\(type) state=\(state) from \(serverKey) — scheduling debounced sync")
            debouncedLibraryUpdate(sectionKey: sectionKey, serverKey: serverKey)

        case .activityUpdate(let event, let type, _):
            // Library scan completion triggers a sync
            if type.contains("library.refresh") && event == "ended" {
                #if DEBUG
                EnsembleLogger.debug("🔌 WebSocketCoordinator: Library scan completed for \(serverKey)")
                #endif
                // Find enabled libraries for this server and trigger incremental sync
                triggerSyncForServer(serverKey: serverKey)
            }

        case .serverShutdown:
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Server shutdown for \(serverKey)")
            #endif
            // Mark server offline immediately
            await connectionRegistry.removeEndpoint(for: serverKey)
            await onServerOffline?(serverKey)

        case .settingsUpdate:
            // Server settings changed — may affect available libraries or permissions
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocketCoordinator: Settings changed for \(serverKey)")
            #endif

        case .connectionHealthy:
            // Reset health check TTL — no need to probe this server
            await onServerHealthy?(serverKey)
        }
    }

    /// Debounce library update triggers to coalesce batch updates from the server.
    private func debouncedLibraryUpdate(sectionKey: String, serverKey: String) {
        let debounceKey = "\(serverKey):\(sectionKey)"

        // Cancel any pending debounce for this section
        pendingLibraryUpdates[debounceKey]?.cancel()

        pendingLibraryUpdates[debounceKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.libraryUpdateDebounce ?? 3.0) * 1_000_000_000))
            guard !Task.isCancelled else { return }

            EnsembleLogger.info("🔌 WebSocketCoordinator: Debounce fired — triggering incremental sync for section \(sectionKey) on \(serverKey)")

            if let onLibraryUpdate = await self?.onLibraryUpdate {
                await onLibraryUpdate(sectionKey)
                EnsembleLogger.info("🔌 WebSocketCoordinator: Incremental sync completed for section \(sectionKey)")
            } else {
                EnsembleLogger.error("🔌 WebSocketCoordinator: onLibraryUpdate callback is nil — sync not triggered!")
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

        for library in server.libraries where library.isEnabled {
            debouncedLibraryUpdate(sectionKey: library.key, serverKey: serverKey)
        }
    }
}
