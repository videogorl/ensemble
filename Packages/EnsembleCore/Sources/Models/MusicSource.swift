import Foundation

// MARK: - Music Source Type

public enum MusicSourceType: String, Codable, Sendable, CaseIterable {
    case plex
    // case appleMusic  // Future
}

// MARK: - Music Source Identifier

public struct MusicSourceIdentifier: Hashable, Codable, Sendable, Identifiable {
    public let type: MusicSourceType
    public let accountId: String
    public let serverId: String
    public let libraryId: String

    public var id: String { compositeKey }

    /// A stable compound key for CoreData scoping and provider routing
    public var compositeKey: String {
        "\(type.rawValue):\(accountId):\(serverId):\(libraryId)"
    }

    public init(type: MusicSourceType, accountId: String, serverId: String, libraryId: String) {
        self.type = type
        self.accountId = accountId
        self.serverId = serverId
        self.libraryId = libraryId
    }
}

// MARK: - Music Source Status

public enum MusicSourceStatus: Sendable {
    case idle
    case syncing(progress: Double)
    case error(String)
    case lastSynced(Date)
}

// MARK: - Music Source

public struct MusicSource: Identifiable, Sendable {
    public let id: MusicSourceIdentifier
    public let displayName: String
    public let accountName: String
    public let sourceType: MusicSourceType
    public var status: MusicSourceStatus

    public init(
        id: MusicSourceIdentifier,
        displayName: String,
        accountName: String,
        sourceType: MusicSourceType,
        status: MusicSourceStatus = .idle
    ) {
        self.id = id
        self.displayName = displayName
        self.accountName = accountName
        self.sourceType = sourceType
        self.status = status
    }
}
