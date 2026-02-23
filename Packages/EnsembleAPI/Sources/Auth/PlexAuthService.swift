import Foundation

public enum PlexAuthError: Error, LocalizedError {
    case pinRequestFailed
    case pinExpired
    case pinNotAuthorized
    case invalidResponse
    case networkError(Error)
    case tokenNotFound

    public var errorDescription: String? {
        switch self {
        case .pinRequestFailed:
            return "Failed to request PIN from Plex"
        case .pinExpired:
            return "PIN has expired. Please try again."
        case .pinNotAuthorized:
            return "PIN was not authorized"
        case .invalidResponse:
            return "Invalid response from Plex"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .tokenNotFound:
            return "No authentication token found"
        }
    }
}

public struct PlexAuthState: Sendable {
    public let pin: PlexPIN
    public let linkURL: URL

    public init(pin: PlexPIN, linkURL: URL) {
        self.pin = pin
        self.linkURL = linkURL
    }
}

public actor PlexAuthService {
    private let session: URLSession
    private let keychain: KeychainServiceProtocol
    private let clientIdentifier: String
    private let productName: String
    private let productVersion: String
    private let deviceName: String

    private static let plexTVBaseURL = "https://plex.tv"
    // Hardcoded link URL — safe to force-unwrap as a named constant (literal cannot fail)
    private static let plexLinkURL = URL(string: "https://plex.tv/link")!

    public init(
        keychain: KeychainServiceProtocol = KeychainService.shared,
        productName: String = "Ensemble",
        productVersion: String = "1.0",
        deviceName: String? = nil
    ) {
        self.keychain = keychain
        self.productName = productName
        self.productVersion = productVersion

        #if os(iOS)
        self.deviceName = deviceName ?? UIDevice.current.name
        #elseif os(macOS)
        self.deviceName = deviceName ?? Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        self.deviceName = deviceName ?? "Apple Watch"
        #else
        self.deviceName = deviceName ?? "Unknown Device"
        #endif

        // Get or create client identifier
        if let existingId = try? keychain.get(KeychainKey.plexClientIdentifier) {
            self.clientIdentifier = existingId
        } else {
            let newId = UUID().uuidString
            // try? is unavoidable in init (can't throw); log if it fails so we notice in debug builds
            if (try? keychain.save(newId, forKey: KeychainKey.plexClientIdentifier)) == nil {
                #if DEBUG
                EnsembleLogger.debug("⚠️ [PlexAuthService] Failed to persist client identifier to keychain")
                #endif
            }
            self.clientIdentifier = newId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15  // Reduced from 30s for better responsiveness
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Start the PIN-based OAuth flow
    public func requestPIN() async throws -> PlexAuthState {
        guard let url = URL(string: "\(Self.plexTVBaseURL)/api/v2/pins") else {
            throw PlexAuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("true", forHTTPHeaderField: "strong")
        addPlexHeaders(to: &request)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 201 else {
                throw PlexAuthError.pinRequestFailed
            }

            let pin = try JSONDecoder().decode(PlexPIN.self, from: data)

            return PlexAuthState(pin: pin, linkURL: Self.plexLinkURL)
        } catch let error as PlexAuthError {
            throw error
        } catch {
            throw PlexAuthError.networkError(error)
        }
    }

    /// Poll for PIN authorization status
    public func checkPIN(_ pin: PlexPIN) async throws -> String? {
        guard let url = URL(string: "\(Self.plexTVBaseURL)/api/v2/pins/\(pin.id)") else {
            throw PlexAuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addPlexHeaders(to: &request)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexAuthError.invalidResponse
            }

            if httpResponse.statusCode == 404 {
                throw PlexAuthError.pinExpired
            }

            guard httpResponse.statusCode == 200 else {
                throw PlexAuthError.invalidResponse
            }

            let updatedPIN = try JSONDecoder().decode(PlexPIN.self, from: data)

            if let token = updatedPIN.authToken, !token.isEmpty {
                return token
            }

            return nil
        } catch let error as PlexAuthError {
            throw error
        } catch {
            throw PlexAuthError.networkError(error)
        }
    }

    /// Poll until authorized or timeout
    public func waitForAuthorization(
        pin: PlexPIN,
        pollInterval: TimeInterval = 2.0,
        timeout: TimeInterval = 300.0
    ) async throws -> String {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if let token = try await checkPIN(pin) {
                return token
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        throw PlexAuthError.pinExpired
    }

    public static func tokenMetadata(from token: String) -> PlexAuthTokenMetadata {
        PlexJWTParser.decodeMetadata(from: token)
    }

    // MARK: - Private Methods

    private func addPlexHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(productVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("controller", forHTTPHeaderField: "X-Plex-Provides")

        #if os(iOS)
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        #elseif os(macOS)
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        #elseif os(watchOS)
        request.setValue("watchOS", forHTTPHeaderField: "X-Plex-Platform")
        #endif
    }
}

#if os(iOS)
import UIKit
#endif
