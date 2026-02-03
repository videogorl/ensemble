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
    public let url: String
    public let token: String
    public let platform: String?
    public let libraries: [PlexLibraryConfig]

    public init(id: String, name: String, url: String, token: String, platform: String? = nil, libraries: [PlexLibraryConfig]) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
        self.platform = platform
        self.libraries = libraries
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
