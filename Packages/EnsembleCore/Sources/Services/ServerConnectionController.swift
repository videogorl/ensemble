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
}
