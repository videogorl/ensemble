import Combine
import EnsembleAPI
import Foundation

public enum AddAccountState: Equatable {
    case ready
    case authenticating(code: String, linkURL: URL)
    case selectingServer
    case selectingLibraries
    case complete
}

@MainActor
public final class AddPlexAccountViewModel: ObservableObject {
    @Published public private(set) var state: AddAccountState = .ready
    @Published public private(set) var servers: [Server] = []
    @Published public private(set) var selectedServer: Server?
    @Published public private(set) var libraries: [Library] = []
    @Published public private(set) var serverLibraryErrors: [String: String] = [:]
    @Published public var selectedLibraryKeys: Set<String> = []
    @Published public var selectedLibraryCompositeKeys: Set<String> = []
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = false

    private let authService: PlexAuthService
    private let accountDiscoveryService: any PlexAccountDiscoveryServiceProtocol
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private var pollTask: Task<Void, Never>?
    private var authToken: String?
    private var discoveredServers: [PlexServerConfig] = []
    private var discoveredIdentity: PlexAccountIdentity?
    internal var refreshProvidersHandlerForTesting: (() -> Void)?
    internal var syncAllHandlerForTesting: (() async -> Void)?

    public init(
        authService: PlexAuthService,
        accountDiscoveryService: any PlexAccountDiscoveryServiceProtocol,
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator
    ) {
        self.authService = authService
        self.accountDiscoveryService = accountDiscoveryService
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Auth Flow

    public func startAuth() async {
        isLoading = true
        error = nil

        do {
            let authState = try await authService.requestPIN()
            state = .authenticating(code: authState.pin.code, linkURL: authState.linkURL)

            pollTask?.cancel()
            pollTask = Task {
                await pollForAuthorization(pin: authState.pin)
            }
        } catch {
            self.error = error.localizedDescription
            state = .ready
        }

        isLoading = false
    }

    private func pollForAuthorization(pin: PlexPIN) async {
        do {
            let token = try await authService.waitForAuthorization(pin: pin)
            authToken = token
            state = .selectingServer
            await loadServers()
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
                state = .ready
            }
        }
    }

    // MARK: - Server Selection

    public func loadServers() async {
        guard let token = authToken else { return }
        isLoading = true
        error = nil

        do {
            let discovery = try await accountDiscoveryService.discoverAccount(authToken: token)
            discoveredIdentity = discovery.identity
            serverLibraryErrors = discovery.serverLibraryErrors
            discoveredServers = discovery.servers
            servers = discovery.servers.map(Self.mapServerConfigToServer)

            // Default to all discovered libraries selected.
            selectedLibraryCompositeKeys = Set(discovery.servers.flatMap { server in
                server.libraries.map { Self.selectionKey(serverId: server.id, libraryKey: $0.key) }
            })
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func selectServer(_ server: Server) async {
        selectedServer = server
        state = .selectingLibraries
        await loadLibraries(for: server.id)
    }

    // MARK: - Library Selection

    public func loadLibraries() async {
        guard let server = selectedServer else { return }
        await loadLibraries(for: server.id)
    }

    public func loadLibraries(for serverId: String) async {
        isLoading = true
        error = nil

        if let server = discoveredServers.first(where: { $0.id == serverId }) {
            libraries = server.libraries.map {
                Library(id: $0.key, key: $0.key, title: $0.title, type: "music")
            }
            selectedLibraryKeys = Set(
                server.libraries
                    .filter { selectedLibraryCompositeKeys.contains(Self.selectionKey(serverId: server.id, libraryKey: $0.key)) }
                    .map(\.key)
            )
        } else {
            libraries = []
            selectedLibraryKeys = []
        }

        isLoading = false
    }

    public func toggleLibrary(_ library: Library) {
        guard let selectedServer else { return }
        let compositeKey = Self.selectionKey(serverId: selectedServer.id, libraryKey: library.key)
        if selectedLibraryCompositeKeys.contains(compositeKey) {
            selectedLibraryCompositeKeys.remove(compositeKey)
            selectedLibraryKeys.remove(library.key)
        } else {
            selectedLibraryCompositeKeys.insert(compositeKey)
            selectedLibraryKeys.insert(library.key)
        }
    }

    public func confirmLibraries() {
        guard let authToken = authToken else { return }
        guard !selectedLibraryCompositeKeys.isEmpty else {
            error = "Please select at least one library"
            return
        }

        guard !discoveredServers.isEmpty else {
            error = "No servers found for this account"
            return
        }

        let serverConfigs = discoveredServers.map { server in
            let updatedLibraries = server.libraries.map { library in
                PlexLibraryConfig(
                    id: library.id,
                    key: library.key,
                    title: library.title,
                    isEnabled: selectedLibraryCompositeKeys.contains(
                        Self.selectionKey(serverId: server.id, libraryKey: library.key)
                    )
                )
            }

            return PlexServerConfig(
                id: server.id,
                name: server.name,
                url: server.url,
                connections: server.connections,
                token: server.token,
                platform: server.platform,
                libraries: updatedLibraries
            )
        }

        let accountId = discoveredIdentity?.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAccountID = (accountId?.isEmpty == false) ? accountId! : UUID().uuidString
        let tokenMetadata = PlexAuthService.tokenMetadata(from: authToken)
        let account = PlexAccountConfig(
            id: resolvedAccountID,
            email: discoveredIdentity?.email,
            plexUsername: discoveredIdentity?.plexUsername,
            displayTitle: discoveredIdentity?.displayTitle,
            authToken: authToken,
            authTokenMetadata: tokenMetadata,
            servers: serverConfigs
        )

        accountManager.addPlexAccount(account)
        
        // Refresh sync providers to include the new account
        if let refreshProvidersHandlerForTesting {
            refreshProvidersHandlerForTesting()
        } else {
            syncCoordinator.refreshProviders()
        }
        
        // Trigger initial sync in the background
        Task {
            if let syncAllHandlerForTesting {
                await syncAllHandlerForTesting()
            } else {
                await syncCoordinator.syncAll()
            }
        }
        
        state = .complete
    }

    // MARK: - Cancel

    public func cancelAuth() {
        pollTask?.cancel()
        pollTask = nil
        state = .ready
    }

    public func reset() {
        pollTask?.cancel()
        pollTask = nil
        state = .ready
        servers = []
        selectedServer = nil
        libraries = []
        selectedLibraryKeys = []
        selectedLibraryCompositeKeys = []
        serverLibraryErrors = [:]
        error = nil
        isLoading = false
        authToken = nil
        discoveredServers = []
        discoveredIdentity = nil
    }

    internal func applyDiscoveryForTesting(
        authToken: String,
        identity: PlexAccountIdentity,
        servers: [PlexServerConfig]
    ) {
        self.authToken = authToken
        discoveredIdentity = identity
        discoveredServers = servers
        self.servers = servers.map(Self.mapServerConfigToServer)
        selectedLibraryCompositeKeys = Set(servers.flatMap { server in
            server.libraries.map { Self.selectionKey(serverId: server.id, libraryKey: $0.key) }
        })
    }

    private static func selectionKey(serverId: String, libraryKey: String) -> String {
        "\(serverId):\(libraryKey)"
    }

    private static func mapServerConfigToServer(_ server: PlexServerConfig) -> Server {
        Server(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: server.connections.map {
                ServerConnection(
                    uri: $0.uri,
                    local: $0.local,
                    relay: $0.relay ?? false,
                    address: $0.address,
                    port: $0.port,
                    protocol: $0.protocol
                )
            },
            accessToken: server.token,
            platform: server.platform,
            isLocal: server.connections.first(where: \.local) != nil
        )
    }
}
