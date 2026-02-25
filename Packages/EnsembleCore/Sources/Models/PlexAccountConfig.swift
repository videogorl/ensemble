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
        servers: [PlexServerConfig]
    ) {
        self.id = id
        self.email = email
        self.plexUsername = plexUsername
        self.displayTitle = displayTitle
        self.authToken = authToken
        self.authTokenMetadata = authTokenMetadata ?? PlexAuthService.tokenMetadata(from: authToken)
        self.servers = servers
    }
}

public struct PlexServerConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: String             // clientIdentifier
    public let name: String
    public let url: String            // Primary connection URL
    public let connections: [PlexConnectionConfig]  // All available connections
    public let token: String
    public let platform: String?
    public let libraries: [PlexLibraryConfig]

    public init(
        id: String,
        name: String,
        url: String,
        connections: [PlexConnectionConfig] = [],
        token: String,
        platform: String? = nil,
        libraries: [PlexLibraryConfig]
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.connections = connections.isEmpty ? [PlexConnectionConfig(uri: url, local: false)] : connections
        self.token = token
        self.platform = platform
        self.libraries = libraries
    }
    
    // Custom Codable implementation to handle backward compatibility
    enum CodingKeys: String, CodingKey {
        case id, name, url, connections, token, platform, libraries
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
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
        try container.encodeIfPresent(platform, forKey: .platform)
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

    public init(id: String, key: String, title: String, isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.title = title
        self.isEnabled = isEnabled
    }
}
