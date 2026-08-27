import CryptoKit
import Foundation
import ImageIO

public enum ArtworkDownloadError: Error, LocalizedError {
    case noArtworkPath
    case httpResponse(statusCode: Int, retryAfter: Date?)
    case requestDeferred(until: Date)
    case downloadFailed(Error)
    case fileSystemError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noArtworkPath:
            return "No artwork path available"
        case .httpResponse(let statusCode, _):
            return "Artwork request returned HTTP \(statusCode)"
        case .requestDeferred(let date):
            return "Artwork request deferred until \(date.formatted(.iso8601))"
        case .downloadFailed(let error):
            return "Artwork download failed: \(error.localizedDescription)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        }
    }

    public var isRequestDeferred: Bool {
        if case .requestDeferred = self { return true }
        return false
    }
}

public enum ArtworkRemoteRequestDecision: Sendable, Equatable {
    case allowed
    case deferred(until: Date)
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
        return sourceCompositeKey == expectedSourceCompositeKey
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

    fileprivate func matchesAsset(_ other: ArtworkIdentity) -> Bool {
        ratingKey == other.ratingKey
            && type == other.type
            && matches(sourceCompositeKey: other.sourceCompositeKey)
            && matches(
                sourcePath: other.sourcePath,
                dateModifiedSeconds: other.dateModifiedSeconds
            )
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
    func remoteArtworkRequestDecision(for identity: ArtworkIdentity) async -> ArtworkRemoteRequestDecision
    func deleteArtwork(ratingKey: String, type: ArtworkType)
    func deleteArtwork(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>)
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>, sourceCompositeKey: String)
    func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String) throws
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
        throw ArtworkDownloadError.noArtworkPath
    }

    func remoteArtworkRequestDecision(for identity: ArtworkIdentity) async -> ArtworkRemoteRequestDecision {
        .allowed
    }

    func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        nil
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
        nil
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
        false
    }

    func deleteArtwork(ratingKey: String, type: ArtworkType, sourceCompositeKey: String?) {
    }

    func deleteArtwork(forRatingKeys ratingKeys: Set<String>, sourceCompositeKey: String) {
    }

    func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String) throws {
        throw ArtworkDownloadError.noArtworkPath
    }
}

/// Shared file inspection for persistent artwork cache entries.
public enum ArtworkFileInspector {
    /// Returns true when the file is a readable image and, when requested, meets a minimum dimension.
    public static func fileExists(atPath path: String, minimumPixelDimension: Int? = nil) -> Bool {
        fileExists(at: URL(fileURLWithPath: path), minimumPixelDimension: minimumPixelDimension)
    }

    /// Returns true when the file exists and, when requested, meets a minimum width or height.
    public static func fileExists(at url: URL, minimumPixelDimension: Int? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return false }
        guard let minimumPixelDimension, minimumPixelDimension > 0 else { return true }
        return min(width, height) >= minimumPixelDimension
    }
}

public final class ArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
    private struct RemoteOutcome: Codable {
        let identity: ArtworkIdentity
        let failureCount: Int
        let retryAfter: Date
    }

    private struct SourceRemoteOutcome: Codable {
        let retryAfter: Date
    }

    private enum RemoteFailureKind {
        case missing
        case rateLimited(Date?)
        case transient
    }

    private let session: URLSession
    private let storageDirectory: URL
    private let now: @Sendable () -> Date
    private static let fileLock = NSLock()
    private static var loadedRemoteOutcomeDirectories: Set<String> = []
    private static var remoteOutcomes: [String: RemoteOutcome] = [:]
    private static var sourceRemoteOutcomes: [String: SourceRemoteOutcome] = [:]
    static let cacheVersionMarkerName = ".source-scoped-v2"
    private static let sourceScopedFilenamePrefix = "v2_"
    private static let missingRetryIntervals: [TimeInterval] = [5 * 60, 60 * 60, 6 * 60 * 60, 24 * 60 * 60]
    private static let transientRetryIntervals: [TimeInterval] = [30, 2 * 60, 10 * 60, 30 * 60]
    
    public init(storageDirectory: URL = ArtworkDownloadManager.artworkDirectory) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.storageDirectory = storageDirectory
        self.now = { Date() }
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    init(
        session: URLSession,
        storageDirectory: URL = ArtworkDownloadManager.artworkDirectory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.storageDirectory = storageDirectory
        self.now = now
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    /// Removes obsolete unscoped cache files. Call from background startup work.
    public func preparePersistentCache() {
        do {
            if let removedCount = try Self.purgeLegacyArtworkCacheIfNeeded(in: storageDirectory) {
                EnsembleLogger.debug("Artwork cache upgraded to source-scoped v2; removed \(removedCount) legacy entries")
            }
            Self.withFileLock {
                Self.loadRemoteOutcomesIfNeeded(in: storageDirectory)
            }
        } catch {
            EnsembleLogger.debug("Artwork cache v2 upgrade failed and will retry: \(error.localizedDescription)")
        }
    }
    
    /// Directory for storing cached artwork
    public static var artworkDirectory: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let artworkURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: artworkURL.path) {
            try? FileManager.default.createDirectory(at: artworkURL, withIntermediateDirectories: true)
        }

        do {
            try (artworkURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        } catch {
            EnsembleLogger.debug("Failed to exclude artwork cache from backup: \(error.localizedDescription)")
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

    /// Unscoped durable artwork is unsupported by the source-isolated cache.
    public func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        nil
    }

    public func getLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?,
        sourcePath: String?,
        dateModifiedSeconds: Int?
    ) async throws -> String? {
        guard let sourceCompositeKey else { return nil }
        return Self.withFileLock {
            let localURL = Self.artworkFileURL(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                in: storageDirectory
            )
            return Self.validArtworkPath(
                at: localURL,
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
        nil
    }

    /// Returns source-owned artwork without enforcing mutable path or date metadata.
    public func getStaleLocalArtworkPath(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String?
    ) async throws -> String? {
        guard let sourceCompositeKey else { return nil }
        return Self.withFileLock {
            let localURL = Self.artworkFileURL(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                in: storageDirectory
            )
            return Self.validArtworkPath(
                at: localURL,
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
        false
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
        throw ArtworkDownloadError.noArtworkPath
    }

    public func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws {
        guard identity.sourceCompositeKey != nil else {
            throw ArtworkDownloadError.noArtworkPath
        }
        if case .deferred(let date) = await remoteArtworkRequestDecision(for: identity) {
            throw ArtworkDownloadError.requestDeferred(until: date)
        }
        try await downloadAndCacheArtwork(from: url, identity: identity, ratingKey: identity.ratingKey, type: identity.type)
    }

    public func remoteArtworkRequestDecision(for identity: ArtworkIdentity) async -> ArtworkRemoteRequestDecision {
        guard identity.sourceCompositeKey != nil else { return .allowed }
        return Self.withFileLock {
            if let sourceCompositeKey = identity.sourceCompositeKey,
               let sourceOutcome = Self.readSourceRemoteOutcome(
                   sourceCompositeKey: sourceCompositeKey,
                   in: storageDirectory
               ),
               sourceOutcome.retryAfter > now() {
                return .deferred(until: sourceOutcome.retryAfter)
            }
            let artworkURL = Self.artworkFileURL(
                ratingKey: identity.ratingKey,
                type: identity.type,
                sourceCompositeKey: identity.sourceCompositeKey,
                in: storageDirectory
            )
            guard let outcome = Self.readRemoteOutcome(for: artworkURL),
                  outcome.identity.matchesAsset(identity),
                  outcome.retryAfter > now() else {
                return .allowed
            }
            return .deferred(until: outcome.retryAfter)
        }
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
            sourceCompositeKey: identity?.sourceCompositeKey,
            in: storageDirectory
        )
        
        do {
            let (tempURL, response) = try await session.download(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                if let identity {
                    recordRemoteFailure(.transient, for: identity)
                }
                throw ArtworkDownloadError.downloadFailed(
                    NSError(
                        domain: "ArtworkDownload",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing HTTP response"]
                    )
                )
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let retryAfter = Self.retryAfterDate(from: httpResponse, now: now())
                if let identity,
                   httpResponse.statusCode != 401,
                   httpResponse.statusCode != 403 {
                    recordRemoteFailure(
                        Self.failureKind(statusCode: httpResponse.statusCode, retryAfter: retryAfter),
                        for: identity
                    )
                }
                throw ArtworkDownloadError.httpResponse(
                    statusCode: httpResponse.statusCode,
                    retryAfter: retryAfter
                )
            }
            guard ArtworkFileInspector.fileExists(at: tempURL) else {
                if let identity {
                    recordRemoteFailure(.transient, for: identity)
                }
                throw ArtworkDownloadError.downloadFailed(
                    NSError(
                        domain: "ArtworkDownload",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Response was not a readable image"]
                    )
                )
            }
            
            try Self.withFileLock {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)

                if let identity {
                    try Self.writeIdentity(identity, for: localURL)
                    Self.removeRemoteOutcome(for: localURL)
                } else {
                    try? FileManager.default.removeItem(at: Self.identityURL(for: localURL))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ArtworkDownloadError {
            throw error
        } catch {
            if let identity {
                recordRemoteFailure(.transient, for: identity)
            }
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
            sourceCompositeKey: sourceCompositeKey,
            in: storageDirectory
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
    public func deleteArtwork(forSourceCompositeKey sourceCompositeKey: String) throws {
        let prefix = Self.scopedFilenamePrefix(sourceCompositeKey: sourceCompositeKey)
        try Self.withFileLock {
            let urls = try FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for url in urls where url.lastPathComponent.hasPrefix(prefix) {
                try FileManager.default.removeItem(at: url)
            }
            Self.remoteOutcomes = Self.remoteOutcomes.filter {
                let url = URL(fileURLWithPath: $0.key)
                return url.deletingLastPathComponent().standardizedFileURL != storageDirectory.standardizedFileURL
                    || !url.lastPathComponent.hasPrefix(prefix)
            }
            Self.sourceRemoteOutcomes = Self.sourceRemoteOutcomes.filter {
                let url = URL(fileURLWithPath: $0.key)
                return url.deletingLastPathComponent().standardizedFileURL != storageDirectory.standardizedFileURL
                    || !url.lastPathComponent.hasPrefix(prefix)
            }
            let remaining = try FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            if remaining.contains(where: { $0.lastPathComponent.hasPrefix(prefix) }) {
                throw ArtworkDownloadError.fileSystemError(
                    CocoaError(.fileWriteUnknown)
                )
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
        sourceCompositeKey: String? = nil,
        in directory: URL = artworkDirectory
    ) -> URL {
        directory.appendingPathComponent(cacheFilename(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceCompositeKey
        ))
    }

    static func identityURL(for artworkURL: URL) -> URL {
        artworkURL.deletingPathExtension().appendingPathExtension("identity.json")
    }

    private static func scopedFilenamePrefix(sourceCompositeKey: String) -> String {
        "\(sourceScopedFilenamePrefix)\(digest(sourceCompositeKey))_"
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

    private static func writeIdentity(_ identity: ArtworkIdentity, for artworkURL: URL) throws {
        let data = try JSONEncoder().encode(identity)
        try data.write(to: identityURL(for: artworkURL), options: [.atomic])
    }

    static func remoteOutcomeURL(for artworkURL: URL) -> URL {
        artworkURL.deletingPathExtension().appendingPathExtension("remote.json")
    }

    private static func readRemoteOutcome(for artworkURL: URL) -> RemoteOutcome? {
        let url = remoteOutcomeURL(for: artworkURL)
        loadRemoteOutcomesIfNeeded(in: url.deletingLastPathComponent())
        return remoteOutcomes[url.path]
    }

    private static func writeRemoteOutcome(_ outcome: RemoteOutcome, for artworkURL: URL) throws {
        let url = remoteOutcomeURL(for: artworkURL)
        let data = try JSONEncoder().encode(outcome)
        try data.write(to: url, options: [.atomic])
        remoteOutcomes[url.path] = outcome
    }

    private static func sourceRemoteOutcomeURL(
        sourceCompositeKey: String,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent(
            "\(scopedFilenamePrefix(sourceCompositeKey: sourceCompositeKey))remote-source.json"
        )
    }

    private static func readSourceRemoteOutcome(
        sourceCompositeKey: String,
        in directory: URL
    ) -> SourceRemoteOutcome? {
        loadRemoteOutcomesIfNeeded(in: directory)
        let url = sourceRemoteOutcomeURL(sourceCompositeKey: sourceCompositeKey, in: directory)
        return sourceRemoteOutcomes[url.path]
    }

    private static func loadRemoteOutcomesIfNeeded(in directory: URL) {
        let directoryPath = directory.standardizedFileURL.path
        guard loadedRemoteOutcomeDirectories.insert(directoryPath).inserted else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        for url in urls {
            let name = url.lastPathComponent
            if name.hasSuffix(".remote.json"),
               let data = try? Data(contentsOf: url),
               let outcome = try? decoder.decode(RemoteOutcome.self, from: data) {
                remoteOutcomes[url.path] = outcome
            } else if name.hasSuffix("_remote-source.json"),
                      let data = try? Data(contentsOf: url),
                      let outcome = try? decoder.decode(SourceRemoteOutcome.self, from: data) {
                sourceRemoteOutcomes[url.path] = outcome
            }
        }
    }

    private func recordRemoteFailure(_ kind: RemoteFailureKind, for identity: ArtworkIdentity) {
        guard let sourceCompositeKey = identity.sourceCompositeKey else { return }
        Self.withFileLock {
            if case .rateLimited(let retryAfter) = kind {
                let outcome = SourceRemoteOutcome(
                    retryAfter: retryAfter.map { max($0, now()) }
                        ?? now().addingTimeInterval(5 * 60)
                )
                let url = Self.sourceRemoteOutcomeURL(
                    sourceCompositeKey: sourceCompositeKey,
                    in: storageDirectory
                )
                if let data = try? JSONEncoder().encode(outcome) {
                    try? data.write(to: url, options: [.atomic])
                    Self.sourceRemoteOutcomes[url.path] = outcome
                }
                return
            }

            let artworkURL = Self.artworkFileURL(
                ratingKey: identity.ratingKey,
                type: identity.type,
                sourceCompositeKey: sourceCompositeKey,
                in: storageDirectory
            )
            let previous = Self.readRemoteOutcome(for: artworkURL)
            let failureCount: Int
            if let previous, previous.identity.matchesAsset(identity) {
                failureCount = previous.failureCount + 1
            } else {
                failureCount = 1
            }
            let retryAfter = Self.retryDate(
                for: kind,
                failureCount: failureCount,
                now: now()
            )
            try? Self.writeRemoteOutcome(
                RemoteOutcome(
                    identity: identity,
                    failureCount: failureCount,
                    retryAfter: retryAfter
                ),
                for: artworkURL
            )
        }
    }

    private static func failureKind(statusCode: Int, retryAfter: Date?) -> RemoteFailureKind {
        switch statusCode {
        case 404, 410:
            return .missing
        case 429:
            return .rateLimited(retryAfter)
        default:
            return .transient
        }
    }

    private static func retryDate(
        for kind: RemoteFailureKind,
        failureCount: Int,
        now: Date
    ) -> Date {
        let index = max(0, failureCount - 1)
        switch kind {
        case .missing:
            return now.addingTimeInterval(missingRetryIntervals[min(index, missingRetryIntervals.count - 1)])
        case .rateLimited(let retryAfter):
            return retryAfter.map { max($0, now) } ?? now.addingTimeInterval(5 * 60)
        case .transient:
            return now.addingTimeInterval(transientRetryIntervals[min(index, transientRetryIntervals.count - 1)])
        }
    }

    private static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return now.addingTimeInterval(max(0, seconds))
        }

        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
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

    private static func deleteArtworkAndIdentity(at artworkURL: URL) {
        try? FileManager.default.removeItem(at: artworkURL)
        try? FileManager.default.removeItem(at: identityURL(for: artworkURL))
        removeRemoteOutcome(for: artworkURL)
    }

    private static func removeRemoteOutcome(for artworkURL: URL) {
        let outcomeURL = remoteOutcomeURL(for: artworkURL)
        try? FileManager.default.removeItem(at: outcomeURL)
        remoteOutcomes.removeValue(forKey: outcomeURL.path)
    }

    private static func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }

    @discardableResult
    static func purgeLegacyArtworkCacheIfNeeded(
        in directory: URL = artworkDirectory
    ) throws -> Int? {
        try withFileLock {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let markerURL = directory.appendingPathComponent(cacheVersionMarkerName)
            guard !fileManager.fileExists(atPath: markerURL.path) else { return nil }

            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            var removedCount = 0
            for url in urls where !url.lastPathComponent.hasPrefix(sourceScopedFilenamePrefix) {
                try fileManager.removeItem(at: url)
                removedCount += 1
            }
            try Data().write(to: markerURL, options: [.atomic])
            return removedCount
        }
    }

    // MARK: - Cache Management
    
    public func clearArtworkCache() async throws {
        do {
            try Self.withFileLock {
                let fileManager = FileManager.default
                let artworkDir = storageDirectory

                if fileManager.fileExists(atPath: artworkDir.path) {
                    try fileManager.removeItem(at: artworkDir)
                    try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
                    try (artworkDir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
                }
                let directoryPath = artworkDir.standardizedFileURL.path
                Self.loadedRemoteOutcomeDirectories.insert(directoryPath)
                Self.remoteOutcomes = Self.remoteOutcomes.filter {
                    URL(fileURLWithPath: $0.key)
                        .deletingLastPathComponent()
                        .standardizedFileURL.path != directoryPath
                }
                Self.sourceRemoteOutcomes = Self.sourceRemoteOutcomes.filter {
                    URL(fileURLWithPath: $0.key)
                        .deletingLastPathComponent()
                        .standardizedFileURL.path != directoryPath
                }
            }
        } catch {
            throw ArtworkDownloadError.fileSystemError(error)
        }
    }
    
    public func getArtworkCacheSize() async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try Self.withFileLock {
                let fileManager = FileManager.default
                let artworkDir = self.storageDirectory

                guard fileManager.fileExists(atPath: artworkDir.path) else { return Int64(0) }

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
                return totalSize
            }
        }.value
    }

    public func getArtworkCacheFileCount() async throws -> Int {
        try await Task.detached(priority: .utility) {
            try Self.withFileLock {
                let artworkDir = self.storageDirectory
                guard FileManager.default.fileExists(atPath: artworkDir.path) else { return 0 }

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
                return count
            }
        }.value
    }
}
