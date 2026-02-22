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
    @Published public var selectedLibraryKeys: Set<String> = []
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = false

    private let authService: PlexAuthService
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let keychain: KeychainServiceProtocol
    private var pollTask: Task<Void, Never>?
    private var authToken: String?

    public init(
        authService: PlexAuthService,
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        keychain: KeychainServiceProtocol
    ) {
        self.authService = authService
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.keychain = keychain
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
            let tempConnection = PlexServerConnection(
                url: "https://plex.tv",
                token: token,
                identifier: "temp",
                name: "temp"
            )
            let client = PlexAPIClient(connection: tempConnection, keychain: keychain)
            guard let token = authToken else {
                throw NSError(domain: "AddPlexAccount", code: -1, userInfo: [NSLocalizedDescriptionKey: "No auth token"])
            }
            let devices = try await client.getResources(token: token)
            servers = devices.map { Server(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func selectServer(_ server: Server) async {
        selectedServer = server
        state = .selectingLibraries
        await loadLibraries()
    }

    // MARK: - Library Selection

    public func loadLibraries() async {
        guard let server = selectedServer, let token = server.accessToken else { return }
        isLoading = true
        error = nil

        do {
            // Include all alternative connection URLs for failover support
            let allowInsecurePolicy = AllowInsecureConnectionsPolicy(
                rawValue: UserDefaults.standard.string(forKey: "allowInsecureConnectionsPolicy") ?? ""
            ) ?? .defaultForEnsemble
            let endpointDescriptors = server.connections.map { connection in
                PlexEndpointDescriptor(
                    url: connection.uri,
                    local: connection.local,
                    relay: connection.relay,
                    secure: connection.protocol == "https"
                )
            }
            let alternativeURLs = endpointDescriptors
                .map(\.url)
                .filter { $0 != server.url }
            
            let connection = PlexServerConnection(
                url: server.url,
                alternativeURLs: alternativeURLs,
                endpoints: endpointDescriptors,
                selectionPolicy: .plexSpecBalanced,
                allowInsecurePolicy: allowInsecurePolicy,
                token: token,
                identifier: server.id,
                name: server.name
            )
            let client = PlexAPIClient(connection: connection, keychain: keychain)
            
            // Proactively test connections to avoid waiting for timeout
            #if DEBUG
            EnsembleLogger.debug("📚 Testing server connections before loading libraries...")
            #endif
            _ = try await client.refreshConnection()
            
            let sections = try await client.getMusicLibrarySections()
            libraries = sections.map { Library(from: $0) }

            // Pre-select all libraries
            selectedLibraryKeys = Set(libraries.map { $0.key })
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func toggleLibrary(_ library: Library) {
        if selectedLibraryKeys.contains(library.key) {
            selectedLibraryKeys.remove(library.key)
        } else {
            selectedLibraryKeys.insert(library.key)
        }
    }

    public func confirmLibraries() {
        guard let server = selectedServer,
              let token = server.accessToken,
              let authToken = authToken else { return }

        let selectedLibs = libraries.filter { selectedLibraryKeys.contains($0.key) }
        guard !selectedLibs.isEmpty else {
            error = "Please select at least one library"
            return
        }

        let libraryConfigs = selectedLibs.map { lib in
            PlexLibraryConfig(id: lib.key, key: lib.key, title: lib.title, isEnabled: true)
        }

        // Convert server connections to PlexConnectionConfig
        let connectionConfigs = server.connections.map { conn in
            PlexConnectionConfig(
                uri: conn.uri,
                local: conn.local,
                relay: conn.relay,
                address: conn.address,
                port: conn.port,
                protocol: conn.protocol
            )
        }

        let serverConfig = PlexServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            connections: connectionConfigs,
            token: token,
            platform: server.platform,
            libraries: libraryConfigs
        )

        let accountId = UUID().uuidString
        let tokenMetadata = PlexAuthService.tokenMetadata(from: authToken)
        let account = PlexAccountConfig(
            id: accountId,
            username: server.name,
            authToken: authToken,
            authTokenMetadata: tokenMetadata,
            servers: [serverConfig]
        )

        accountManager.addPlexAccount(account)
        
        // Refresh sync providers to include the new account
        syncCoordinator.refreshProviders()
        
        // Trigger initial sync in the background
        Task {
            await syncCoordinator.syncAll()
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
        error = nil
        isLoading = false
        authToken = nil
    }
}
