import EnsembleAPI
import Foundation

public struct PlexAccountIdentity: Sendable, Equatable {
    public let id: String
    public let email: String?
    public let plexUsername: String?
    public let displayTitle: String?

    public init(
        id: String,
        email: String?,
        plexUsername: String?,
        displayTitle: String?
    ) {
        self.id = id
        self.email = email
        self.plexUsername = plexUsername
        self.displayTitle = displayTitle
    }
}

public struct PlexAccountDiscoveryResult: Sendable, Equatable {
    public let identity: PlexAccountIdentity
    public let servers: [PlexServerConfig]
    public let serverLibraryErrors: [String: String]

    public init(
        identity: PlexAccountIdentity,
        servers: [PlexServerConfig],
        serverLibraryErrors: [String: String]
    ) {
        self.identity = identity
        self.servers = servers
        self.serverLibraryErrors = serverLibraryErrors
    }

    public var hasPartialFailures: Bool {
        !serverLibraryErrors.isEmpty
    }
}

public protocol PlexAccountDiscoveryClientProtocol: Sendable {
    func getUserInfo(token: String) async throws -> PlexUser
    func getResources(token: String) async throws -> [PlexDevice]
    func getMusicLibrarySections(
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> [PlexLibrarySection]
}

public protocol PlexAccountDiscoveryServiceProtocol: Sendable {
    func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult
}

public struct PlexAPIAccountDiscoveryClient: PlexAccountDiscoveryClientProtocol {
    private let keychain: KeychainServiceProtocol

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    public func getUserInfo(token: String) async throws -> PlexUser {
        let connection = PlexServerConnection(
            url: "https://plex.tv",
            token: token,
            identifier: "plex-tv",
            name: "plex-tv"
        )
        let client = PlexAPIClient(connection: connection, keychain: keychain)
        return try await client.getUserInfo(token: token)
    }

    public func getResources(token: String) async throws -> [PlexDevice] {
        let connection = PlexServerConnection(
            url: "https://plex.tv",
            token: token,
            identifier: "plex-tv",
            name: "plex-tv"
        )
        let client = PlexAPIClient(connection: connection, keychain: keychain)
        return try await client.getResources(token: token)
    }

    public func getMusicLibrarySections(
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> [PlexLibrarySection] {
        let orderedConnections = device.orderedConnections(
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: allowInsecurePolicy
        )

        let fallbackConnections = orderedConnections.isEmpty ? device.connections : orderedConnections
        guard let primaryConnection = fallbackConnections.first else {
            throw PlexAPIError.noServerSelected
        }

        let endpointDescriptors = fallbackConnections.map { connection in
            PlexEndpointDescriptor(
                url: connection.uri,
                local: connection.local,
                relay: connection.relay ?? false,
                secure: connection.protocol == "https"
            )
        }

        let alternativeURLs = endpointDescriptors
            .map(\.url)
            .filter { $0 != primaryConnection.uri }

        let serverToken = device.accessToken ?? token
        let connection = PlexServerConnection(
            url: primaryConnection.uri,
            alternativeURLs: alternativeURLs,
            endpoints: endpointDescriptors,
            selectionPolicy: .plexSpecBalanced,
            allowInsecurePolicy: allowInsecurePolicy,
            token: serverToken,
            identifier: device.clientIdentifier,
            name: device.name
        )
        let client = PlexAPIClient(connection: connection, keychain: keychain)
        _ = try await client.refreshConnection()
        return try await client.getMusicLibrarySections()
    }
}

/// Discovers account identity, servers, and music libraries for Plex account setup and management.
public final class PlexAccountDiscoveryService: @unchecked Sendable {
    private let client: any PlexAccountDiscoveryClientProtocol
    private let allowInsecurePolicyProvider: @Sendable () -> AllowInsecureConnectionsPolicy

    public init(
        client: any PlexAccountDiscoveryClientProtocol,
        allowInsecurePolicyProvider: @escaping @Sendable () -> AllowInsecureConnectionsPolicy = {
            let raw = UserDefaults.standard.string(forKey: "allowInsecureConnectionsPolicy")
            return AllowInsecureConnectionsPolicy(rawValue: raw ?? "") ?? .defaultForEnsemble
        }
    ) {
        self.client = client
        self.allowInsecurePolicyProvider = allowInsecurePolicyProvider
    }

    public convenience init(
        keychain: KeychainServiceProtocol,
        allowInsecurePolicyProvider: @escaping @Sendable () -> AllowInsecureConnectionsPolicy = {
            let raw = UserDefaults.standard.string(forKey: "allowInsecureConnectionsPolicy")
            return AllowInsecureConnectionsPolicy(rawValue: raw ?? "") ?? .defaultForEnsemble
        }
    ) {
        self.init(
            client: PlexAPIAccountDiscoveryClient(keychain: keychain),
            allowInsecurePolicyProvider: allowInsecurePolicyProvider
        )
    }

    public func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult {
        async let userTask = client.getUserInfo(token: authToken)
        async let resourcesTask = client.getResources(token: authToken)

        let user = try await userTask
        let devices = try await resourcesTask
        let allowInsecurePolicy = allowInsecurePolicyProvider()

        var discoveredServers: [PlexServerConfig] = []
        var serverLibraryErrors: [String: String] = [:]

        await withTaskGroup(of: (PlexServerConfig, String?).self) { group in
            for device in devices {
                group.addTask {
                    let orderedConnections = device.orderedConnections(
                        selectionPolicy: .plexSpecBalanced,
                        allowInsecure: allowInsecurePolicy
                    )
                    let fallbackConnections = orderedConnections.isEmpty ? device.connections : orderedConnections
                    let primaryConnection = fallbackConnections.first

                    let connectionConfigs = fallbackConnections.map { connection in
                        PlexConnectionConfig(
                            uri: connection.uri,
                            local: connection.local,
                            relay: connection.relay,
                            address: connection.address,
                            port: connection.port,
                            protocol: connection.protocol
                        )
                    }

                    do {
                        let sections = try await self.client.getMusicLibrarySections(
                            for: device,
                            token: authToken,
                            allowInsecurePolicy: allowInsecurePolicy
                        )
                        let libraries = sections
                            .filter(\.isMusicLibrary)
                            .map { section in
                                PlexLibraryConfig(
                                    id: section.key,
                                    key: section.key,
                                    title: section.title,
                                    isEnabled: false
                                )
                            }

                        return (
                            PlexServerConfig(
                                id: device.clientIdentifier,
                                name: device.name,
                                url: primaryConnection?.uri ?? "",
                                connections: connectionConfigs,
                                token: device.accessToken ?? authToken,
                                platform: device.platform,
                                libraries: libraries
                            ),
                            nil
                        )
                    } catch {
                        let message = error.localizedDescription
                        return (
                            PlexServerConfig(
                                id: device.clientIdentifier,
                                name: device.name,
                                url: primaryConnection?.uri ?? "",
                                connections: connectionConfigs,
                                token: device.accessToken ?? authToken,
                                platform: device.platform,
                                libraries: []
                            ),
                            message
                        )
                    }
                }
            }

            for await (serverConfig, maybeError) in group {
                discoveredServers.append(serverConfig)
                if let error = maybeError {
                    serverLibraryErrors[serverConfig.id] = error
                }
            }
        }

        discoveredServers.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let identity = PlexAccountIdentity(
            id: user.uuid,
            email: user.email,
            plexUsername: user.username,
            displayTitle: user.title
        )

        return PlexAccountDiscoveryResult(
            identity: identity,
            servers: discoveredServers,
            serverLibraryErrors: serverLibraryErrors
        )
    }
}

extension PlexAccountDiscoveryService: PlexAccountDiscoveryServiceProtocol {}
