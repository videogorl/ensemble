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
}

public protocol ArtworkDownloadManagerProtocol: Sendable {
    func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int
    func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int
    func getLocalArtworkPath(for album: CDAlbum) async throws -> String?
    func getLocalArtworkPath(for artist: CDArtist) async throws -> String?
    func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws
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
    
    public func predownloadArtwork(for albums: [CDAlbum], size: Int = 500) async throws -> Int {
        var downloadedCount = 0
        
        for album in albums {
            guard let thumbPath = album.thumbPath else { continue }
            
            // Skip if already cached
            if let localPath = try? await getLocalArtworkPath(for: album),
               FileManager.default.fileExists(atPath: localPath) {
                continue
            }
            
            do {
                try await downloadAndCacheArtwork(
                    path: thumbPath,
                    ratingKey: album.ratingKey,
                    type: .album,
                    size: size
                )
                downloadedCount += 1
            } catch {
                // Continue with next album on error
                print("Failed to download artwork for album \(album.title ?? "unknown"): \(error)")
            }
        }
        
        return downloadedCount
    }
    
    public func getLocalArtworkPath(for album: CDAlbum) async throws -> String? {
        let ratingKey = album.ratingKey
        let filename = "\(ratingKey)_album.jpg"
        let localPath = Self.artworkDirectory.appendingPathComponent(filename).path
        
        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }
    
    // MARK: - Artist Artwork
    
    public func predownloadArtwork(for artists: [CDArtist], size: Int = 500) async throws -> Int {
        var downloadedCount = 0
        
        for artist in artists {
            guard let thumbPath = artist.thumbPath else { continue }
            
            // Skip if already cached
            if let localPath = try? await getLocalArtworkPath(for: artist),
               FileManager.default.fileExists(atPath: localPath) {
                continue
            }
            
            do {
                try await downloadAndCacheArtwork(
                    path: thumbPath,
                    ratingKey: artist.ratingKey,
                    type: .artist,
                    size: size
                )
                downloadedCount += 1
            } catch {
                // Continue with next artist on error
                print("Failed to download artwork for artist \(artist.name ?? "unknown"): \(error)")
            }
        }
        
        return downloadedCount
    }
    
    public func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
        let ratingKey = artist.ratingKey
        let filename = "\(ratingKey)_artist.jpg"
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
    
    private func downloadAndCacheArtwork(
        path: String,
        ratingKey: String,
        type: ArtworkType,
        size: Int
    ) async throws {
        // This is called internally but doesn't have server connection details
        // It's a placeholder that will be replaced by actual implementation
        // through the public downloadAndCacheArtwork method
        let typeString: String
        switch type {
        case .album: typeString = "album"
        case .artist: typeString = "artist"
        case .track: typeString = "track"
        }
        
        let filename = "\(ratingKey)_\(typeString).jpg"
        let localURL = Self.artworkDirectory.appendingPathComponent(filename)
        
        // Create empty marker - actual implementation will come through ArtworkLoader
        try Data().write(to: localURL)
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
