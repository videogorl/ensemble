import CryptoKit
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
    public let requestedPixelDimension: Int?
    /// Source ownership used to isolate equal provider IDs in the durable cache.
    public let sourceCompositeKey: String?

    public init(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        requestedPixelDimension: Int? = nil,
        sourceCompositeKey: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.type = type
        self.sourcePath = sourcePath
        self.dateModifiedSeconds = dateModifiedSeconds
        self.requestedPixelDimension = requestedPixelDimension
        self.sourceCompositeKey = sourceCompositeKey
    }

    public init(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModified: Date?,
        requestedPixelDimension: Int? = nil,
        sourceCompositeKey: String? = nil
    ) {
        self.init(
            ratingKey: ratingKey,
            type: type,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModified.map { Int($0.timeIntervalSince1970) },
            requestedPixelDimension: requestedPixelDimension,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    /// Returns whether this identity can satisfy a source-scoped lookup.
    public func matches(sourceCompositeKey expectedSourceCompositeKey: String?) -> Bool {
        guard let expectedSourceCompositeKey else { return true }
        return sourceCompositeKey == nil || sourceCompositeKey == expectedSourceCompositeKey
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

    public func satisfiesAttemptedPixelDimension(_ minimumPixelDimension: Int?) -> Bool {
        guard let minimumPixelDimension, minimumPixelDimension > 0 else { return true }
        guard let requestedPixelDimension else { return false }
        return requestedPixelDimension >= minimumPixelDimension
    }
}

public protocol ArtworkDownloadManagerProtocol: Sendable {
    func getLocalArtworkPath(for album: CDAlbum) async throws -> String?
    func getLocalArtworkPath(for artist: CDArtist) async throws -> String?
    func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String?
    func getLocalArtworkPath(ratingKey: String, type: ArtworkType, sourcePath: String?, dateModifiedSeconds: Int?) async throws -> String?
    func getLocalArtworkPath(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?, sourcePath: String?, dateModifiedSeconds: Int?) async throws -> String?
    func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String?
    func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?) async throws -> String?
    func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool
    func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool
    func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws
    func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws
    func deleteArtwork(ratingKey: String, type: ArtworkType)
    func deleteArtwork(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>, sourceCompositeKey: String)
    func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String)
    func clearArtworkCache() async throws
    func getArtworkCacheSize() async throws -> Int64
}

public extension ArtworkDownloadManagerProtocol {
    func localArtworkExists(for album: CDAlbum, minimumPixelDimension: Int? = nil) async -> Bool {
        await localArtworkExists(
            ratingKey: album.ratingKey,
            type: .album,
            sourceCompositeKey: album.sourceCompositeKey,
            sourcePath: album.thumbPath,
            dateModifiedSeconds: album.dateModified.map { Int($0.timeIntervalSince1970) },
            minimumPixelDimension: minimumPixelDimension
        )
    }

    func localArtworkExists(for artist: CDArtist, minimumPixelDimension: Int? = nil) async -> Bool {
        await localArtworkExists(
            ratingKey: artist.ratingKey,
            type: .artist,
            sourceCompositeKey: artist.sourceCompositeKey,
            sourcePath: artist.thumbPath,
            dateModifiedSeconds: artist.dateModified.map { Int($0.timeIntervalSince1970) },
            minimumPixelDimension: minimumPixelDimension
        )
    }

    func localArtworkExists(for playlist: CDPlaylist, minimumPixelDimension: Int? = nil) async -> Bool {
        await localArtworkExists(
            ratingKey: playlist.ratingKey,
            type: .playlist,
            sourceCompositeKey: playlist.sourceCompositeKey,
            sourcePath: playlist.compositePath,
            dateModifiedSeconds: playlist.dateModified.map { Int($0.timeIntervalSince1970) },
            minimumPixelDimension: minimumPixelDimension
        )
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

    func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds
        )
    }

    func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
        let localPath = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
            .path
        return FileManager.default.fileExists(atPath: localPath) ? localPath : nil
    }

    func getStaleLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?
    ) async throws -> String? {
        try await getStaleLocalArtworkPath(ratingKey: ratingKey, type: type)
    }

    func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool {
        guard let localPath = try? await getLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds
        ) else {
            return false
        }
        return ArtworkFileInspector.fileExists(
            atPath: localPath,
            minimumPixelDimension: minimumPixelDimension
        )
    }

    func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool {
        await localArtworkExists(
            ratingKey: ratingKey,
            type: type,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds,
            minimumPixelDimension: minimumPixelDimension
        )
    }

    func deleteArtwork(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?) {
        deleteArtwork(ratingKey: ratingKey, type: type)
    }

    func deleteArtwork(forRatingKeys ratingKeys: Set<String>, sourceCompositeKey: String) {
        deleteArtwork(forRatingKeys: ratingKeys)
    }

    func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String) {}
}

/// Shared file inspection for persistent artwork cache entries.
public enum ArtworkFileInspector {
    /// Returns true when the file exists and, when requested, meets a minimum width or height.
    public static func fileExists(atPath path: String, minimumPixelDimension: Int? = nil) -> Bool {
        fileExists(at: URL(fileURLWithPath: path), minimumPixelDimension: minimumPixelDimension)
    }

    /// Returns true when the file exists and, when requested, meets a minimum width or height.
    public static func fileExists(at url: URL, minimumPixelDimension: Int? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let minimumPixelDimension, minimumPixelDimension > 0 else { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height) >= minimumPixelDimension
    }
}

public final class ArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
    private let session: URLSession
    private static let fileLock = NSLock()
    
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
            sourceCompositeKey: album.sourceCompositeKey,
            sourcePath: album.thumbPath,
            dateModifiedSeconds: Self.dateModifiedSeconds(album.dateModified)
        )
    }
    
    // MARK: - Artist Artwork
    
    public func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: artist.ratingKey,
            type: .artist,
            sourceCompositeKey: artist.sourceCompositeKey,
            sourcePath: artist.thumbPath,
            dateModifiedSeconds: Self.dateModifiedSeconds(artist.dateModified)
        )
    }

    // MARK: - Playlist Artwork

    public func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: playlist.ratingKey,
            type: .playlist,
            sourceCompositeKey: playlist.sourceCompositeKey,
            sourcePath: playlist.compositePath,
            dateModifiedSeconds: Self.dateModifiedSeconds(playlist.dateModified)
        )
    }

    /// Returns fresh artwork owned by one source, migrating a matching legacy entry when needed.
    public func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        try await getLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: nil,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds
        )
    }

    public func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        try Self.withFileLock {
            let localURL = Self.artworkFileURL(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            )
            if let path = Self.validArtworkPath(
                at: localURL,
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModifiedSeconds,
                allowStaleMetadata: false
            ) {
                return path
            }

            guard let sourceCompositeKey else { return nil }
            return try Self.migrateLegacyArtwork(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModifiedSeconds,
                allowStaleMetadata: false
            )
        }
    }

    public func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
        try await getStaleLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: nil
        )
    }

    /// Returns source-owned artwork without enforcing mutable path or date metadata.
    public func getStaleLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?
    ) async throws -> String? {
        try Self.withFileLock {
            let localURL = Self.artworkFileURL(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey
            )
            if let path = Self.validArtworkPath(
                at: localURL,
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                sourcePath: nil,
                dateModifiedSeconds: nil,
                allowStaleMetadata: true
            ) {
                return path
            }

            guard let sourceCompositeKey else { return nil }
            return try Self.migrateLegacyArtwork(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                sourcePath: nil,
                dateModifiedSeconds: nil,
                allowStaleMetadata: true
            )
        }
    }

    /// Returns whether source-owned artwork satisfies the requested source metadata and size.
    public func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool {
        await localArtworkExists(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: nil,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds,
            minimumPixelDimension: minimumPixelDimension
        )
    }

    public func localArtworkExists(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        minimumPixelDimension: Int?
    ) async -> Bool {
        guard let localPath = try? await getLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey,
            sourcePath: sourcePath,
            dateModifiedSeconds: dateModifiedSeconds
        ) else {
            return false
        }

        if ArtworkFileInspector.fileExists(
            atPath: localPath,
            minimumPixelDimension: minimumPixelDimension
        ) {
            return true
        }

        let localURL = URL(fileURLWithPath: localPath)
        guard let storedIdentity = Self.readIdentity(for: localURL),
              storedIdentity.matches(
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModifiedSeconds
              ) else {
            return false
        }
        return storedIdentity.satisfiesAttemptedPixelDimension(minimumPixelDimension)
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
        let localURL = Self.artworkFileURL(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: identity?.sourceCompositeKey
        )
        
        do {
            let (tempURL, response) = try await session.download(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw ArtworkDownloadError.downloadFailed(
                    NSError(domain: "ArtworkDownload", code: -1, 
                           userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                )
            }
            
            try Self.withFileLock {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)

                if let identity {
                    try Self.writeIdentity(identity, for: localURL)
                } else {
                    try? FileManager.default.removeItem(at: Self.identityURL(for: localURL))
                }
            }
            
        } catch {
            throw ArtworkDownloadError.downloadFailed(error)
        }
    }
    

    
    // MARK: - Single Artwork Deletion

    /// Delete a specific cached artwork file by ratingKey and type.
    public func deleteArtwork(ratingKey: String, type: ArtworkType) {
        deleteArtwork(ratingKey: ratingKey, type: type, sourceCompositeKey: nil)
    }

    /// Deletes one source-owned artwork entry without touching equal IDs from other sources.
    public func deleteArtwork(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?
    ) {
        let fileURL = Self.artworkFileURL(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey
        )

        Self.withFileLock {
            Self.deleteArtworkAndIdentity(at: fileURL)
        }
    }

    /// Delete all cached artwork files whose ratingKey is in the given set.
    /// Checks all type suffixes (album, artist, track, playlist) for each key.
    public func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {
        deleteArtwork(forRatingKeys: ratingKeys, sourceCompositeKey: nil)
    }

    /// Deletes the supplied source-owned artwork IDs across all artwork types.
    public func deleteArtwork(
        forRatingKeys ratingKeys: Set<String>,
        sourceCompositeKey: String
    ) {
        deleteArtwork(forRatingKeys: ratingKeys, sourceCompositeKey: Optional(sourceCompositeKey))
    }

    /// Deletes every durable artwork entry owned by one source.
    public func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String) {
        let prefix = Self.scopedFilenamePrefix(sourceCompositeKey: sourceCompositeKey)
        Self.withFileLock {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: Self.artworkDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }

            for url in urls where url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }

            for identityURL in urls where Self.isIdentitySidecar(identityURL) {
                let artworkURL = identityURL
                    .deletingPathExtension()
                    .deletingPathExtension()
                    .appendingPathExtension("jpg")
                guard let identity = Self.readIdentity(for: artworkURL),
                      identity.sourceCompositeKey == sourceCompositeKey,
                      artworkURL == Self.artworkFileURL(
                          ratingKey: identity.ratingKey,
                          type: identity.type
                      ) else {
                    continue
                }
                Self.deleteArtworkAndIdentity(at: artworkURL)
            }
        }
    }

    private func deleteArtwork(
        forRatingKeys ratingKeys: Set<String>,
        sourceCompositeKey: String?
    ) {
        for key in ratingKeys {
            for type in [ArtworkType.album, .artist, .track, .playlist] {
                deleteArtwork(
                    ratingKey: key,
                    type: type,
                    sourceCompositeKey: sourceCompositeKey
                )
            }
        }
    }

    /// Returns the stable source-scoped filename used by persistent artwork and system media surfaces.
    public static func cacheFilename(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?
    ) -> String {
        guard let sourceCompositeKey else {
            return "\(ratingKey)_\(type.rawValue).jpg"
        }
        return "\(scopedFilenamePrefix(sourceCompositeKey: sourceCompositeKey))\(digest(ratingKey))_\(type.rawValue).jpg"
    }

    static func artworkFileURL(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String? = nil
    ) -> URL {
        artworkDirectory.appendingPathComponent(cacheFilename(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey
        ))
    }

    static func identityURL(for artworkURL: URL) -> URL {
        artworkURL.deletingPathExtension().appendingPathExtension("identity.json")
    }

    private static func scopedFilenamePrefix(sourceCompositeKey: String) -> String {
        "v2_\(digest(sourceCompositeKey))_"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func dateModifiedSeconds(_ date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    private static func readIdentity(for artworkURL: URL) -> ArtworkIdentity? {
        let url = identityURL(for: artworkURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArtworkIdentity.self, from: data)
    }

    private static func isIdentitySidecar(_ url: URL) -> Bool {
        url.pathExtension == "json"
            && url.deletingPathExtension().pathExtension == "identity"
    }

    private static func writeIdentity(_ identity: ArtworkIdentity, for artworkURL: URL) throws {
        let data = try JSONEncoder().encode(identity)
        try data.write(to: identityURL(for: artworkURL), options: [.atomic])
    }

    private static func validArtworkPath(
        at artworkURL: URL,
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        allowStaleMetadata: Bool
    ) -> String? {
        guard FileManager.default.fileExists(atPath: artworkURL.path) else { return nil }
        guard let storedIdentity = readIdentity(for: artworkURL) else { return artworkURL.path }
        guard storedIdentity.ratingKey == ratingKey,
              storedIdentity.type == type,
              storedIdentity.matches(sourceCompositeKey: sourceCompositeKey) else {
            return nil
        }
        if !allowStaleMetadata,
           !storedIdentity.matches(
               sourcePath: sourcePath,
               dateModifiedSeconds: dateModifiedSeconds
           ) {
            return nil
        }
        return artworkURL.path
    }

    private static func migrateLegacyArtwork(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String,
        sourcePath: String?,
        dateModifiedSeconds: Int?,
        allowStaleMetadata: Bool
    ) throws -> String? {
        let legacyURL = artworkFileURL(ratingKey: ratingKey, type: type)
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let legacyIdentity = readIdentity(for: legacyURL),
              legacyIdentity.ratingKey == ratingKey,
              legacyIdentity.type == type,
              legacyIdentity.sourceCompositeKey == sourceCompositeKey else {
            return nil
        }

        if !allowStaleMetadata {
            guard legacyIdentity.sourcePath == sourcePath,
                  legacyIdentity.dateModifiedSeconds == dateModifiedSeconds else {
                return nil
            }
        }

        let scopedURL = artworkFileURL(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey
        )
        let scopedIdentity = ArtworkIdentity(
            ratingKey: ratingKey,
            type: type,
            sourcePath: legacyIdentity.sourcePath,
            dateModifiedSeconds: legacyIdentity.dateModifiedSeconds,
            requestedPixelDimension: legacyIdentity.requestedPixelDimension,
            sourceCompositeKey: sourceCompositeKey
        )

        do {
            if FileManager.default.fileExists(atPath: scopedURL.path) {
                deleteArtworkAndIdentity(at: scopedURL)
            }
            try FileManager.default.copyItem(at: legacyURL, to: scopedURL)
            try writeIdentity(scopedIdentity, for: scopedURL)
            deleteArtworkAndIdentity(at: legacyURL)
            return scopedURL.path
        } catch {
            deleteArtworkAndIdentity(at: scopedURL)
            throw error
        }
    }

    private static func deleteArtworkAndIdentity(at artworkURL: URL) {
        try? FileManager.default.removeItem(at: artworkURL)
        try? FileManager.default.removeItem(at: identityURL(for: artworkURL))
    }

    private static func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }

    // MARK: - Cache Management
    
    public func clearArtworkCache() async throws {
        do {
            try Self.withFileLock {
                let fileManager = FileManager.default
                let artworkDir = Self.artworkDirectory

                if fileManager.fileExists(atPath: artworkDir.path) {
                    try fileManager.removeItem(at: artworkDir)
                    try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
                }
            }
        } catch {
            throw ArtworkDownloadError.fileSystemError(error)
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
