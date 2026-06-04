import EnsembleAPI
import Foundation

// MARK: - Plex Account Configuration (persisted as JSON in Keychain)

public struct PlexAccountConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: String             // Plex user UUID or generated ID
    public let email: String?
    public let plexUsername: String?
    public let displayTitle: String?
    public let authToken: String
    public let authTokenMetadata: PlexAuthTokenMetadata?
    public let subscription: PlexSubscription?
    public let servers: [PlexServerConfig]

    /// Preferred account label for UI presentation.
    public var accountIdentifier: String {
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        if let username = plexUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username
        }
        if let title = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "Plex Account"
    }

    public init(
        id: String,
        email: String? = nil,
        plexUsername: String? = nil,
        displayTitle: String? = nil,
        authToken: String,
        authTokenMetadata: PlexAuthTokenMetadata? = nil,
        subscription: PlexSubscription? = nil,
        servers: [PlexServerConfig]
    ) {
        self.id = id
        self.email = email
        self.plexUsername = plexUsername
        self.displayTitle = displayTitle
        self.authToken = authToken
        self.authTokenMetadata = authTokenMetadata ?? PlexAuthService.tokenMetadata(from: authToken)
        self.subscription = subscription
        self.servers = servers
    }
}

public struct PlexServerConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: String             // clientIdentifier
    public let name: String
    public let url: String            // Primary connection URL
    public let connections: [PlexConnectionConfig]  // All available connections
    public let token: String
    public let owned: Bool
    public let platform: String?
    public let capabilities: PlexServerCapabilities?
    public let libraries: [PlexLibraryConfig]

    public init(
        id: String,
        name: String,
        url: String,
        connections: [PlexConnectionConfig] = [],
        token: String,
        owned: Bool = false,
        platform: String? = nil,
        capabilities: PlexServerCapabilities? = nil,
        libraries: [PlexLibraryConfig]
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.connections = connections.isEmpty ? [PlexConnectionConfig(uri: url, local: false)] : connections
        self.token = token
        self.owned = owned
        self.platform = platform
        self.capabilities = capabilities
        self.libraries = libraries
    }

    // Custom Codable implementation to handle backward compatibility
    enum CodingKeys: String, CodingKey {
        case id, name, url, connections, token, owned, platform, capabilities, libraries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        capabilities = try container.decodeIfPresent(PlexServerCapabilities.self, forKey: .capabilities)
        libraries = try container.decode([PlexLibraryConfig].self, forKey: .libraries)

        // Decode connections if present, otherwise create default from URL
        if let decodedConnections = try container.decodeIfPresent([PlexConnectionConfig].self, forKey: .connections),
           !decodedConnections.isEmpty {
            connections = decodedConnections
        } else {
            // Backward compatibility: create a default connection from the URL
            connections = [PlexConnectionConfig(uri: url, local: false)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(connections, forKey: .connections)
        try container.encode(token, forKey: .token)
        try container.encode(owned, forKey: .owned)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encode(libraries, forKey: .libraries)
    }
    
    /// Get the best connection using local-first secure routing.
    public var preferredConnection: PlexConnectionConfig {
        orderedConnections.first ?? PlexConnectionConfig(uri: url, local: false)
    }
    
    /// Get all connections ordered by preference:
    /// local secure -> remote secure -> local insecure -> remote insecure -> relay.
    public var orderedConnections: [PlexConnectionConfig] {
        connections.enumerated().sorted { lhs, rhs in
            let lClass = connectionClass(lhs.element)
            let rClass = connectionClass(rhs.element)
            if lClass == rClass {
                return lhs.offset < rhs.offset
            }
            return lClass.rawValue < rClass.rawValue
        }.map(\.element)
    }

    private enum ConnectionClass: Int {
        case localSecure = 0
        case remoteSecure = 1
        case localInsecure = 2
        case remoteInsecure = 3
        case relay = 4
    }

    private func connectionClass(_ connection: PlexConnectionConfig) -> ConnectionClass {
        if connection.relay ?? false {
            return .relay
        }
        let isSecure = connection.protocol == "https" || connection.uri.lowercased().hasPrefix("https://")
        if isSecure && connection.local {
            return .localSecure
        }
        if isSecure && !connection.local {
            return .remoteSecure
        }
        if !isSecure && connection.local {
            return .localInsecure
        }
        return .remoteInsecure
    }
}

public struct PlexConnectionConfig: Codable, Sendable, Equatable {
    public let uri: String
    public let local: Bool
    public let relay: Bool?
    public let address: String?
    public let port: Int?
    public let `protocol`: String?
    
    public init(
        uri: String,
        local: Bool,
        relay: Bool? = nil,
        address: String? = nil,
        port: Int? = nil,
        protocol: String? = nil
    ) {
        self.uri = uri
        self.local = local
        self.relay = relay
        self.address = address
        self.port = port
        self.protocol = `protocol`
    }
}

public struct PlexLibraryConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: String             // section key
    public let key: String
    public let title: String
    public var isEnabled: Bool
    public let allowSync: Bool?
    public let trackCount: Int?

    public init(
        id: String,
        key: String,
        title: String,
        isEnabled: Bool = true,
        allowSync: Bool? = nil,
        trackCount: Int? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.isEnabled = isEnabled
        self.allowSync = allowSync
        self.trackCount = trackCount
    }
}

// MARK: - Syncable Account Credential (iCloud Keychain)

/// Lightweight account credential for iCloud Keychain sync.
/// Strips connection details (IPs/URLs are device-specific); each device
/// discovers its own connections via the Plex resources API.
public struct SyncableAccountCredential: Codable, Equatable, Sendable {
    public let accountId: String
    public let email: String?
    public let plexUsername: String?
    public let displayTitle: String?
    public let authToken: String
    public let servers: [SyncableServerCredential]

    public init(
        accountId: String,
        email: String?,
        plexUsername: String?,
        displayTitle: String?,
        authToken: String,
        servers: [SyncableServerCredential]
    ) {
        self.accountId = accountId
        self.email = email
        self.plexUsername = plexUsername
        self.displayTitle = displayTitle
        self.authToken = authToken
        self.servers = servers
    }

    public init(from account: PlexAccountConfig) {
        self.accountId = account.id
        self.email = account.email
        self.plexUsername = account.plexUsername
        self.displayTitle = account.displayTitle
        self.authToken = account.authToken
        self.servers = account.servers.map { SyncableServerCredential(from: $0) }
    }
}

/// Lightweight server credential for sync — no connections or capabilities.
public struct SyncableServerCredential: Codable, Equatable, Sendable {
    public let serverId: String
    public let serverName: String
    public let serverToken: String
    public let libraries: [SyncableLibraryRef]

    public init(
        serverId: String,
        serverName: String,
        serverToken: String,
        libraries: [SyncableLibraryRef]
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.serverToken = serverToken
        self.libraries = libraries
    }

    public init(from server: PlexServerConfig) {
        self.serverId = server.id
        self.serverName = server.name
        self.serverToken = server.token
        self.libraries = server.libraries.map { SyncableLibraryRef(from: $0) }
    }
}

/// Lightweight library reference for sync — just identity + enabled state.
public struct SyncableLibraryRef: Codable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let title: String
    public let isEnabled: Bool

    public init(id: String, key: String, title: String, isEnabled: Bool) {
        self.id = id
        self.key = key
        self.title = title
        self.isEnabled = isEnabled
    }

    public init(from library: PlexLibraryConfig) {
        self.id = library.id
        self.key = library.key
        self.title = library.title
        self.isEnabled = library.isEnabled
    }
}
