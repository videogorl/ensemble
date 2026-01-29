import CoreData
import Foundation

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
    @NSManaged public var updatedAt: Date?
    @NSManaged public var server: CDServer?
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
    @NSManaged public var summary: String?
    @NSManaged public var thumbPath: String?
    @NSManaged public var artPath: String?
    @NSManaged public var year: Int32
    @NSManaged public var trackCount: Int32
    @NSManaged public var updatedAt: Date?
    @NSManaged public var artist: CDArtist?
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
    @NSManaged public var updatedAt: Date?
    @NSManaged public var album: CDAlbum?
    @NSManaged public var download: CDDownload?
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
    @NSManaged public var updatedAt: Date?
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
    @NSManaged public var filePath: String?
    @NSManaged public var fileSize: Int64
    @NSManaged public var startedAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var error: String?
    @NSManaged public var track: CDTrack?
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
}

extension CDGenre {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDGenre> {
        return NSFetchRequest<CDGenre>(entityName: "CDGenre")
    }
}
