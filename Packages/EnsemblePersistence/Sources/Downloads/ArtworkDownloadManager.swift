import Foundation
import ImageIO

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

public enum ArtworkType: String, Sendable, Codable, Hashable {
    case album
    case artist
    case track
    case playlist
}

/// Stable identity for a locally cached artwork file.
public struct ArtworkIdentity: Sendable, Codable, Equatable {
    public let ratingKey: String
    public let type: ArtworkType
    public let sourcePath: String?
    public let dateModifiedSeconds: Int?

    public init(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) {
        self.ratingKey = ratingKey
        self.type = type
        self.sourcePath = sourcePath
        self.dateModifiedSeconds = dateModifiedSeconds
    }

    public init(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModified: Date?
    ) {
        self.init(
            ratingKey: ratingKey,
            type: type,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModified.map { Int($0.timeIntervalSince1970) }
        )
    }

    public func matches(sourcePath expectedSourcePath: String?, dateModifiedSeconds expectedDateModifiedSeconds: Int?) -> Bool {
        if let expectedSourcePath, sourcePath != expectedSourcePath {
            return false
        }
        if let expectedDateModifiedSeconds, dateModifiedSeconds != expectedDateModifiedSeconds {
            return false
        }
        return true
    }
}

public protocol ArtworkDownloadManagerProtocol: Sendable {
    func getLocalArtworkPath(for album: CDAlbum) async throws -> String?
    func getLocalArtworkPath(for artist: CDArtist) async throws -> String?
    func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String?
    func getLocalArtworkPath(ratingKey: String, type: ArtworkType, sourcePath: String?, dateModifiedSeconds: Int?) async throws -> String?
    func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String?
    func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws
    func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws
    func deleteArtwork(ratingKey: String, type: ArtworkType)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>)
    func clearArtworkCache() async throws
    func getArtworkCacheSize() async throws -> Int64
}

public extension ArtworkDownloadManagerProtocol {
    func localArtworkExists(for album: CDAlbum, minimumPixelDimension: Int? = nil) async -> Bool {
        guard let localPath = try? await getLocalArtworkPath(for: album) else { return false }
        return artworkFileExists(atPath: localPath, minimumPixelDimension: minimumPixelDimension)
    }

    func localArtworkExists(for artist: CDArtist, minimumPixelDimension: Int? = nil) async -> Bool {
        guard let localPath = try? await getLocalArtworkPath(for: artist) else { return false }
        return artworkFileExists(atPath: localPath, minimumPixelDimension: minimumPixelDimension)
    }

    func localArtworkExists(for playlist: CDPlaylist, minimumPixelDimension: Int? = nil) async -> Bool {
        guard let localPath = try? await getLocalArtworkPath(for: playlist) else { return false }
        return artworkFileExists(atPath: localPath, minimumPixelDimension: minimumPixelDimension)
    }

    func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        let localPath = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
            .path
        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }

    func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws {
        try await downloadAndCacheArtwork(from: url, ratingKey: identity.ratingKey, type: identity.type)
    }

    func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
        let localPath = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
            .path
        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }
}

private func artworkFileExists(atPath path: String, minimumPixelDimension: Int?) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    guard let minimumPixelDimension, minimumPixelDimension > 0 else { return true }
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return true
    }

    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    return max(width, height) >= minimumPixelDimension
}

public final class ArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
    private let session: URLSession
    
    public init() {
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
    
    public func getLocalArtworkPath(for album: CDAlbum) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: album.ratingKey,
            type: .album,
            sourcePath: album.thumbPath,
            dateModifiedSeconds: Self.dateModifiedSeconds(album.dateModified)
        )
    }
    
    // MARK: - Artist Artwork
    
    public func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: artist.ratingKey,
            type: .artist,
            sourcePath: artist.thumbPath,
            dateModifiedSeconds: Self.dateModifiedSeconds(artist.dateModified)
        )
    }

    // MARK: - Playlist Artwork

    public func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: playlist.ratingKey,
            type: .playlist,
            sourcePath: playlist.compositePath,
            dateModifiedSeconds: Self.dateModifiedSeconds(playlist.dateModified)
        )
    }

    public func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        let localURL = Self.artworkFileURL(ratingKey: ratingKey, type: type)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }

        guard let storedIdentity = Self.readIdentity(for: localURL) else {
            return localURL.path
        }

        guard storedIdentity.ratingKey == ratingKey,
              storedIdentity.type == type,
              storedIdentity.matches(sourcePath: sourcePath, dateModifiedSeconds: dateModifiedSeconds) else {
            return nil
        }

        return localURL.path
    }

    public func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
        let localURL = Self.artworkFileURL(ratingKey: ratingKey, type: type)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }

        guard let storedIdentity = Self.readIdentity(for: localURL) else {
            return localURL.path
        }

        guard storedIdentity.ratingKey == ratingKey,
              storedIdentity.type == type else {
            return nil
        }

        return localURL.path
    }

    // MARK: - Private Download Methods
    
    /// Download artwork from URL and cache it locally
    /// Note: The URL must be provided by the caller (typically through ArtworkLoader/SyncCoordinator)
    public func downloadAndCacheArtwork(
        from url: URL,
        ratingKey: String,
        type: ArtworkType
    ) async throws {
        try await downloadAndCacheArtwork(from: url, identity: nil, ratingKey: ratingKey, type: type)
    }

    public func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws {
        try await downloadAndCacheArtwork(from: url, identity: identity, ratingKey: identity.ratingKey, type: identity.type)
    }

    private func downloadAndCacheArtwork(
        from url: URL,
        identity: ArtworkIdentity?,
        ratingKey: String,
        type: ArtworkType
    ) async throws {
        let localURL = Self.artworkFileURL(ratingKey: ratingKey, type: type)
        
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

            if let identity {
                try Self.writeIdentity(identity, for: localURL)
            } else {
                try? FileManager.default.removeItem(at: Self.identityURL(for: localURL))
            }
            
        } catch {
            throw ArtworkDownloadError.downloadFailed(error)
        }
    }
    

    
    // MARK: - Single Artwork Deletion

    /// Delete a specific cached artwork file by ratingKey and type.
    public func deleteArtwork(ratingKey: String, type: ArtworkType) {
        let fileURL = Self.artworkFileURL(ratingKey: ratingKey, type: type)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try? FileManager.default.removeItem(at: Self.identityURL(for: fileURL))
    }

    /// Delete all cached artwork files whose ratingKey is in the given set.
    /// Checks all type suffixes (album, artist, track, playlist) for each key.
    public func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {
        let fileManager = FileManager.default
        let dir = Self.artworkDirectory
        for key in ratingKeys {
            for suffix in ["album", "artist", "track", "playlist"] {
                let fileURL = dir.appendingPathComponent("\(key)_\(suffix).jpg")
                if fileManager.fileExists(atPath: fileURL.path) {
                    try? fileManager.removeItem(at: fileURL)
                }
                try? fileManager.removeItem(at: Self.identityURL(for: fileURL))
            }
        }
    }

    private static func artworkFileURL(ratingKey: String, type: ArtworkType) -> URL {
        artworkDirectory.appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
    }

    private static func identityURL(for artworkURL: URL) -> URL {
        artworkURL.deletingPathExtension().appendingPathExtension("identity.json")
    }

    private static func dateModifiedSeconds(_ date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    private static func readIdentity(for artworkURL: URL) -> ArtworkIdentity? {
        let url = identityURL(for: artworkURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArtworkIdentity.self, from: data)
    }

    private static func writeIdentity(_ identity: ArtworkIdentity, for artworkURL: URL) throws {
        let data = try JSONEncoder().encode(identity)
        try data.write(to: identityURL(for: artworkURL), options: [.atomic])
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

    public func getArtworkCacheFileCount() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let artworkDir = Self.artworkDirectory
                guard FileManager.default.fileExists(atPath: artworkDir.path) else {
                    continuation.resume(returning: 0)
                    return
                }

                let contents = try FileManager.default.contentsOfDirectory(
                    at: artworkDir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )

                var count = 0
                for url in contents {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                    if values.isRegularFile == true {
                        count += 1
                    }
                }
                continuation.resume(returning: count)
            } catch {
                continuation.resume(throwing: ArtworkDownloadError.fileSystemError(error))
            }
        }
    }
}
