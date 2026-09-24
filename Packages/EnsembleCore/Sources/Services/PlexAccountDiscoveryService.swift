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
    public let subscription: PlexSubscription?
    public let servers: [PlexServerConfig]
    public let serverLibraryErrors: [String: String]
    public let serverCapabilityErrors: [String: String]

    public init(
        identity: PlexAccountIdentity,
        subscription: PlexSubscription? = nil,
        servers: [PlexServerConfig],
        serverLibraryErrors: [String: String],
        serverCapabilityErrors: [String: String] = [:]
    ) {
        self.identity = identity
        self.subscription = subscription
        self.servers = servers
        self.serverLibraryErrors = serverLibraryErrors
        self.serverCapabilityErrors = serverCapabilityErrors
    }

    public var hasPartialFailures: Bool {
        !serverLibraryErrors.isEmpty || !serverCapabilityErrors.isEmpty
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
    func getServerCapabilities(
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> PlexServerCapabilities
    func getTrackCount(
        sectionKey: String,
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> Int?
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
        let client = try makeClient(for: device, token: token, allowInsecurePolicy: allowInsecurePolicy)
        _ = try await client.refreshConnection()
        return try await client.getMusicLibrarySections()
    }

    public func getServerCapabilities(
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> PlexServerCapabilities {
        let client = try makeClient(for: device, token: token, allowInsecurePolicy: allowInsecurePolicy)
        _ = try await client.refreshConnection()
        return try await client.getServerCapabilities()
    }

    public func getTrackCount(
        sectionKey: String,
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) async throws -> Int? {
        let client = try makeClient(for: device, token: token, allowInsecurePolicy: allowInsecurePolicy)
        _ = try await client.refreshConnection()
        return try await client.getTrackCount(sectionKey: sectionKey)
    }

    /// Creates a temporary `PlexAPIClient` for the given device during discovery.
    private func makeClient(
        for device: PlexDevice,
        token: String,
        allowInsecurePolicy: AllowInsecureConnectionsPolicy
    ) throws -> PlexAPIClient {
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
        return PlexAPIClient(connection: connection, keychain: keychain)
    }
}

// Used internally to fan-out concurrent user+resources discovery without async let,
// which causes Swift runtime crashes in protocol witness cleanup on certain OS versions.
private enum DiscoveryInitialResult: Sendable {
    case user(PlexUser)
    case devices([PlexDevice])
}

/// Discovers account identity, servers, and music libraries for Plex account setup and management.
public final class PlexAccountDiscoveryService: @unchecked Sendable {
    private let client: any PlexAccountDiscoveryClientProtocol
    private let allowInsecurePolicyProvider: @Sendable () -> AllowInsecureConnectionsPolicy

    public init(
        client: any PlexAccountDiscoveryClientProtocol,
        allowInsecurePolicyProvider: @escaping @Sendable () -> AllowInsecureConnectionsPolicy = {
            AllowInsecureConnectionsPolicy.storedPreference()
        }
    ) {
        self.client = client
        self.allowInsecurePolicyProvider = allowInsecurePolicyProvider
    }

    public convenience init(
        keychain: KeychainServiceProtocol,
        allowInsecurePolicyProvider: @escaping @Sendable () -> AllowInsecureConnectionsPolicy = {
            AllowInsecureConnectionsPolicy.storedPreference()
        }
    ) {
        self.init(
            client: PlexAPIAccountDiscoveryClient(keychain: keychain),
            allowInsecurePolicyProvider: allowInsecurePolicyProvider
        )
    }

    public func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult {
        // Fetch user info and Plex resources concurrently. We use withThrowingTaskGroup
        // instead of `async let` because `async let` in a protocol witness thunk can cause
        // a Swift runtime abort during async-let cleanup when one task throws or the parent
        // task is cancelled (repro: asyncLet_finish_after_task_completion crash on iOS 26 beta).
        let (user, devices) = try await withThrowingTaskGroup(of: DiscoveryInitialResult.self) { group in
            group.addTask { .user(try await self.client.getUserInfo(token: authToken)) }
            group.addTask { .devices(try await self.client.getResources(token: authToken)) }

            var user: PlexUser?
            var devices: [PlexDevice]?
            for try await result in group {
                switch result {
                case .user(let u): user = u
                case .devices(let d): devices = d
                }
            }
            guard let user, let devices else { throw CancellationError() }
            return (user, devices)
        }

        let allowInsecurePolicy = allowInsecurePolicyProvider()

        var discoveredServers: [PlexServerConfig] = []
        var serverLibraryErrors: [String: String] = [:]
        var serverCapabilityErrors: [String: String] = [:]

        try await withThrowingTaskGroup(of: (PlexServerConfig, libraryError: String?, capabilityError: String?).self) { group in
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

                    let capabilities: PlexServerCapabilities?
                    let capabilityError: String?
                    do {
                        let fetchedCapabilities = try await self.client.getServerCapabilities(
                            for: device,
                            token: authToken,
                            allowInsecurePolicy: allowInsecurePolicy
                        )
                        capabilities = fetchedCapabilities
                        capabilityError = nil
                        EnsembleLogger.debug(
                            "[\(device.name)] capabilities: plexPass=\(fetchedCapabilities.plexPassSupport.rawValue), lyrics=\(fetchedCapabilities.lyricsSupport.rawValue), radio=\(fetchedCapabilities.radioSupport.rawValue), ownerFeatures=\(fetchedCapabilities.ownerFeatures ?? "nil")"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        capabilities = nil
                        capabilityError = error.localizedDescription
                        EnsembleLogger.debug("[\(device.name)] capabilities fetch failed: \(error.localizedDescription)")
                    }

                    do {
                        let sections = try await self.client.getMusicLibrarySections(
                            for: device,
                            token: authToken,
                            allowInsecurePolicy: allowInsecurePolicy
                        )

                        var trackCountsBySectionKey: [String: Int] = [:]
                        for section in sections where section.isMusicLibrary {
                            do {
                                trackCountsBySectionKey[section.key] = try await self.client.getTrackCount(
                                    sectionKey: section.key,
                                    for: device,
                                    token: authToken,
                                    allowInsecurePolicy: allowInsecurePolicy
                                )
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                EnsembleLogger.debug("[\(device.name)] track count fetch failed for section \(section.key): \(error.localizedDescription)")
                            }
                        }

                        let libraries = sections
                            .filter(\.isMusicLibrary)
                            .map { section in
                                PlexLibraryConfig(
                                    id: section.key,
                                    key: section.key,
                                    title: section.title,
                                    isEnabled: false,
                                    allowSync: section.allowSync,
                                    trackCount: trackCountsBySectionKey[section.key]
                                )
                            }

                        return (
                            PlexServerConfig(
                                id: device.clientIdentifier,
                                name: device.name,
                                url: primaryConnection?.uri ?? "",
                                connections: connectionConfigs,
                                token: device.accessToken ?? authToken,
                                owned: device.owned,
                                platform: device.platform,
                                capabilities: capabilities,
                                libraries: libraries
                            ),
                            nil,
                            capabilityError
                        )
                    } catch is CancellationError {
                        // Navigation/task cancellation should abort discovery rather than surface
                        // as a per-server error that appears in source management UI.
                        throw CancellationError()
                    } catch {
                        let message = error.localizedDescription
                        return (
                            PlexServerConfig(
                                id: device.clientIdentifier,
                                name: device.name,
                                url: primaryConnection?.uri ?? "",
                                connections: connectionConfigs,
                                token: device.accessToken ?? authToken,
                                owned: device.owned,
                                platform: device.platform,
                                capabilities: capabilities,
                                libraries: []
                            ),
                            message,
                            capabilityError
                        )
                    }
                }
            }

            for try await (serverConfig, maybeError, maybeCapabilityError) in group {
                discoveredServers.append(serverConfig)
                if let error = maybeError {
                    serverLibraryErrors[serverConfig.id] = error
                }
                if let error = maybeCapabilityError {
                    serverCapabilityErrors[serverConfig.id] = error
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
            subscription: user.subscription,
            servers: discoveredServers,
            serverLibraryErrors: serverLibraryErrors,
            serverCapabilityErrors: serverCapabilityErrors
        )
    }
}

extension PlexAccountDiscoveryService: PlexAccountDiscoveryServiceProtocol {}
