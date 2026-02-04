import Foundation

// MARK: - Plex Account Configuration (persisted as JSON in Keychain)

public struct PlexAccountConfig: Codable, Sendable, Identifiable, Equatable {
    public let id: String             // Plex user UUID or generated ID
    public let username: String
    public let authToken: String
    public let servers: [PlexServerConfig]

    public init(id: String, username: String, authToken: String, servers: [PlexServerConfig]) {
        self.id = id
        self.username = username
        self.authToken = authToken
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
    
    /// Get the best connection to try (prefer local, then non-relay, then relay)
    public var preferredConnection: PlexConnectionConfig {
        // Try local connections first
        if let local = connections.first(where: { $0.local && !($0.relay ?? false) }) {
            return local
        }
        // Then try non-relay remote connections
        if let remote = connections.first(where: { !$0.local && !($0.relay ?? false) }) {
            return remote
        }
        // Finally try relay
        if let relay = connections.first(where: { $0.relay ?? false }) {
            return relay
        }
        // Fallback to first connection or create one from URL
        return connections.first ?? PlexConnectionConfig(uri: url, local: false)
    }
    
    /// Get all connections ordered by preference
    public var orderedConnections: [PlexConnectionConfig] {
        let local = connections.filter { $0.local && !($0.relay ?? false) }
        let remote = connections.filter { !$0.local && !($0.relay ?? false) }
        let relay = connections.filter { $0.relay ?? false }
        return local + remote + relay
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
