import Combine
import EnsembleAPI
import Foundation

public enum AuthState: Equatable {
    case unknown
    case unauthenticated
    case authenticating(code: String, linkURL: URL)
    case selectingServer
    case selectingLibrary
    case authenticated
}

@MainActor
public final class AuthViewModel: ObservableObject {
    @Published public private(set) var authState: AuthState = .unknown
    @Published public private(set) var servers: [Server] = []
    @Published public private(set) var selectedServer: Server?
    @Published public private(set) var libraries: [Library] = []
    @Published public private(set) var selectedLibrary: Library?
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = false

    private let authService: PlexAuthService
    private let apiClient: PlexAPIClient
    private var pollTask: Task<Void, Never>?

    public init(authService: PlexAuthService, apiClient: PlexAPIClient) {
        self.authService = authService
        self.apiClient = apiClient
    }

    public func checkAuthState() async {
        isLoading = true
        defer { isLoading = false }

        // Check if we have a stored token
        let hasToken = await authService.isAuthenticated()

        if hasToken {
            // Check if we have a selected server
            let connection = await apiClient.getServerConnection()
            if connection != nil {
                // Check if we have a selected library
                let librarySelection = await apiClient.getLibrarySelection()
                if librarySelection != nil {
                    authState = .authenticated
                } else {
                    authState = .selectingLibrary
                    await loadLibraries()
                }
            } else {
                authState = .selectingServer
                await loadServers()
            }
        } else {
            authState = .unauthenticated
        }
    }

    public func startAuth() async {
        isLoading = true
        error = nil

        do {
            let authState = try await authService.requestPIN()
            self.authState = .authenticating(code: authState.pin.code, linkURL: authState.linkURL)

            // Start polling for authorization
            pollTask?.cancel()
            pollTask = Task {
                await pollForAuthorization(pin: authState.pin)
            }
        } catch {
            self.error = error.localizedDescription
            self.authState = .unauthenticated
        }

        isLoading = false
    }

    private func pollForAuthorization(pin: PlexPIN) async {
        do {
            _ = try await authService.waitForAuthorization(pin: pin)
            authState = .selectingServer
            await loadServers()
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
                self.authState = .unauthenticated
            }
        }
    }

    public func loadServers() async {
        isLoading = true
        error = nil

        do {
            let devices = try await apiClient.getResources()
            servers = devices.map { Server(from: $0) }

            // Auto-select if only one server
            if servers.count == 1, let server = servers.first {
                await selectServer(server)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func selectServer(_ server: Server) async {
        guard let token = server.accessToken else {
            error = "Server has no access token"
            return
        }

        isLoading = true

        do {
            let connection = PlexServerConnection(
                url: server.url,
                token: token,
                identifier: server.id,
                name: server.name
            )
            try await apiClient.setServerConnection(connection)
            selectedServer = server
            authState = .selectingLibrary
            await loadLibraries()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func loadLibraries() async {
        isLoading = true
        error = nil

        do {
            let sections = try await apiClient.getMusicLibrarySections()
            libraries = sections.map { Library(from: $0) }

            // Auto-select if only one library
            if libraries.count == 1, let library = libraries.first {
                await selectLibrary(library)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func selectLibrary(_ library: Library) async {
        isLoading = true

        do {
            let selection = PlexLibrarySelection(key: library.key, title: library.title)
            try await apiClient.setLibrarySelection(selection)
            selectedLibrary = library
            authState = .authenticated
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func signOut() async {
        isLoading = true

        do {
            try await authService.signOut()
            try await apiClient.clearServerConnection()
            try await apiClient.clearLibrarySelection()
        } catch {
            print("Sign out error: \(error)")
        }

        servers = []
        selectedServer = nil
        libraries = []
        selectedLibrary = nil
        authState = .unauthenticated
        isLoading = false
    }

    public func changeLibrary() async {
        authState = .selectingLibrary
        await loadLibraries()
    }

    public func cancelAuth() {
        pollTask?.cancel()
        pollTask = nil
        authState = .unauthenticated
    }
}
