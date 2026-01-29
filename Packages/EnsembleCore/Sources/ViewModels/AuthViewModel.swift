import Combine
import EnsembleAPI
import Foundation

public enum AuthState: Equatable {
    case unknown
    case unauthenticated
    case authenticating(code: String, linkURL: URL)
    case selectingServer
    case authenticated
}

@MainActor
public final class AuthViewModel: ObservableObject {
    @Published public private(set) var authState: AuthState = .unknown
    @Published public private(set) var servers: [Server] = []
    @Published public private(set) var selectedServer: Server?
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
                authState = .authenticated
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
        } catch {
            print("Sign out error: \(error)")
        }

        servers = []
        selectedServer = nil
        authState = .unauthenticated
        isLoading = false
    }

    public func cancelAuth() {
        pollTask?.cancel()
        pollTask = nil
        authState = .unauthenticated
    }
}
