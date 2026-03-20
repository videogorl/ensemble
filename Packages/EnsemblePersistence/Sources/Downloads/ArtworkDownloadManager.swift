import CoreData
import Foundation

public enum ArtworkDownloadError: Error, LocalizedError {
    case noArtworkPath
    case downloadFailed(Error)
    case fileSystemError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noArtworkPath:
            return "No artwork path available"
        case .downloadFailed(let error):
            return "Artwork download failed: \(error.localizedDescription)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        }
    }
}

public enum ArtworkType {
    case album
    case artist
    case track
    case playlist
}

public protocol ArtworkDownloadManagerProtocol: Sendable {
    func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int
    func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int
    func getLocalArtworkPath(for album: CDAlbum) async throws -> String?
    func getLocalArtworkPath(for artist: CDArtist) async throws -> String?
    func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String?
    func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws
    func deleteArtwork(ratingKey: String, type: ArtworkType)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>)
    func clearArtworkCache() async throws
    func getArtworkCacheSize() async throws -> Int64
}

public final class ArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let session: URLSession
    
    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    /// Directory for storing cached artwork
    public static var artworkDirectory: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let artworkURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: artworkURL.path) {
            try? FileManager.default.createDirectory(at: artworkURL, withIntermediateDirectories: true)
        }
        
        return artworkURL
    }
    
    // MARK: - Album Artwork
    
    /// Pre-download artwork for albums
    /// Note: This is a placeholder - actual downloading should be done via downloadAndCacheArtwork(from:ratingKey:type:)
    /// which requires resolved URLs from the sync coordinator
    public func predownloadArtwork(for albums: [CDAlbum], size: Int = 500) async throws -> Int {
        // Deprecated - use downloadAndCacheArtwork(from:ratingKey:type:) directly from SyncCoordinator
        return 0
    }
    
    public func getLocalArtworkPath(for album: CDAlbum) async throws -> String? {
        let ratingKey = album.ratingKey
        let filename = "\(ratingKey)_album.jpg"
        let localPath = Self.artworkDirectory.appendingPathComponent(filename).path
        
        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }
    
    // MARK: - Artist Artwork
    
    /// Pre-download artwork for artists
    /// Note: This is a placeholder - actual downloading should be done via downloadAndCacheArtwork(from:ratingKey:type:)
    /// which requires resolved URLs from the sync coordinator
    public func predownloadArtwork(for artists: [CDArtist], size: Int = 500) async throws -> Int {
        // Deprecated - use downloadAndCacheArtwork(from:ratingKey:type:) directly from SyncCoordinator
        return 0
    }
    
    public func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
        let ratingKey = artist.ratingKey
        let filename = "\(ratingKey)_artist.jpg"
        let localPath = Self.artworkDirectory.appendingPathComponent(filename).path

        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }

    // MARK: - Playlist Artwork

    public func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? {
        let ratingKey = playlist.ratingKey
        let filename = "\(ratingKey)_playlist.jpg"
        let localPath = Self.artworkDirectory.appendingPathComponent(filename).path

        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }

    // MARK: - Private Download Methods
    
    /// Download artwork from URL and cache it locally
    /// Note: The URL must be provided by the caller (typically through ArtworkLoader/SyncCoordinator)
    public func downloadAndCacheArtwork(
        from url: URL,
        ratingKey: String,
        type: ArtworkType
    ) async throws {
        let typeString: String
        switch type {
        case .album: typeString = "album"
        case .artist: typeString = "artist"
        case .track: typeString = "track"
        case .playlist: typeString = "playlist"
        }
        
        let filename = "\(ratingKey)_\(typeString).jpg"
        let localURL = Self.artworkDirectory.appendingPathComponent(filename)
        
        do {
            let (tempURL, response) = try await session.download(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw ArtworkDownloadError.downloadFailed(
                    NSError(domain: "ArtworkDownload", code: -1, 
                           userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                )
            }
            
            // Move downloaded file to cache directory
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: localURL)
            
        } catch {
            throw ArtworkDownloadError.downloadFailed(error)
        }
    }
    

    
    // MARK: - Single Artwork Deletion

    /// Delete a specific cached artwork file by ratingKey and type.
    public func deleteArtwork(ratingKey: String, type: ArtworkType) {
        let typeString: String
        switch type {
        case .album: typeString = "album"
        case .artist: typeString = "artist"
        case .track: typeString = "track"
        case .playlist: typeString = "playlist"
        }

        let filename = "\(ratingKey)_\(typeString).jpg"
        let fileURL = Self.artworkDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Delete all cached artwork files whose ratingKey is in the given set.
    /// Checks all type suffixes (album, artist, track, playlist) for each key.
    public func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {
        let fileManager = FileManager.default
        let dir = Self.artworkDirectory
        for key in ratingKeys {
            for suffix in ["album", "artist", "track", "playlist"] {
                let path = dir.appendingPathComponent("\(key)_\(suffix).jpg").path
                if fileManager.fileExists(atPath: path) {
                    try? fileManager.removeItem(atPath: path)
                }
            }
        }
    }

    // MARK: - Cache Management
    
    public func clearArtworkCache() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let fileManager = FileManager.default
                let artworkDir = Self.artworkDirectory
                
                if fileManager.fileExists(atPath: artworkDir.path) {
                    try fileManager.removeItem(at: artworkDir)
                    try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
                }
                
                continuation.resume()
            } catch {
                continuation.resume(throwing: ArtworkDownloadError.fileSystemError(error))
            }
        }
    }
    
    public func getArtworkCacheSize() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let fileManager = FileManager.default
                let artworkDir = Self.artworkDirectory
                
                guard fileManager.fileExists(atPath: artworkDir.path) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                let contents = try fileManager.contentsOfDirectory(
                    at: artworkDir,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
                
                var totalSize: Int64 = 0
                for url in contents {
                    let attributes = try fileManager.attributesOfItem(atPath: url.path)
                    if let size = attributes[.size] as? Int64 {
                        totalSize += size
                    }
                }
                
                continuation.resume(returning: totalSize)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
