import EnsembleAPI
import Foundation

/// Centralizes API-client endpoint synchronization so SyncCoordinator no longer
/// owns registry subscriptions and URL fan-out directly.
@MainActor
final class ServerConnectionController {
    private let accountManager: AccountManager
    private let serverHealthChecker: ServerHealthChecker
    private let connectionRegistry: ServerConnectionRegistry?
    private var registrySubscriptionTask: Task<Void, Never>?
    private var isRegistrySubscriptionActive = false
    private var registrySubscriptionStartedContinuation: CheckedContinuation<Void, Never>?

    var onConnectionsRefreshed: (() async -> Void)?

    init(
        accountManager: AccountManager,
        serverHealthChecker: ServerHealthChecker,
        connectionRegistry: ServerConnectionRegistry?
    ) {
        self.accountManager = accountManager
        self.serverHealthChecker = serverHealthChecker
        self.connectionRegistry = connectionRegistry
    }

    deinit {
        registrySubscriptionTask?.cancel()
    }

    func start() {
        guard registrySubscriptionTask == nil, let registry = connectionRegistry else {
            return
        }

        registrySubscriptionTask = Task { [weak self] in
            let stream = await registry.endpointChanges()
            await MainActor.run {
                guard let self else { return }
                self.isRegistrySubscriptionActive = true
                self.registrySubscriptionStartedContinuation?.resume()
                self.registrySubscriptionStartedContinuation = nil
            }
            for await state in stream {
                guard let self, !Task.isCancelled else { break }
                await self.applyRegistryUpdate(state)
            }
        }
    }

    func refreshAPIClientConnections() async {
        EnsembleLogger.debug("🔄 ServerConnectionController: Updating API client connections...")
        var didApplyEndpointChange = false

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let serverKey = "\(account.id):\(server.id)"

                if let registry = connectionRegistry,
                   let registryURL = await registry.currentURL(for: serverKey),
                   let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    let currentURL = await apiClient.getCurrentServerURL()
                    if currentURL != registryURL {
                        await apiClient.updateCurrentServerURL(registryURL)
                        didApplyEndpointChange = true
                        EnsembleLogger.debug(
                            "✅ ServerConnectionController: Updated API client for server \(server.name) from registry: \(registryURL)"
                        )
                    }
                    continue
                }

                let connectionState = serverHealthChecker.getServerState(
                    accountId: account.id,
                    serverId: server.id
                )

                if case .connected(let workingURL) = connectionState,
                   let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    let currentURL = await apiClient.getCurrentServerURL()
                    if currentURL != workingURL {
                        await apiClient.updateCurrentServerURL(workingURL)
                        didApplyEndpointChange = true
                        EnsembleLogger.debug(
                            "✅ ServerConnectionController: Updated API client for server \(server.name) to use: \(workingURL)"
                        )
                    }
                } else if case .degraded(let workingURL) = connectionState,
                          let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) {
                    let currentURL = await apiClient.getCurrentServerURL()
                    if currentURL != workingURL {
                        await apiClient.updateCurrentServerURL(workingURL)
                        didApplyEndpointChange = true
                        EnsembleLogger.debug(
                            "⚠️ ServerConnectionController: Updated API client for server \(server.name) to use degraded connection: \(workingURL)"
                        )
                    }
                }
            }
        }

        if didApplyEndpointChange {
            await onConnectionsRefreshed?()
        }
    }

    func ensureServerConnection(sourceKey: String) async throws {
        guard let identity = MediaSourceIdentity.parse(sourceKey),
              identity.libraryId != nil else {
            throw PlexAPIError.noServerSelected
        }

        let currentState = serverHealthChecker.getServerState(
            accountId: identity.accountId,
            serverId: identity.serverId
        )

        EnsembleLogger.debug("🎵 ServerConnectionController: current state for \(identity.accountId):\(identity.serverId) = \(currentState.description)")

        if case .connected = currentState {
            return
        }
        if case .degraded = currentState {
            return
        }

        EnsembleLogger.debug("🔍 ServerConnectionController: Checking server connection before playback")
        let newState = await serverHealthChecker.checkServer(
            accountId: identity.accountId,
            serverId: identity.serverId,
            forceRefresh: false
        )

        switch newState {
        case .connected(let url), .degraded(let url):
            if let apiClient = accountManager.makeAPIClient(accountId: identity.accountId, serverId: identity.serverId) {
                await apiClient.updateCurrentServerURL(url)
                EnsembleLogger.debug("✅ ServerConnectionController: Server connection ready for playback: \(url)")
            }
        case .offline:
            EnsembleLogger.debug("⚠️ ServerConnectionController: Health check reported offline; attempting optimistic failover refresh")
            if let apiClient = accountManager.makeAPIClient(accountId: identity.accountId, serverId: identity.serverId) {
                let refreshResult = try? await apiClient.refreshConnection()
                let refreshedURL = await apiClient.getCurrentServerURL()
                EnsembleLogger.debug(
                    "⚠️ ServerConnectionController: proceeding after refresh with URL host=\(hostForDebugURL(refreshedURL))"
                )
                if let refreshResult {
                    EnsembleLogger.debug(
                        "⚠️ ServerConnectionController: refresh outcome=\(refreshResult.outcome.rawValue) probes=\(refreshResult.probeCount)"
                    )
                }
            }
            // Do not fail fast on health-check offline. Stream URL retrieval/playback
            // performs its own network path and can still succeed on slower paths.
            return
        case .connecting, .unknown:
            EnsembleLogger.debug("⚠️ ServerConnectionController: Server state uncertain, attempting playback anyway")
        }
    }

    func serverFailureMessage(sourceKey: String) -> String? {
        guard let identity = MediaSourceIdentity.parse(sourceKey),
              identity.libraryId != nil else {
            return nil
        }

        return serverHealthChecker.getServerFailureReason(
            accountId: identity.accountId,
            serverId: identity.serverId
        )?.userMessage
    }

    func apiClient(sourceKey: String?) -> PlexAPIClient? {
        guard let identity = MediaSourceIdentity.parse(sourceKey) else {
            return nil
        }

        return accountManager.makeAPIClient(
            accountId: identity.accountId,
            serverId: identity.serverId
        )
    }

    func requireAPIClient(sourceKey: String?) throws -> PlexAPIClient {
        guard let apiClient = apiClient(sourceKey: sourceKey) else {
            throw PlexAPIError.noServerSelected
        }
        return apiClient
    }

    /// Proactively refresh Plex server connections across configured accounts.
    /// Playback retry paths use this to recover from transient endpoint failures.
    func refreshConnections(resetStreamFallbackState: () -> Void) async throws {
        var refreshedAnyConnection = false
        var lastError: Error?

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                do {
                    let result = try await apiClient.refreshConnection()
                    refreshedAnyConnection = true
                    EnsembleLogger.debug(
                        "🔄 ServerConnectionController: Refreshed \(server.name) outcome=\(result.outcome.rawValue), probes=\(result.probeCount)"
                    )
                } catch {
                    lastError = error
                    EnsembleLogger.debug(
                        "⚠️ ServerConnectionController: Failed to refresh \(server.name): \(error.localizedDescription)"
                    )
                }
            }
        }

        guard refreshedAnyConnection else {
            throw lastError ?? PlexAPIError.noServerSelected
        }

        resetStreamFallbackState()
    }

    func connectionStateAfterSuccessfulSync(
        for source: MusicSourceIdentifier,
        fallback: ServerConnectionState
    ) async -> ServerConnectionState {
        var resolvedURL: String?

        if let apiClient = accountManager.makeAPIClient(accountId: source.accountId, serverId: source.serverId) {
            let currentURL = await apiClient.getCurrentServerURL().trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentURL.isEmpty {
                resolvedURL = currentURL
            }
        }

        if resolvedURL == nil,
           let account = accountManager.plexAccounts.first(where: { $0.id == source.accountId }),
           let server = account.servers.first(where: { $0.id == source.serverId }) {
            let fallbackURL = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackURL.isEmpty {
                resolvedURL = fallbackURL
            }
        }

        guard let resolvedURL else {
            return fallback
        }

        if case .degraded = fallback {
            return .degraded(url: resolvedURL)
        }

        return .connected(url: resolvedURL)
    }

    internal func awaitRegistryPropagationForTesting() async {
        await Task.yield()
        await Task.yield()
    }

    internal func awaitRegistrySubscriptionStartedForTesting() async {
        if isRegistrySubscriptionActive {
            return
        }

        await withCheckedContinuation { continuation in
            registrySubscriptionStartedContinuation = continuation
        }
    }

    internal func processRegistryUpdateForTesting(_ state: ServerEndpointState) async {
        await applyRegistryUpdate(state)
    }

    private func applyRegistryUpdate(_ state: ServerEndpointState) async {
        let parts = state.serverKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let accountId = String(parts[0])
        let serverId = String(parts[1])

        if let apiClient = accountManager.makeAPIClient(accountId: accountId, serverId: serverId) {
            let currentURL = await apiClient.getCurrentServerURL()
            if currentURL != state.endpoint.url {
                await apiClient.updateCurrentServerURL(state.endpoint.url)
                EnsembleLogger.debug(
                    "📍 ServerConnectionController: Registry synced API client for \(state.serverKey) to \(state.endpoint.url) (source=\(state.source.rawValue))"
                )
            }
        }

        await onConnectionsRefreshed?()
    }

    private func hostForDebugURL(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? "invalid"
    }
}
