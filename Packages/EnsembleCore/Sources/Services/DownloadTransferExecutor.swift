import AVFoundation
import CoreData
import EnsembleAPI
import EnsemblePersistence
import Foundation

enum DownloadProcessingError: LocalizedError {
    case invalidHTTPStatus(Int)
    case emptyPayload(String)
    case truncatedPayload(fileDuration: Double, expectedDuration: Double)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let statusCode):
            return "Download HTTP status \(statusCode)"
        case .emptyPayload(let context):
            return "Download payload was empty for \(context)"
        case .truncatedPayload(let fileDuration, let expectedDuration):
            return "Download truncated: file is \(String(format: "%.1f", fileDuration))s but expected \(String(format: "%.1f", expectedDuration))s"
        }
    }
}

/// Transport-level error for incomplete byte transfer.
/// Separate from DownloadProcessingError because these are retryable —
/// the download should be re-queued as pending, not permanently failed.
enum DownloadTransferError: LocalizedError {
    case incompleteTransfer(bytesReceived: Int64, bytesExpected: Int64, percentComplete: Int)

    var errorDescription: String? {
        switch self {
        case .incompleteTransfer(let received, let expected, let pct):
            return "Incomplete transfer: received \(received)/\(expected) bytes (\(pct)%)"
        }
    }
}

/// Value-type snapshot of CDDownload + CDTrack properties captured before async download begins.
/// Prevents issues when viewContext.reset() invalidates managed objects mid-download
/// or when cascade deletes remove the CDDownload from the store during sync.
struct DownloadTransferContext {
    let downloadObjectID: NSManagedObjectID
    let trackRatingKey: String
    let sourceCompositeKey: String
    let trackDuration: Int64
    let downloadQuality: String?
    let domainTrack: Track
    /// sourceCompositeKey with colons replaced for safe file naming
    let safeSourceKey: String
    // For artwork caching
    let trackThumbPath: String?
    let albumRatingKey: String?
    let albumThumbPath: String?
}

struct DownloadTransferResult {
    let attemptedDirectFallback: Bool
    let persisted: Bool
}

struct DownloadTransferExecutionError: Error {
    let underlying: Error
    let attemptedDirectFallback: Bool
}

@MainActor
final class DownloadTransferExecutor {
    struct Dependencies {
        let downloadManager: DownloadManagerProtocol
        let fetchDirectDownloadURL: (Track, StreamingQuality) async throws -> URL
        let fetchOfflineDownloadQueueMedia: (Track, StreamingQuality) async throws -> (fileURL: URL, suggestedFilename: String?, mimeType: String?)
        let shouldAttemptDirectFallback: (Error, DownloadTransferContext) -> Bool
        let performDirectDownload: (URL, NSManagedObjectID, Int64) async throws -> (URL, URLResponse)
        let didComplete: (DownloadTransferContext, URL) async -> Void
        let scheduleDownloadsChanged: () -> Void
        let isStillReferenced: (DownloadTransferContext) async -> Bool
        var matchingPlaybackArtifact: (DownloadTransferContext, StreamingQuality) -> URL? = { _, _ in nil }
        var rejectPlaybackArtifact: (URL) -> Void = { _ in }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func execute(
        ctx: DownloadTransferContext,
        requestedQuality: StreamingQuality
    ) async throws -> DownloadTransferResult {
        var attemptedDirectFallback = false
        do {
            if let artifactURL = dependencies.matchingPlaybackArtifact(ctx, requestedQuality) {
                do {
                    return try await completeFromPlaybackArtifact(
                        artifactURL,
                        ctx: ctx,
                        quality: requestedQuality
                    )
                } catch {
                    dependencies.rejectPlaybackArtifact(artifactURL)
                    EnsembleLogger.debug(
                        "⚠️ Playback cache adoption failed for track=\(ctx.trackRatingKey): \(error.localizedDescription); using download transport"
                    )
                }
            }

            let sizeEstimate = Self.estimatedFileSize(durationMs: ctx.trackDuration, quality: requestedQuality)

            if requestedQuality != .original {
                do {
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(ctx.trackRatingKey) stage=download-queue quality=\(requestedQuality.rawValue)"
                    )
                    let completed = try await completeViaDownloadQueue(
                        ctx: ctx,
                        quality: requestedQuality
                    )
                    switch completed {
                    case .completed:
                        return DownloadTransferResult(attemptedDirectFallback: false, persisted: true)
                    case .skippedUnreferenced:
                        return DownloadTransferResult(attemptedDirectFallback: false, persisted: false)
                    case .emptyPayload:
                        break
                    }
                } catch {
                    if !dependencies.shouldAttemptDirectFallback(error, ctx) {
                        throw error
                    }
                    EnsembleLogger.debug(
                        "⚠️ Download queue failed for track=\(ctx.trackRatingKey): \(error.localizedDescription); falling back to direct original"
                    )
                }
            }

            let effectiveQuality: StreamingQuality = .original
            let selectedURL = try await dependencies.fetchDirectDownloadURL(ctx.domainTrack, effectiveQuality)
            let selectedMode = requestedQuality == .original ? "direct-original" : "direct-original-fallback"
            attemptedDirectFallback = requestedQuality != .original

            EnsembleLogger.debug(
                "⬇️ Offline download attempt: track=\(ctx.trackRatingKey) stage=\(selectedMode)"
            )

            let (temporaryURL, response) = try await dependencies.performDirectDownload(
                selectedURL,
                ctx.downloadObjectID,
                sizeEstimate
            )

            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            if let httpResponse = response as? HTTPURLResponse {
                EnsembleLogger.debug(
                    "⬇️ Offline download response: track=\(ctx.trackRatingKey) status=\(httpResponse.statusCode) quality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) mode=\(selectedMode)"
                )
                if let plexError = httpResponse.value(forHTTPHeaderField: "X-Plex-Error"), !plexError.isEmpty {
                    EnsembleLogger.debug("⬇️ Offline download X-Plex-Error: \(plexError)")
                }
                if !(200...299).contains(httpResponse.statusCode) {
                    if let data = try? Data(contentsOf: temporaryURL), !data.isEmpty {
                        let preview = String(decoding: data.prefix(200), as: UTF8.self)
                            .replacingOccurrences(of: "\n", with: " ")
                        EnsembleLogger.debug("⬇️ Offline download error body (preview): \(preview)")
                    }
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw DownloadProcessingError.invalidHTTPStatus(httpResponse.statusCode)
                }
            }

            let destinationURL = Self.localFileURL(
                ratingKey: ctx.trackRatingKey, safeSourceKey: ctx.safeSourceKey,
                quality: effectiveQuality, response: response
            )
            let persisted = try await install(
                temporaryURL, at: destinationURL, ctx: ctx, quality: effectiveQuality
            )
            return DownloadTransferResult(attemptedDirectFallback: attemptedDirectFallback, persisted: persisted)
        } catch {
            throw DownloadTransferExecutionError(
                underlying: error,
                attemptedDirectFallback: attemptedDirectFallback
            )
        }
    }

    private enum QueueDownloadCompletion {
        case completed
        case emptyPayload
        case skippedUnreferenced
    }

    private func completeFromPlaybackArtifact(
        _ artifactURL: URL,
        ctx: DownloadTransferContext,
        quality: StreamingQuality
    ) async throws -> DownloadTransferResult {
        guard await dependencies.isStillReferenced(ctx) else {
            return DownloadTransferResult(attemptedDirectFallback: false, persisted: false)
        }

        let destinationURL = Self.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: quality,
            suggestedFilename: artifactURL.lastPathComponent,
            mimeType: nil,
            payload: nil
        )
        let persisted = try await install(
            artifactURL, at: destinationURL, ctx: ctx, quality: quality, preserveSource: true
        )
        return DownloadTransferResult(attemptedDirectFallback: false, persisted: persisted)
    }

    private func completeViaDownloadQueue(
        ctx: DownloadTransferContext,
        quality: StreamingQuality
    ) async throws -> QueueDownloadCompletion {
        let payload = try await dependencies.fetchOfflineDownloadQueueMedia(ctx.domainTrack, quality)
        defer { try? FileManager.default.removeItem(at: payload.fileURL) }
        let handle = try FileHandle(forReadingFrom: payload.fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard !header.isEmpty else { return .emptyPayload }
        let destinationURL = Self.localFileURL(
            ratingKey: ctx.trackRatingKey, safeSourceKey: ctx.safeSourceKey, quality: quality,
            suggestedFilename: payload.suggestedFilename, mimeType: payload.mimeType, payload: header
        )
        return try await install(payload.fileURL, at: destinationURL, ctx: ctx, quality: quality)
            ? .completed : .skippedUnreferenced
    }

    /// Validate staging before replacing a playable file. Playback-cache files remain owned by their cache.
    private func install(
        _ sourceURL: URL, at destinationURL: URL, ctx: DownloadTransferContext,
        quality: StreamingQuality, preserveSource: Bool = false
    ) async throws -> Bool {
        guard await dependencies.isStillReferenced(ctx) else { return false }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).installing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        if preserveSource {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: stagingURL)
        }
        try Self.validateDownloadDuration(fileURL: stagingURL, ctx: ctx)
        let size = (try FileManager.default.attributesOfItem(atPath: stagingURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw DownloadProcessingError.emptyPayload("staged-file") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        guard try await completeDownloadIfStillReferenced(
            ctx: ctx, filePath: destinationURL.lastPathComponent, fileSize: size,
            quality: quality, fileURL: destinationURL
        ) else { return false }
        EnsembleLogger.debug("Offline download installed track=\(ctx.trackRatingKey) quality=\(quality.rawValue) bytes=\(size) playbackCache=\(preserveSource)")
        await notifyCompletion(fileURL: destinationURL, ctx: ctx)
        return true
    }

    private func completeDownloadIfStillReferenced(
        ctx: DownloadTransferContext,
        filePath: String,
        fileSize: Int64,
        quality: StreamingQuality,
        fileURL: URL
    ) async throws -> Bool {
        guard await dependencies.isStillReferenced(ctx) else {
            Self.removeLocalDownloadArtifact(fileURL)
            EnsembleLogger.debug(
                "🗑️ Skipped persisting completed download for unreferenced target: track=\(ctx.trackRatingKey)"
            )
            return false
        }

        do {
            try await dependencies.downloadManager.completeDownload(
                ctx.downloadObjectID,
                filePath: filePath,
                fileSize: fileSize,
                quality: quality.rawValue
            )
            return true
        } catch {
            guard await dependencies.isStillReferenced(ctx) else {
                Self.removeLocalDownloadArtifact(fileURL)
                EnsembleLogger.debug(
                    "🗑️ Skipped recovery for unreferenced completed download: track=\(ctx.trackRatingKey)"
                )
                return false
            }

            EnsembleLogger.debug(
                "⚠️ completeDownload(\(ctx.trackRatingKey)) objectID not found: \(error.localizedDescription); attempting recovery"
            )
            let recovered = try await dependencies.downloadManager.createDownload(
                forTrackRatingKey: ctx.trackRatingKey,
                sourceCompositeKey: ctx.sourceCompositeKey,
                quality: quality.rawValue
            )
            try await dependencies.downloadManager.completeDownload(
                recovered.objectID,
                filePath: filePath,
                fileSize: fileSize,
                quality: quality.rawValue
            )
            EnsembleLogger.debug("✅ Download recovery successful for track=\(ctx.trackRatingKey)")
            return true
        }
    }

    private func notifyCompletion(fileURL: URL, ctx: DownloadTransferContext) async {
        dependencies.scheduleDownloadsChanged()
        await dependencies.didComplete(ctx, fileURL)
    }

    /// Downloads a URL to a temporary file while periodically reporting progress to CoreData.
    /// Retains validated partial transfers through the shared HTTP download transport.
    /// Falls back to `estimatedSize` when Content-Length is absent (common for transcode streams).
    /// Progress is throttled to ~1 update/second to avoid excessive CoreData writes.
    /// The nonisolated API transport owns execution; cancellation follows the worker task.
    static func downloadWithProgress(
        from url: URL,
        downloadID: NSManagedObjectID,
        estimatedSize: Int64 = -1,
        downloadManager: DownloadManagerProtocol,
        networkPolicy: DownloadNetworkPolicy
    ) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        networkPolicy.apply(to: &request)
        return try await ResumableDownload.file(
            for: request, identity: downloadID.uriRepresentation().absoluteString
        ) { received, expected in
            let total = expected > 0 ? expected : estimatedSize
            if total > 0 {
                try? await downloadManager.updateDownloadProgress(
                    downloadID, progress: min(Float(received) / Float(total), 0.99)
                )
            }
        }
    }

    /// Estimates file size in bytes for a track at a given quality based on duration and bitrate.
    /// Returns -1 for original quality since the original file size is unknown.
    static func estimatedFileSize(durationMs: Int64, quality: StreamingQuality) -> Int64 {
        guard quality != .original else { return -1 }
        let durationSeconds = Double(durationMs) / 1000.0
        let bitrateKbps: Double
        switch quality {
        case .high: bitrateKbps = 320
        case .medium: bitrateKbps = 192
        case .low: bitrateKbps = 128
        case .original: return -1
        }
        return Int64(durationSeconds * bitrateKbps * 1000.0 / 8.0)
    }

    /// Validate that a downloaded audio file's duration is consistent with the track's metadata.
    /// Catches truncated downloads from interrupted connections or server-side errors.
    private static func validateDownloadDuration(
        fileURL: URL,
        ctx: DownloadTransferContext
    ) throws {
        let expectedDurationMs = ctx.trackDuration
        guard expectedDurationMs > 10_000 else { return }
        let expectedSeconds = Double(expectedDurationMs) / 1000.0

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return }
            let fileDuration = Double(audioFile.length) / sampleRate

            if fileDuration < expectedSeconds * 0.5 && fileDuration < expectedSeconds - 10 {
                EnsembleLogger.debug(
                    "⚠️ Truncated download for track=\(ctx.trackRatingKey): file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedSeconds))s — rejecting"
                )
                throw DownloadProcessingError.truncatedPayload(
                    fileDuration: fileDuration,
                    expectedDuration: expectedSeconds
                )
            }
        } catch let error as DownloadProcessingError {
            throw error
        } catch {
            EnsembleLogger.debug(
                "⚠️ Could not validate download duration for track=\(ctx.trackRatingKey): \(error.localizedDescription)"
            )
        }
    }

    static func localFileURL(
        ratingKey: String,
        safeSourceKey: String,
        quality: StreamingQuality,
        response: URLResponse
    ) -> URL {
        let responseExtension = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = responseExtension?.isEmpty == false
            ? responseExtension!
            : inferredFileExtension(
                mimeType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                payload: nil
            )
        let fileName = "\(ratingKey)_\(safeSourceKey)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func localFileURL(
        ratingKey: String,
        safeSourceKey: String,
        quality: StreamingQuality,
        suggestedFilename: String?,
        mimeType: String?,
        payload: Data?
    ) -> URL {
        let suggestedExtension = suggestedFilename
            .flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = suggestedExtension?.isEmpty == false
            ? suggestedExtension!
            : inferredFileExtension(mimeType: mimeType, payload: payload)
        let fileName = "\(ratingKey)_\(safeSourceKey)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func removeLocalDownloadArtifact(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("freq"))
    }

    static func inferredFileExtension(mimeType: String?, payload: Data?) -> String {
        if let mimeType {
            let normalized = mimeType.lowercased()
            if normalized.contains("mpeg") || normalized.contains("mp3") {
                return "mp3"
            }
            if normalized.contains("mp4") || normalized.contains("m4a") {
                return "m4a"
            }
            if normalized.contains("aac") {
                return "aac"
            }
            if normalized.contains("flac") {
                return "flac"
            }
        }

        guard let payload, payload.count >= 4 else {
            return "m4a"
        }

        if payload.starts(with: [0x49, 0x44, 0x33]) {
            return "mp3"
        }
        if payload.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return "flac"
        }
        if payload.starts(with: [0xFF, 0xFB]) || payload.starts(with: [0xFF, 0xF3]) || payload.starts(with: [0xFF, 0xF2]) {
            return "mp3"
        }
        if payload.count >= 12 {
            let ftypMarker = Data([0x66, 0x74, 0x79, 0x70])
            if payload.subdata(in: 4..<8) == ftypMarker {
                return "m4a"
            }
        }

        return "m4a"
    }
}
