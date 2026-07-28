import Foundation

// MARK: - Music Source Type

public enum MusicSourceType: String, Codable, Sendable, CaseIterable {
    case plex
    case appleMusic
}

/// Source-routing failures that are independent of any provider API.
public enum MusicSourceRoutingError: LocalizedError, Equatable, Sendable {
    case invalidSourceKey(String?)
    case providerUnavailable(sourceKey: String)
    case capabilityUnavailable(sourceKey: String, capability: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceKey:
            return "The music source is invalid."
        case .providerUnavailable:
            return "The music source is unavailable."
        case .capabilityUnavailable(_, let capability):
            return "This music source doesn’t support \(capability)."
        }
    }
}

/// Provider behavior and copy consumed by shared UI surfaces.
/// Adding a source should require one entry here, not source checks throughout the UI.
public struct MusicSourceCapabilities: Sendable, Equatable {
    public let displayName: String
    public let defaultLibraryName: String
    public let requiresServerConnection: Bool
    public let supportsWaveform: Bool
    public let supportsLyrics: Bool
    public let lyricsUnavailableMessage: String?
    public let lyricsStatusDescription: String?
    public let managedPlaybackQualityDescription: String?
    public let supportsAudioFileInfo: Bool
    public let supportsInstrumentalMode: Bool
    public let supportsAudioFileSharing: Bool
    public let supportsMetadataEditing: Bool
    public let supportsTrackDeletion: Bool
    public let supportsFavoriteRemoval: Bool
    public let supportsCatalogLibraryAdds: Bool
    /// Whether provider-owned Feed items remain actionable without a matching local library row.
    public let retainsHubItemsWithoutLocalCache: Bool
    public let smartMixCrossSourceNotice: String?
}

public extension MusicSourceType {
    var capabilities: MusicSourceCapabilities {
        switch self {
        case .plex:
            MusicSourceCapabilities(
                displayName: "Plex",
                defaultLibraryName: "Library",
                requiresServerConnection: true,
                supportsWaveform: true,
                supportsLyrics: true,
                lyricsUnavailableMessage: nil,
                lyricsStatusDescription: nil,
                managedPlaybackQualityDescription: nil,
                supportsAudioFileInfo: true,
                supportsInstrumentalMode: true,
                supportsAudioFileSharing: true,
                supportsMetadataEditing: true,
                supportsTrackDeletion: true,
                supportsFavoriteRemoval: true,
                supportsCatalogLibraryAdds: false,
                retainsHubItemsWithoutLocalCache: false,
                smartMixCrossSourceNotice: nil
            )
        case .appleMusic:
            MusicSourceCapabilities(
                displayName: "Apple Music",
                defaultLibraryName: "Apple Music",
                requiresServerConnection: false,
                supportsWaveform: false,
                supportsLyrics: false,
                lyricsUnavailableMessage: "Lyrics aren’t supported for Apple Music tracks in Ensemble.",
                lyricsStatusDescription: "Not Supported",
                managedPlaybackQualityDescription: "Managed by Apple Music",
                supportsAudioFileInfo: false,
                supportsInstrumentalMode: false,
                supportsAudioFileSharing: false,
                supportsMetadataEditing: false,
                supportsTrackDeletion: false,
                supportsFavoriteRemoval: false,
                supportsCatalogLibraryAdds: true,
                retainsHubItemsWithoutLocalCache: true,
                smartMixCrossSourceNotice: "SmartMix cannot transition between songs from Apple Music and other services"
            )
        }
    }
}

/// Resolved names and capabilities for one configured source.
public struct MusicSourcePresentation: Sendable, Equatable {
    public let capabilities: MusicSourceCapabilities
    public let serverName: String
    public let libraryName: String
    public let accountName: String

    public init(capabilities: MusicSourceCapabilities, serverName: String, libraryName: String, accountName: String) {
        self.capabilities = capabilities
        self.serverName = serverName
        self.libraryName = libraryName
        self.accountName = accountName
    }
}

// MARK: - Music Source Identifier

public struct MusicSourceIdentifier: Hashable, Codable, Sendable, Identifiable {
    public static let appleMusic = MusicSourceIdentifier(
        type: .appleMusic,
        accountId: "device",
        serverId: "system",
        libraryId: "library"
    )

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

    public init?(compositeKey: String) {
        guard let identity = MediaSourceIdentity.parse(compositeKey),
              let libraryId = identity.libraryId else {
            return nil
        }
        self.init(
            type: identity.sourceType,
            accountId: identity.accountId,
            serverId: identity.serverId,
            libraryId: libraryId
        )
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

public extension Track {
    var sourceType: MusicSourceType? {
        sourceCompositeKey.flatMap(MusicSourceIdentifier.init(compositeKey:))?.type
    }

    var isAppleMusic: Bool { sourceType == .appleMusic }

    var sourceCapabilities: MusicSourceCapabilities {
        (sourceType ?? .plex).capabilities
    }

    /// Catalog results use a catalog key. Library-backed results use a distinct key,
    /// even when Apple also supplies a catalog identifier.
    var canAddToSourceLibrary: Bool {
        sourceCapabilities.supportsCatalogLibraryAdds && key == "apple-catalog"
    }

    var appleMusicCatalogID: String? {
        if key == "apple-catalog" || key == "apple-catalog-library" { return id }
        if key.hasPrefix("apple-library-catalog:") {
            let value = String(key.dropFirst("apple-library-catalog:".count))
            return value.isEmpty ? nil : value
        }
        guard key.hasPrefix("apple-library:") else { return nil }
        let value = String(key.dropFirst("apple-library:".count))
        return value.isEmpty || value == id ? nil : value
    }

    var appleMusicLibraryID: String? {
        guard key.hasPrefix("apple-library:") || key.hasPrefix("apple-library-catalog:") else {
            return nil
        }
        return id.isEmpty ? nil : id
    }

    internal var appleMusicPlaybackIdentifier: AppleMusicPlaybackIdentifier? {
        if let catalogID = appleMusicCatalogID { return .catalog(catalogID) }
        if let libraryID = appleMusicLibraryID { return .library(libraryID) }
        return nil
    }
}

enum AppleMusicPlaybackIdentifier: Equatable {
    case catalog(String)
    case library(String)
}
