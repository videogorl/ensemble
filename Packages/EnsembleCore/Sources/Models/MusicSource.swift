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

/// Combined sync and connection status for a music source
public struct MusicSourceStatus: Sendable, Equatable {
    public let syncStatus: SyncStatus
    public let connectionState: ServerConnectionState

    public init(syncStatus: SyncStatus = .idle, connectionState: ServerConnectionState = .unknown) {
        self.syncStatus = syncStatus
        self.connectionState = connectionState
    }

    /// Sync operation status (independent of connection state)
    public enum SyncStatus: Equatable, Sendable {
        case idle
        case syncing(progress: Double)
        case error(String)
        case lastSynced(Date)
    }

    /// Overall availability - true if both connected and not in error state
    public var isAvailable: Bool {
        connectionState.isAvailable && !syncStatus.isError
    }
}

extension MusicSourceStatus.SyncStatus {
    public var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
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
        status: MusicSourceStatus = MusicSourceStatus()
    ) {
        self.id = id
        self.displayName = displayName
        self.accountName = accountName
        self.sourceType = sourceType
        self.status = status
    }
}
