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

public protocol PlexAccountDiscoveryServiceProtocol: Sendable {
    func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult
}

// Used internally to fan-out concurrent user+resources discovery without async let,
// which causes Swift runtime crashes in protocol witness cleanup on certain OS versions.
private enum DiscoveryInitialResult: Sendable {
    case user(PlexUser)
    case devices([PlexDevice])
}

/// Discovers account identity, servers, and music libraries for Plex account setup and management.
public final class PlexAccountDiscoveryService: Sendable {
    private let urlSession: URLSession?
    private let allowInsecurePolicyProvider: @Sendable () -> AllowInsecureConnectionsPolicy

    public init(
        urlSession: URLSession? = nil,
        allowInsecurePolicyProvider: @escaping @Sendable () -> AllowInsecureConnectionsPolicy = {
            AllowInsecureConnectionsPolicy.storedPreference()
        }
    ) {
        self.urlSession = urlSession
        self.allowInsecurePolicyProvider = allowInsecurePolicyProvider
    }

    public func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult {
        // Fetch user info and Plex resources concurrently. We use withThrowingTaskGroup
        // instead of `async let` because `async let` in a protocol witness thunk can cause
        // a Swift runtime abort during async-let cleanup when one task throws or the parent
        // task is cancelled (repro: asyncLet_finish_after_task_completion crash on iOS 26 beta).
        let accountClient = PlexAPIClient(
            connection: PlexServerConnection(url: "https://plex.tv", token: authToken, identifier: "plex-tv", name: "plex-tv"),
            urlSession: urlSession
        )
        let (user, devices) = try await withThrowingTaskGroup(of: DiscoveryInitialResult.self) { group in
            group.addTask { .user(try await accountClient.getUserInfo(token: authToken)) }
            group.addTask { .devices(try await accountClient.getResources(token: authToken)) }

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

        try Task.checkCancellation()
        let allowInsecurePolicy = allowInsecurePolicyProvider()

        var discoveredServers: [PlexServerConfig] = []
        var serverLibraryErrors: [String: String] = [:]
        var serverCapabilityErrors: [String: String] = [:]

        try await withThrowingTaskGroup(of: (PlexServerConfig, libraryError: String?, capabilityError: String?).self) { group in
            for device in devices {
                group.addTask {
                    try Task.checkCancellation()
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

                    var capabilities: PlexServerCapabilities?
                    var capabilityError: String?
                    do {
                        guard let primaryConnection else { throw PlexAPIError.noServerSelected }
                        let endpoints = fallbackConnections.map {
                            PlexEndpointDescriptor(url: $0.uri, local: $0.local, relay: $0.relay ?? false, secure: $0.protocol == "https")
                        }
                        let client = PlexAPIClient(
                            connection: PlexServerConnection(
                                url: primaryConnection.uri,
                                alternativeURLs: endpoints.map(\.url).filter { $0 != primaryConnection.uri },
                                endpoints: endpoints,
                                selectionPolicy: .plexSpecBalanced,
                                allowInsecurePolicy: allowInsecurePolicy,
                                token: device.accessToken ?? authToken,
                                identifier: device.clientIdentifier,
                                name: device.name
                            ),
                            probeURLSession: self.urlSession,
                            urlSession: self.urlSession
                        )
                        // Selection must succeed before any metadata request, including when
                        // the configured primary endpoint is disallowed by the user's policy.
                        _ = try await client.refreshConnection()
                        try Task.checkCancellation()
                        do {
                            capabilities = try await client.getServerCapabilities()
                        } catch {
                            try Task.checkCancellation()
                            if PlexErrorClassification.classify(error) == .cancelled { throw CancellationError() }
                            capabilityError = error.localizedDescription
                            EnsembleLogger.debug("[\(device.name)] capabilities fetch failed: \(error.localizedDescription)")
                        }

                        try Task.checkCancellation()
                        let sections = try await client.getMusicLibrarySections()
                        try Task.checkCancellation()

                        var trackCountsBySectionKey: [String: Int] = [:]
                        for section in sections {
                            do {
                                try Task.checkCancellation()
                                trackCountsBySectionKey[section.key] = try await client.getTrackCount(sectionKey: section.key)
                            } catch {
                                try Task.checkCancellation()
                                if PlexErrorClassification.classify(error) == .cancelled { throw CancellationError() }
                                EnsembleLogger.debug("[\(device.name)] track count fetch failed for section \(section.key): \(error.localizedDescription)")
                            }
                        }

                        try Task.checkCancellation()
                        let libraries = sections
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
                                url: primaryConnection.uri,
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
                    } catch {
                        try Task.checkCancellation()
                        if PlexErrorClassification.classify(error) == .cancelled { throw CancellationError() }
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

        try Task.checkCancellation()
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
