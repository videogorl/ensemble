import CoreData
import Foundation

// MARK: - CDMusicSource

@objc(CDMusicSource)
public class CDMusicSource: NSManagedObject {
    @NSManaged public var compositeKey: String
    @NSManaged public var type: String
    @NSManaged public var accountId: String
    @NSManaged public var serverId: String
    @NSManaged public var libraryId: String
    @NSManaged public var displayName: String?
    @NSManaged public var accountName: String?
    @NSManaged public var lastSyncedAt: Date?
    @NSManaged public var artists: NSSet?
    @NSManaged public var albums: NSSet?
    @NSManaged public var tracks: NSSet?
    @NSManaged public var genres: NSSet?
    @NSManaged public var playlists: NSSet?
}

extension CDMusicSource {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDMusicSource> {
        return NSFetchRequest<CDMusicSource>(entityName: "CDMusicSource")
    }
}

// MARK: - CDServer

@objc(CDServer)
public class CDServer: NSManagedObject {
    @NSManaged public var clientIdentifier: String
    @NSManaged public var name: String
    @NSManaged public var url: String
    @NSManaged public var accessToken: String?
    @NSManaged public var platform: String?
    @NSManaged public var artists: NSSet?
}

extension CDServer {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDServer> {
        return NSFetchRequest<CDServer>(entityName: "CDServer")
    }
}

// MARK: - CDArtist

@objc(CDArtist)
public class CDArtist: NSManagedObject {
    @NSManaged public var ratingKey: String
    @NSManaged public var key: String
    @NSManaged public var name: String
    @NSManaged public var summary: String?
    @NSManaged public var thumbPath: String?
    @NSManaged public var artPath: String?
    @NSManaged public var dateAdded: Date?
    @NSManaged public var dateModified: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var server: CDServer?
    @NSManaged public var source: CDMusicSource?
    @NSManaged public var albums: NSSet?
}

extension CDArtist {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDArtist> {
        return NSFetchRequest<CDArtist>(entityName: "CDArtist")
    }

    public var albumsArray: [CDAlbum] {
        let set = albums as? Set<CDAlbum> ?? []
        return set.sorted { ($0.year) > ($1.year) }
    }
}

// MARK: - CDAlbum

@objc(CDAlbum)
public class CDAlbum: NSManagedObject {
    @NSManaged public var ratingKey: String
    @NSManaged public var key: String
    @NSManaged public var title: String
    @NSManaged public var artistName: String?
    @NSManaged public var albumArtist: String?
    @NSManaged public var summary: String?
    @NSManaged public var thumbPath: String?
    @NSManaged public var artPath: String?
    @NSManaged public var year: Int32
    @NSManaged public var trackCount: Int32
    @NSManaged public var dateAdded: Date?
    @NSManaged public var dateModified: Date?
    @NSManaged public var rating: Int16
    @NSManaged public var updatedAt: Date?
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var artist: CDArtist?
    @NSManaged public var source: CDMusicSource?
    @NSManaged public var tracks: NSSet?
}

extension CDAlbum {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDAlbum> {
        return NSFetchRequest<CDAlbum>(entityName: "CDAlbum")
    }

    public var tracksArray: [CDTrack] {
        let set = tracks as? Set<CDTrack> ?? []
        return set.sorted {
            if $0.discNumber != $1.discNumber {
                return $0.discNumber < $1.discNumber
            }
            return $0.trackNumber < $1.trackNumber
        }
    }
}

// MARK: - CDTrack

@objc(CDTrack)
public class CDTrack: NSManagedObject {
    @NSManaged public var ratingKey: String
    @NSManaged public var key: String
    @NSManaged public var title: String
    @NSManaged public var artistName: String?
    @NSManaged public var albumName: String?
    @NSManaged public var trackNumber: Int32
    @NSManaged public var discNumber: Int32
    @NSManaged public var duration: Int64  // Milliseconds
    @NSManaged public var thumbPath: String?
    @NSManaged public var streamKey: String?
    @NSManaged public var localFilePath: String?
    @NSManaged public var dateAdded: Date?
    @NSManaged public var dateModified: Date?
    @NSManaged public var lastPlayed: Date?
    @NSManaged public var rating: Int16
    @NSManaged public var playCount: Int32
    @NSManaged public var updatedAt: Date?
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var album: CDAlbum?
    @NSManaged public var source: CDMusicSource?
    @NSManaged public var download: CDDownload?
    @NSManaged public var offlineMemberships: NSSet?
    @NSManaged public var playlistTracks: NSSet?
}

extension CDTrack {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDTrack> {
        return NSFetchRequest<CDTrack>(entityName: "CDTrack")
    }

    public var durationSeconds: TimeInterval {
        TimeInterval(duration) / 1000.0
    }

    public var isDownloaded: Bool {
        localFilePath != nil
    }
}

// MARK: - CDPlaylist

@objc(CDPlaylist)
public class CDPlaylist: NSManagedObject {
    @NSManaged public var ratingKey: String
    @NSManaged public var key: String
    @NSManaged public var title: String
    @NSManaged public var summary: String?
    @NSManaged public var compositePath: String?
    @NSManaged public var isSmart: Bool
    @NSManaged public var duration: Int64
    @NSManaged public var trackCount: Int32
    @NSManaged public var dateAdded: Date?
    @NSManaged public var dateModified: Date?
    @NSManaged public var lastPlayed: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var source: CDMusicSource?
    @NSManaged public var playlistTracks: NSSet?
}

extension CDPlaylist {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPlaylist> {
        return NSFetchRequest<CDPlaylist>(entityName: "CDPlaylist")
    }

    public var tracksArray: [CDTrack] {
        let set = playlistTracks as? Set<CDPlaylistTrack> ?? []
        return set.sorted { $0.order < $1.order }.compactMap { $0.track }
    }
}

// MARK: - CDPlaylistTrack

@objc(CDPlaylistTrack)
public class CDPlaylistTrack: NSManagedObject {
    @NSManaged public var order: Int32
    @NSManaged public var playlist: CDPlaylist?
    @NSManaged public var track: CDTrack?
}

extension CDPlaylistTrack {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPlaylistTrack> {
        return NSFetchRequest<CDPlaylistTrack>(entityName: "CDPlaylistTrack")
    }
}

// MARK: - CDDownload

@objc(CDDownload)
public class CDDownload: NSManagedObject {
    @NSManaged public var status: String?
    @NSManaged public var progress: Float
    @NSManaged public var quality: String?
    @NSManaged public var filePath: String?
    @NSManaged public var fileSize: Int64
    @NSManaged public var startedAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var error: String?
    @NSManaged public var track: CDTrack?
}

// MARK: - CDOfflineDownloadTarget

@objc(CDOfflineDownloadTarget)
public class CDOfflineDownloadTarget: NSManagedObject {
    @NSManaged public var key: String
    @NSManaged public var kind: String
    @NSManaged public var ratingKey: String?
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var displayName: String?
    @NSManaged public var status: String?
    @NSManaged public var totalTrackCount: Int32
    @NSManaged public var completedTrackCount: Int32
    @NSManaged public var progress: Float
    @NSManaged public var lastError: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var memberships: NSSet?
}

extension CDOfflineDownloadTarget {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDOfflineDownloadTarget> {
        return NSFetchRequest<CDOfflineDownloadTarget>(entityName: "CDOfflineDownloadTarget")
    }

    public enum Kind: String {
        case library
        case album
        case artist
        case playlist
    }

    public enum Status: String {
        case pending
        case downloading
        case completed
        case paused
        case failed
    }

    public var membershipArray: [CDOfflineDownloadMembership] {
        let set = memberships as? Set<CDOfflineDownloadMembership> ?? []
        return set.sorted { $0.id < $1.id }
    }

    public var targetKind: Kind {
        get { Kind(rawValue: kind) ?? .library }
        set { kind = newValue.rawValue }
    }

    public var targetStatus: Status {
        get { Status(rawValue: status ?? "") ?? .pending }
        set { status = newValue.rawValue }
    }
}

// MARK: - CDOfflineDownloadMembership

@objc(CDOfflineDownloadMembership)
public class CDOfflineDownloadMembership: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var targetKey: String
    @NSManaged public var trackRatingKey: String
    @NSManaged public var trackSourceCompositeKey: String
    @NSManaged public var createdAt: Date?
    @NSManaged public var target: CDOfflineDownloadTarget?
    @NSManaged public var track: CDTrack?
}

extension CDOfflineDownloadMembership {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDOfflineDownloadMembership> {
        return NSFetchRequest<CDOfflineDownloadMembership>(entityName: "CDOfflineDownloadMembership")
    }
}

extension CDDownload {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDDownload> {
        return NSFetchRequest<CDDownload>(entityName: "CDDownload")
    }

    public enum Status: String {
        case pending
        case downloading
        case completed
        case failed
        case paused
    }

    public var downloadStatus: Status {
        get { Status(rawValue: status ?? "") ?? .pending }
        set { status = newValue.rawValue }
    }
}

// MARK: - CDGenre

@objc(CDGenre)
public class CDGenre: NSManagedObject {
    @NSManaged public var ratingKey: String?
    @NSManaged public var key: String
    @NSManaged public var title: String
    @NSManaged public var sourceCompositeKey: String?
    @NSManaged public var source: CDMusicSource?
}

extension CDGenre {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDGenre> {
        return NSFetchRequest<CDGenre>(entityName: "CDGenre")
    }
}

// MARK: - CDMood

@objc(CDMood)
public class CDMood: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var key: String
    @NSManaged public var title: String
    @NSManaged public var sourceCompositeKey: String?
}

extension CDMood {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDMood> {
        return NSFetchRequest<CDMood>(entityName: "CDMood")
    }
}

// MARK: - CDHub

@objc(CDHub)
public class CDHub: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var title: String
    @NSManaged public var type: String
    @NSManaged public var order: Int16
    @NSManaged public var items: NSOrderedSet?
}

extension CDHub {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDHub> {
        return NSFetchRequest<CDHub>(entityName: "CDHub")
    }

    public var itemsArray: [CDHubItem] {
        return items?.array as? [CDHubItem] ?? []
    }
}

// MARK: - CDHubItem

@objc(CDHubItem)
public class CDHubItem: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var type: String
    @NSManaged public var title: String
    @NSManaged public var subtitle: String?
    @NSManaged public var thumbPath: String?
    @NSManaged public var sourceCompositeKey: String
    @NSManaged public var order: Int16
    @NSManaged public var hub: CDHub?
}

extension CDHubItem {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDHubItem> {
        return NSFetchRequest<CDHubItem>(entityName: "CDHubItem")
    }
}

// MARK: - CDPendingMutation

/// Persisted record for a server-side mutation that couldn't be sent while offline.
/// Drained automatically when the device reconnects.
@objc(CDPendingMutation)
public class CDPendingMutation: NSManagedObject {
    @NSManaged public var id: String
    @NSManaged public var type: String
    @NSManaged public var payload: Data
    @NSManaged public var createdAt: Date
    @NSManaged public var retryCount: Int16
    @NSManaged public var status: String
    @NSManaged public var sourceCompositeKey: String?
}

extension CDPendingMutation {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPendingMutation> {
        return NSFetchRequest<CDPendingMutation>(entityName: "CDPendingMutation")
    }

    public enum MutationType: String {
        case trackRating
        case playlistAdd
        case playlistRemove
    }

    public enum MutationStatus: String {
        case pending
        case failed
    }

    public var mutationType: MutationType {
        get { MutationType(rawValue: type) ?? .trackRating }
        set { type = newValue.rawValue }
    }

    public var mutationStatus: MutationStatus {
        get { MutationStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }
}
