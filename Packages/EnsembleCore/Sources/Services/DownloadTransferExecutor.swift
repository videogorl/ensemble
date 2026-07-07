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
        let fetchOfflineDownloadQueueMedia: (Track, StreamingQuality) async throws -> (data: Data, suggestedFilename: String?, mimeType: String?)
        let shouldAttemptDirectFallback: (Error, DownloadTransferContext) -> Bool
        let performDirectDownload: (URL, NSManagedObjectID, Int64) async throws -> (URL, URLResponse)
        let fetchArtworkURL: (String, String, Int) async throws -> URL?
        let artworkDownloadManager: ArtworkDownloadManagerProtocol
        let fetchAndCacheLyrics: @Sendable (String, String?) async -> Void
        let enqueueSidecarAnalysis: (URL, URL) async -> Void
        let scheduleDownloadsChanged: () -> Void
        let isStillReferenced: (DownloadTransferContext) async -> Bool
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
            let sizeEstimate = Self.estimatedFileSize(durationMs: ctx.trackDuration, quality: requestedQuality)
            var effectiveQuality = requestedQuality

            if requestedQuality != .original {
                do {
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(ctx.trackRatingKey) stage=download-queue quality=\(requestedQuality.rawValue)"
                    )
                    let completed = try await completeViaDownloadQueue(
                        ctx: ctx,
                        quality: requestedQuality,
                        mode: "download-queue"
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
                    effectiveQuality = .original
                }
            }

            let selectedURL = try await dependencies.fetchDirectDownloadURL(ctx.domainTrack, .original)
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

            let temporaryAttributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let temporaryFileSize = (temporaryAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard temporaryFileSize > 0 else {
                throw DownloadProcessingError.emptyPayload(selectedMode)
            }

            let destinationURL = Self.localFileURL(
                ratingKey: ctx.trackRatingKey,
                safeSourceKey: ctx.safeSourceKey,
                quality: effectiveQuality,
                response: response
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

            let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let destinationFileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let persistedFileSize = max(temporaryFileSize, destinationFileSize)
            guard persistedFileSize > 0 else {
                throw DownloadProcessingError.emptyPayload(selectedMode)
            }

            // Diagnostic: log Content-Type and file magic bytes to verify transcode actually happened
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            var magicBytesHex = "?"
            if let handle = FileHandle(forReadingAtPath: destinationURL.path),
               let header = try? handle.read(upToCount: 12) {
                magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
                try? handle.close()
            }
            EnsembleLogger.debug(
                "✅ Offline download stored: track=\(ctx.trackRatingKey) path=\(destinationURL.lastPathComponent) size=\(persistedFileSize) mode=\(selectedMode) contentType=\(contentType) requestedQuality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) magic=\(magicBytesHex)"
            )

            try Self.validateDownloadDuration(fileURL: destinationURL, ctx: ctx)
            let persisted = try await completeDownloadIfStillReferenced(
                ctx: ctx,
                filePath: destinationURL.lastPathComponent,
                fileSize: persistedFileSize,
                quality: effectiveQuality,
                fileURL: destinationURL
            )
            guard persisted else {
                return DownloadTransferResult(attemptedDirectFallback: attemptedDirectFallback, persisted: false)
            }
            await runPostCompletionWork(fileURL: destinationURL, ctx: ctx)

            return DownloadTransferResult(attemptedDirectFallback: attemptedDirectFallback, persisted: true)
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

    private func completeViaDownloadQueue(
        ctx: DownloadTransferContext,
        quality: StreamingQuality,
        mode: String
    ) async throws -> QueueDownloadCompletion {
        let queuePayload = try await dependencies.fetchOfflineDownloadQueueMedia(ctx.domainTrack, quality)
        guard !queuePayload.data.isEmpty else {
            return .emptyPayload
        }

        let destinationURL = Self.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: quality,
            suggestedFilename: queuePayload.suggestedFilename,
            mimeType: queuePayload.mimeType,
            payload: queuePayload.data
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try queuePayload.data.write(to: destinationURL, options: [.atomic])

        let queueAttributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let queueFileSize = (queueAttributes?[.size] as? NSNumber)?.int64Value ?? Int64(queuePayload.data.count)
        guard queueFileSize > 0 else {
            return .emptyPayload
        }

        var magicBytesHex = "?"
        if let handle = FileHandle(forReadingAtPath: destinationURL.path),
           let header = try? handle.read(upToCount: 12) {
            magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            try? handle.close()
        }
        EnsembleLogger.debug(
            "✅ Offline download stored: track=\(ctx.trackRatingKey) path=\(destinationURL.lastPathComponent) size=\(queueFileSize) mode=\(mode) contentType=\(queuePayload.mimeType ?? "unknown") magic=\(magicBytesHex)"
        )

        try Self.validateDownloadDuration(fileURL: destinationURL, ctx: ctx)
        let persisted = try await completeDownloadIfStillReferenced(
            ctx: ctx,
            filePath: destinationURL.lastPathComponent,
            fileSize: queueFileSize,
            quality: quality,
            fileURL: destinationURL
        )
        guard persisted else {
            return .skippedUnreferenced
        }
        await runPostCompletionWork(fileURL: destinationURL, ctx: ctx)
        return .completed
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

    private func runPostCompletionWork(fileURL: URL, ctx: DownloadTransferContext) async {
        await cacheArtworkForDownloadedTrack(ctx: ctx)

        let sidecarURL = fileURL.appendingPathExtension("freq")
        await dependencies.enqueueSidecarAnalysis(fileURL, sidecarURL)

        let trackRatingKey = ctx.trackRatingKey
        let sourceCompositeKey = ctx.sourceCompositeKey
        let fetchAndCacheLyrics = dependencies.fetchAndCacheLyrics
        Task(priority: .utility) {
            await fetchAndCacheLyrics(trackRatingKey, sourceCompositeKey)
        }

        dependencies.scheduleDownloadsChanged()
    }

    /// Best-effort artwork caching for newly downloaded tracks so offline lists/details keep artwork.
    private func cacheArtworkForDownloadedTrack(ctx: DownloadTransferContext) async {
        var candidates: [(ratingKey: String, path: String)] = []
        if let path = ctx.trackThumbPath, !path.isEmpty {
            candidates.append((ctx.trackRatingKey, path))
        }
        if let albumRatingKey = ctx.albumRatingKey,
           let albumThumbPath = ctx.albumThumbPath,
           !albumThumbPath.isEmpty {
            candidates.append((albumRatingKey, albumThumbPath))
        }

        guard !candidates.isEmpty else { return }

        var seen = Set<String>()
        for candidate in candidates {
            let dedupeKey = "\(candidate.ratingKey)|\(candidate.path)"
            guard seen.insert(dedupeKey).inserted else { continue }

            if let cachedArtworkPath = try? await dependencies.artworkDownloadManager.getLocalArtworkPath(
                ratingKey: candidate.ratingKey,
                type: .album,
                sourcePath: candidate.path,
                dateModifiedSeconds: nil
            ), FileManager.default.fileExists(atPath: cachedArtworkPath) {
                continue
            }

            do {
                guard let artworkURL = try await dependencies.fetchArtworkURL(
                    candidate.path,
                    ctx.sourceCompositeKey,
                    500
                ) else {
                    continue
                }

                try await dependencies.artworkDownloadManager.downloadAndCacheArtwork(
                    from: artworkURL,
                    identity: ArtworkIdentity(
                        ratingKey: candidate.ratingKey,
                        type: .album,
                        sourcePath: candidate.path,
                        dateModifiedSeconds: nil
                    )
                )

                EnsembleLogger.debug(
                    "🖼️ Cached artwork for downloaded track: track=\(ctx.trackRatingKey) artworkKey=\(candidate.ratingKey)"
                )
            } catch {
                EnsembleLogger.debug(
                    "⚠️ Failed caching artwork for downloaded track \(ctx.trackRatingKey): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Downloads a URL to a temporary file while periodically reporting progress to CoreData.
    /// Uses URLSession.bytes(from:) to stream data and compare bytes received against Content-Length.
    /// Falls back to `estimatedSize` when Content-Length is absent (common for transcode streams).
    /// Progress is throttled to ~1 update/second to avoid excessive CoreData writes.
    /// Runs the byte-streaming loop off the main actor so UI updates aren't blocked.
    static func downloadWithProgress(
        from url: URL,
        downloadID: NSManagedObjectID,
        estimatedSize: Int64 = -1,
        downloadManager: DownloadManagerProtocol
    ) async throws -> (URL, URLResponse) {
        let dm = downloadManager
        let estimate = estimatedSize

        let detachedTask = Task.detached(priority: .utility) { [dm] () -> (URL, URLResponse) in
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
            let totalExpected = response.expectedContentLength > 0
                ? response.expectedContentLength
                : estimate

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)

            do {
                let fileHandle = try FileHandle(forWritingTo: tempURL)

                var bytesReceived: Int64 = 0
                var buffer = Data()
                let flushThreshold = 65_536 // 64KB chunks
                var lastProgressUpdate = Date.distantPast
                let progressInterval: TimeInterval = 1.0

                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    buffer.append(byte)

                    if buffer.count >= flushThreshold {
                        try fileHandle.write(contentsOf: buffer)
                        bytesReceived += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)

                        if totalExpected > 0 {
                            let now = Date()
                            if now.timeIntervalSince(lastProgressUpdate) >= progressInterval {
                                let progress = min(Float(bytesReceived) / Float(totalExpected), 0.99)
                                try? await dm.updateDownloadProgress(downloadID, progress: progress)
                                lastProgressUpdate = now
                            }
                        }
                    }
                }

                if !buffer.isEmpty {
                    bytesReceived += Int64(buffer.count)
                    try fileHandle.write(contentsOf: buffer)
                }
                try fileHandle.close()

                let expectedLength = response.expectedContentLength
                if expectedLength > 0 {
                    if bytesReceived < expectedLength {
                        let pctReceived = Int(Double(bytesReceived) / Double(expectedLength) * 100)
                        EnsembleLogger.debug(
                            "⚠️ Download incomplete: received \(bytesReceived)/\(expectedLength) bytes (\(pctReceived)%)"
                        )
                        try? FileManager.default.removeItem(at: tempURL)
                        throw DownloadTransferError.incompleteTransfer(
                            bytesReceived: bytesReceived,
                            bytesExpected: expectedLength,
                            percentComplete: pctReceived
                        )
                    }
                } else if estimate > 0, bytesReceived < estimate / 2 {
                    let pctOfEstimate = Int(Double(bytesReceived) / Double(estimate) * 100)
                    EnsembleLogger.debug(
                        "⚠️ Download suspiciously short: received \(bytesReceived) bytes vs ~\(estimate) estimated (\(pctOfEstimate)%)"
                    )
                }

                return (tempURL, response)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        return try await withTaskCancellationHandler {
            try await detachedTask.value
        } onCancel: {
            detachedTask.cancel()
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
    static func validateDownloadDuration(
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
                try? FileManager.default.removeItem(at: fileURL)
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
