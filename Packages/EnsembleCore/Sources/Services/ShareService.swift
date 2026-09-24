import EnsembleAPI
import Foundation
import os

/// Stable export metadata for audio files shared or dragged out of Ensemble.
public struct TrackFileExportMetadata: Equatable, Sendable {
    public let displayTitle: String
    public let sanitizedBaseName: String
    public let fileExtension: String

    public var fileName: String {
        "\(sanitizedBaseName).\(fileExtension)"
    }

    public init(
        track: Track,
        fallbackExtension: String = "mp3",
        quality: StreamingQuality = .original
    ) {
        let title = Self.formattedTrackTitle(track)
        self.displayTitle = title
        self.sanitizedBaseName = Self.sanitizedFilename(title)
        self.fileExtension = quality == .original
            ? Self.preferredExtension(for: track, fallbackExtension: fallbackExtension)
            : "mp3"
    }

    private static func formattedTrackTitle(_ track: Track) -> String {
        var name = ""

        if track.trackNumber > 0 {
            name += String(format: "%02d. ", track.trackNumber)
        }

        name += track.title

        if let artist = track.artistName {
            name += " - \(artist)"
        }

        return name
    }

    private static func preferredExtension(for track: Track, fallbackExtension: String) -> String {
        let localQuality = AudioQualityPreference.normalizedQuality(track.downloadedQuality)
            ?? track.localFilePath.flatMap { AudioQualityPreference.fileQuality(at: URL(fileURLWithPath: $0)) }
        if localQuality == StreamingQuality.original.rawValue,
           let ext = pathExtension(from: track.localFilePath) {
            return ext
        }

        if let ext = pathExtension(from: track.streamKey) {
            return ext
        }

        let normalizedFallback = fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalizedFallback.isEmpty ? "mp3" : normalizedFallback
    }

    private static func pathExtension(from rawPath: String?) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }

        if let components = URLComponents(string: rawPath),
           let decodedPath = components.percentEncodedPath.removingPercentEncoding,
           !decodedPath.isEmpty {
            let ext = URL(fileURLWithPath: decodedPath).pathExtension
            if let normalized = normalizedExtension(ext) {
                return normalized
            }
        }

        return normalizedExtension(URL(fileURLWithPath: rawPath).pathExtension)
    }

    private static func normalizedExtension(_ ext: String) -> String? {
        let normalized = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: invalidChars).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Track" : sanitized
    }
}

/// Payload types for the share sheet
public enum SharePayload {
    /// A URL link with optional descriptive text
    case link(url: URL, text: String)
    /// Plain text fallback when no link could be resolved
    case text(String)
    /// A local audio file for sharing
    case file(url: URL, title: String)
}

/// Assembles share payloads for tracks and albums.
/// Coordinates between SongLinkService (link resolution) and SyncCoordinator (stream access).
@MainActor
public final class ShareService: ObservableObject {
    private let songLinkService: SongLinkService
    private let syncCoordinator: SyncCoordinator
    private let logger = Logger(subsystem: "com.videogorl.ensemble", category: "ShareService")

    /// Directory for temporary files created during share-file-for-non-downloaded-tracks
    private static let tempShareDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EnsembleShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public init(
        songLinkService: SongLinkService,
        syncCoordinator: SyncCoordinator
    ) {
        self.songLinkService = songLinkService
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Link Sharing

    /// Prepare a shareable link payload for a track.
    /// Falls back: song.link → Apple Music URL → plain text
    public func prepareTrackLinkPayload(track: Track) async -> SharePayload {
        let fallbackText = formatTrackText(track)

        if track.isAppleMusic,
           let rawURL = track.streamKey.flatMap(URL.init(string:)) {
            let url = await songLinkService.resolveAppleMusicURL(rawURL)
            return .link(url: url, text: fallbackText)
        }

        if let url = await songLinkService.resolveTrackLink(title: track.title, artist: track.artistName) {
            return .link(url: url, text: fallbackText)
        }

        return .text(fallbackText)
    }

    /// Prepare a shareable link payload for an album.
    /// Falls back: song.link → Apple Music URL → plain text
    public func prepareAlbumLinkPayload(album: Album) async -> SharePayload {
        let fallbackText = formatAlbumText(album)

        if let url = await songLinkService.resolveAlbumLink(title: album.title, artist: album.artistName) {
            return .link(url: url, text: fallbackText)
        }

        return .text(fallbackText)
    }

    // MARK: - File Sharing

    /// Prepare a shareable audio file payload for a track.
    /// Reuses a local download when it matches the selected sharing quality, or
    /// falls back to any valid download when the track's server is offline.
    /// For non-downloaded tracks, downloads to a temp directory first.
    /// Returns nil on download failure.
    public func prepareTrackFilePayload(track: Track) async -> SharePayload? {
        guard !track.isAppleMusic else { return nil }
        let quality = StreamingQuality(
            rawValue: AudioQualityPreference.storedSharingQuality()
        ) ?? .original
        let serverState = serverState(for: track)
        let matchingLocalFileURL = Self.matchingLocalFileURL(for: track, quality: quality)
        let localFileURL = Self.localFileURL(
            for: track,
            quality: quality,
            serverState: serverState
        )
        let originalFileInfo = quality == .original && localFileURL == nil
            ? await originalFileInfo(for: track)
            : nil
        let exportMetadata = TrackFileExportMetadata(
            track: track,
            fallbackExtension: originalFileInfo?.container ?? "mp3",
            quality: quality
        )
        let title = exportMetadata.displayTitle

        // Check for existing local download — create a renamed copy so the share sheet
        // shows the human-readable filename instead of the internal storage name
        if let localFileURL {
            if matchingLocalFileURL == nil {
                logger.info("Server is offline; sharing the existing offline download")
            }
            let localExtension = localFileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = localExtension.isEmpty
                ? exportMetadata.fileName
                : "\(exportMetadata.sanitizedBaseName).\(localExtension.lowercased())"
            let renamedURL = Self.tempShareDirectory
                .appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: renamedURL)
            do {
                try FileManager.default.copyItem(at: localFileURL, to: renamedURL)
                return .file(url: renamedURL, title: title)
            } catch {
                // Fall back to sharing the original file directly
                return .file(url: localFileURL, title: title)
            }
        }

        // Download to temp directory for non-downloaded tracks
        do {
            let downloadedURL: URL
            let responseByteCount: Int?
            if quality == .original {
                let resolution = try await syncCoordinator.getStreamURL(for: track, quality: quality)
                let streamURL: URL
                switch resolution {
                case .directStream(let url), .downloadedFile(let url):
                    streamURL = url
                case .progressiveTranscode:
                    throw PlexAPIError.invalidURL
                }
                let (url, response) = try await URLSession.shared.download(from: streamURL)
                downloadedURL = url
                responseByteCount = response.expectedContentLength > 0
                    ? Int(response.expectedContentLength)
                    : nil
            } else {
                downloadedURL = try await syncCoordinator.downloadUniversalStreamToFile(
                    for: track,
                    quality: quality
                )
                responseByteCount = nil
            }
            let tempFileURL = Self.tempShareDirectory
                .appendingPathComponent(exportMetadata.fileName)

            // Clean up any previous temp file at this path
            try? FileManager.default.removeItem(at: tempFileURL)

            let actualByteCount = try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let expectedByteCount = originalFileInfo?.fileSize ?? responseByteCount
            guard Self.isCompleteAudioExport(
                actualByteCount: actualByteCount,
                expectedByteCount: expectedByteCount
            ) else {
                throw ShareFileError.incompleteDownload
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tempFileURL)

            logger.info("Downloaded track to temp for sharing: \(title)")
            return .file(url: tempFileURL, title: title)
        } catch {
            logger.error("Failed to download track for sharing: \(error.localizedDescription)")
            return nil
        }
    }

    /// Prepare a local audio file URL for external drag destinations.
    /// Uses the same renamed-temp/download behavior as the share sheet path.
    public func prepareTrackFileURL(track: Track) async -> URL? {
        guard case let .file(url, _) = await prepareTrackFilePayload(track: track) else {
            return nil
        }
        return url
    }

    /// Return a complete local download only when it matches the requested export quality.
    public nonisolated static func matchingLocalFileURL(
        for track: Track,
        quality: StreamingQuality
    ) -> URL? {
        guard let localPath = track.localFilePath,
              FileManager.default.fileExists(atPath: localPath) else {
            return nil
        }
        let localQuality = AudioQualityPreference.normalizedQuality(track.downloadedQuality)
            ?? AudioQualityPreference.fileQuality(at: URL(fileURLWithPath: localPath))
        return localQuality == quality.rawValue ? URL(fileURLWithPath: localPath) : nil
    }

    nonisolated static func localFileURL(
        for track: Track,
        quality: StreamingQuality,
        serverState: ServerConnectionState
    ) -> URL? {
        if let matchingURL = matchingLocalFileURL(for: track, quality: quality) {
            return matchingURL
        }
        guard serverState == .offline,
              let localPath = track.localFilePath,
              FileManager.default.fileExists(atPath: localPath) else {
            return nil
        }
        return URL(fileURLWithPath: localPath)
    }

    nonisolated static func isCompleteAudioExport(actualByteCount: Int, expectedByteCount: Int?) -> Bool {
        actualByteCount > 0 && expectedByteCount.map { actualByteCount >= $0 } != false
    }

    private func originalFileInfo(for track: Track) async -> AudioFileInfo? {
        do {
            return try await syncCoordinator.getAudioFileInfo(
                trackId: track.id,
                sourceKey: track.sourceCompositeKey
            )
        } catch {
            logger.debug("Couldn't load original file metadata for sharing: \(error.localizedDescription)")
            return nil
        }
    }

    private func serverState(for track: Track) -> ServerConnectionState {
        guard let source = MediaSourceIdentity.parse(track.sourceCompositeKey) else {
            return .unknown
        }
        return syncCoordinator.serverHealthChecker.getServerState(
            accountId: source.accountId,
            serverId: source.serverId
        )
    }

    // MARK: - Formatting Helpers

    private func formatTrackText(_ track: Track) -> String {
        if let artist = track.artistName {
            return "\"\(track.title)\" by \(artist)"
        }
        return "\"\(track.title)\""
    }

    private func formatAlbumText(_ album: Album) -> String {
        if let artist = album.artistName {
            return "\"\(album.title)\" by \(artist)"
        }
        return "\"\(album.title)\""
    }

}

private enum ShareFileError: Error {
    case incompleteDownload
}
