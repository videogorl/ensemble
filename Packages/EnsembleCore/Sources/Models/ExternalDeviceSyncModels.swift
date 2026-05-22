import EnsemblePersistence
import Foundation

public enum ExternalDeviceSupportState: Equatable, Sendable {
    case supported
    case unsupported(String)
}

public struct ExternalDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let modelIdentifier: String?
    public let mountPath: String?
    public let totalCapacity: Int64
    public let freeCapacity: Int64
    public let supportState: ExternalDeviceSupportState
    public let automaticSyncEnabled: Bool
    public let lastSeenAt: Date?
    public let lastSyncAt: Date?

    public init(record: ExternalDeviceRecord) {
        id = record.id
        name = record.displayName
        modelIdentifier = record.modelIdentifier
        mountPath = record.mountPath
        totalCapacity = record.totalCapacity
        freeCapacity = record.freeCapacity
        supportState = record.isSupported ? .supported : .unsupported(record.supportMessage ?? "Unsupported iPod")
        automaticSyncEnabled = record.automaticSyncEnabled
        lastSeenAt = record.lastSeenAt
        lastSyncAt = record.lastSyncAt
    }
}

public struct IPodDeviceSnapshot: Equatable, Sendable {
    public let deviceID: String
    public let name: String
    public let modelIdentifier: String?
    public let mountURL: URL
    public let totalCapacity: Int64
    public let freeCapacity: Int64
    public let supportState: ExternalDeviceSupportState

    public init(
        deviceID: String,
        name: String,
        modelIdentifier: String?,
        mountURL: URL,
        totalCapacity: Int64,
        freeCapacity: Int64,
        supportState: ExternalDeviceSupportState
    ) {
        self.deviceID = deviceID
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.mountURL = mountURL
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.supportState = supportState
    }
}

public struct IPodTrackSnapshot: Equatable, Sendable {
    public let persistentID: String
    public let filePath: String?
    public let title: String
    public let ratingStars: Int
    public let totalPlayCount: Int
    public let recentPlayCount: Int
    public let lastPlayed: Date?

    public init(
        persistentID: String,
        filePath: String?,
        title: String,
        ratingStars: Int,
        totalPlayCount: Int,
        recentPlayCount: Int,
        lastPlayed: Date?
    ) {
        self.persistentID = persistentID
        self.filePath = filePath
        self.title = title
        self.ratingStars = ratingStars
        self.totalPlayCount = totalPlayCount
        self.recentPlayCount = recentPlayCount
        self.lastPlayed = lastPlayed
    }
}

public struct IPodPlaylistSnapshot: Equatable, Sendable {
    public let persistentID: String
    public let name: String
    public let trackPersistentIDs: [String]
    public let isOnTheGo: Bool

    public init(
        persistentID: String,
        name: String,
        trackPersistentIDs: [String],
        isOnTheGo: Bool
    ) {
        self.persistentID = persistentID
        self.name = name
        self.trackPersistentIDs = trackPersistentIDs
        self.isOnTheGo = isOnTheGo
    }
}

public struct IPodLibrarySnapshot: Equatable, Sendable {
    public let device: IPodDeviceSnapshot
    public let tracks: [IPodTrackSnapshot]
    public let playlists: [IPodPlaylistSnapshot]

    public init(
        device: IPodDeviceSnapshot,
        tracks: [IPodTrackSnapshot],
        playlists: [IPodPlaylistSnapshot]
    ) {
        self.device = device
        self.tracks = tracks
        self.playlists = playlists
    }
}

public struct ExternalDeviceImportPlan: Equatable, Sendable {
    public struct RatingUpdate: Equatable, Sendable {
        public let mapID: String
        public let trackRatingKey: String
        public let sourceCompositeKey: String
        public let plexRating: Int
        public let checkpointRating: Int
    }

    public struct PlayDelta: Equatable, Sendable {
        public let mapID: String
        public let trackRatingKey: String
        public let sourceCompositeKey: String
        public let delta: Int
        public let checkpointPlayCount: Int
    }

    public struct PlaylistUpdate: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            case updateExisting(playlistRatingKey: String, sourceCompositeKey: String)
            case create(title: String, sourceCompositeKey: String)
        }

        public let playlistPersistentID: String
        public let action: Action
        public let trackReferences: [ExternalDeviceTrackReference]
    }

    public let ratingUpdates: [RatingUpdate]
    public let playDeltas: [PlayDelta]
    public let playlistUpdates: [PlaylistUpdate]
    public let discardedItemCount: Int
}

public struct ExternalDeviceTrackReference: Equatable, Sendable {
    public let ratingKey: String
    public let sourceCompositeKey: String
}

public struct ExternalDeviceSyncSummary: Equatable, Sendable {
    public let status: String
    public let importedRatings: Int
    public let importedPlays: Int
    public let importedPlaylists: Int
    public let exportedTracks: Int
    public let exportedPlaylists: Int
    public let discardedItems: Int
    public let message: String?

    public init(
        status: String,
        importedRatings: Int = 0,
        importedPlays: Int = 0,
        importedPlaylists: Int = 0,
        exportedTracks: Int = 0,
        exportedPlaylists: Int = 0,
        discardedItems: Int = 0,
        message: String? = nil
    ) {
        self.status = status
        self.importedRatings = importedRatings
        self.importedPlays = importedPlays
        self.importedPlaylists = importedPlaylists
        self.exportedTracks = exportedTracks
        self.exportedPlaylists = exportedPlaylists
        self.discardedItems = discardedItems
        self.message = message
    }
}
