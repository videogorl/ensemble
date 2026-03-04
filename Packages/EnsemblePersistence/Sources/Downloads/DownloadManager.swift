import CoreData
import Foundation

public enum DownloadError: Error, LocalizedError {
    case trackNotFound
    case downloadFailed(Error)
    case fileSystemError(Error)
    case noStreamURL

    public var errorDescription: String? {
        switch self {
        case .trackNotFound:
            return "Track not found"
        case .downloadFailed(let error):
            return "Download failed: \(error.localizedDescription)"
        case .fileSystemError(let error):
            return "File system error: \(error.localizedDescription)"
        case .noStreamURL:
            return "No stream URL available"
        }
    }
}

public protocol DownloadManagerProtocol: Sendable {
    func fetchDownloads() async throws -> [CDDownload]
    func fetchPendingDownloads() async throws -> [CDDownload]
    /// Atomically claim the next pending download by setting its status to `.downloading`.
    /// Returns nil when no pending downloads remain.
    func fetchNextPendingDownload() async throws -> CDDownload?
    func fetchCompletedDownloads() async throws -> [CDDownload]
    func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload?

    func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload
    func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?, quality: String) async throws -> CDDownload

    func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws
    func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status) async throws
    func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws

    func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws
    func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws

    func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws
    func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws

    func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String?
    func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> String?

    func getTotalDownloadSize() async throws -> Int64
}

public final class DownloadManager: DownloadManagerProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Directory for storing downloaded tracks
    public static var downloadsDirectory: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsURL = documentsURL.appendingPathComponent("Downloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: downloadsURL.path) {
            try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        }

        return downloadsURL
    }

    public func fetchDownloads() async throws -> [CDDownload] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
                do {
                    let downloads = try context.fetch(request)

                    // Self-heal metadata drift for completed downloads:
                    // - backfill missing track.localFilePath from download.filePath
                    // - backfill fileSize from on-disk file
                    // - mark completed items as failed when file is missing on disk
                    var healedPathCount = 0
                    var healedSizeCount = 0
                    var missingFileCount = 0
                    var invalidFileCount = 0
                    var recoveredFailedCount = 0

                    for download in downloads {
                        guard let originalFilePath = download.filePath, !originalFilePath.isEmpty else {
                            continue
                        }

                        let resolvedFilePath = Self.resolveExistingDownloadedFilePath(originalFilePath) ?? originalFilePath
                        if resolvedFilePath != originalFilePath {
                            download.filePath = resolvedFilePath
                            healedPathCount += 1
                        }

                        let fileExists = FileManager.default.fileExists(atPath: resolvedFilePath)
                        let isCompleted = download.downloadStatus == .completed
                        let isFailed = download.downloadStatus == .failed

                        if fileExists {
                            if Self.isClearlyInvalidDownloadedPayload(atPath: resolvedFilePath) {
                                download.downloadStatus = .failed
                                download.error = "Downloaded file is invalid"
                                download.progress = 0
                                if download.track?.localFilePath == resolvedFilePath {
                                    download.track?.localFilePath = nil
                                }
                                invalidFileCount += 1
                                continue
                            }

                            // Recover failed records that already have a valid payload on disk.
                            if isFailed {
                                download.downloadStatus = .completed
                                download.error = nil
                                download.progress = 1
                                if download.completedAt == nil {
                                    download.completedAt = Date()
                                }
                                recoveredFailedCount += 1
                            }

                            if download.track?.localFilePath != resolvedFilePath {
                                download.track?.localFilePath = resolvedFilePath
                                healedPathCount += 1
                            }

                            if download.fileSize <= 0,
                               let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedFilePath),
                               let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
                               actualSize > 0 {
                                download.fileSize = actualSize
                                healedSizeCount += 1
                            }
                        } else if isCompleted {
                            download.downloadStatus = .failed
                            download.error = "Downloaded file missing on disk"
                            download.progress = 0
                            if download.track?.localFilePath == resolvedFilePath {
                                download.track?.localFilePath = nil
                            }
                            missingFileCount += 1
                        }
                    }

                    if context.hasChanges {
                        try context.save()
                        #if DEBUG
                        EnsembleLogger.debug(
                            "🧰 DownloadManager healed download metadata (path=\(healedPathCount), size=\(healedSizeCount), missing=\(missingFileCount), invalid=\(invalidFileCount), recoveredFailed=\(recoveredFailedCount))"
                        )
                        #endif
                    }

                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchPendingDownloads() async throws -> [CDDownload] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(
                    format: "status == %@ OR status == %@",
                    CDDownload.Status.pending.rawValue,
                    CDDownload.Status.downloading.rawValue
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
                do {
                    let downloads = try context.fetch(request)
                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchNextPendingDownload() async throws -> CDDownload? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(
                    format: "status == %@",
                    CDDownload.Status.pending.rawValue
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: true)]
                request.fetchLimit = 1
                do {
                    guard let download = try context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Claim it so other workers don't pick the same one
                    download.status = CDDownload.Status.downloading.rawValue
                    try context.save()
                    continuation.resume(returning: download)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchCompletedDownloads() async throws -> [CDDownload] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(format: "status == %@", CDDownload.Status.completed.rawValue)
                request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
                do {
                    let downloads = try context.fetch(request)
                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = Self.downloadPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

                do {
                    let download = try context.fetch(request).first
                    continuation.resume(returning: download)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload {
        try await createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: nil,
            quality: "original"
        )
    }

    public func createDownload(
        forTrackRatingKey trackRatingKey: String,
        sourceCompositeKey: String?,
        quality: String
    ) async throws -> CDDownload {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let trackRequest = CDTrack.fetchRequest()
                trackRequest.predicate = Self.trackPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )
                trackRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

                do {
                    guard let track = try context.fetch(trackRequest).first else {
                        continuation.resume(throwing: DownloadError.trackNotFound)
                        return
                    }

                    let downloadRequest = CDDownload.fetchRequest()
                    downloadRequest.predicate = Self.downloadPredicate(
                        trackRatingKey: trackRatingKey,
                        sourceCompositeKey: sourceCompositeKey
                    )
                    downloadRequest.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

                    if let existing = try context.fetch(downloadRequest).first {
                        let normalizedQuality = Self.normalizedQuality(quality)
                        if existing.quality != normalizedQuality {
                            // Keep the old file and localFilePath intact so the track remains
                            // playable at old quality while the new download proceeds.
                            // completeDownload() will update paths and clean up the old file.
                            existing.quality = normalizedQuality
                            existing.progress = 0
                            existing.error = nil
                            existing.completedAt = nil
                            existing.status = CDDownload.Status.pending.rawValue
                            existing.startedAt = Date()
                            try context.save()
                        }

                        let existingObjectID = existing.objectID
                        let mainContext = self.coreDataStack.viewContext
                        mainContext.perform {
                            if let mainDownload = try? mainContext.existingObject(with: existingObjectID) as? CDDownload {
                                continuation.resume(returning: mainDownload)
                            } else {
                                continuation.resume(throwing: DownloadError.trackNotFound)
                            }
                        }
                        return
                    }

                    let download = CDDownload(context: context)
                    download.status = CDDownload.Status.pending.rawValue
                    download.progress = 0
                    download.startedAt = Date()
                    download.quality = Self.normalizedQuality(quality)
                    download.track = track

                    try context.save()

                    let downloadObjectID = download.objectID
                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        if let mainDownload = try? mainContext.existingObject(with: downloadObjectID) as? CDDownload {
                            continuation.resume(returning: mainDownload)
                        } else {
                            continuation.resume(throwing: DownloadError.trackNotFound)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }
                    download.progress = progress
                    download.status = CDDownload.Status.downloading.rawValue
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }
                    download.status = status.rawValue
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {
        let fromRawValues = statuses.map(\.rawValue)
        guard !fromRawValues.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDDownload.fetchRequest()
                    request.predicate = NSPredicate(format: "status IN %@", fromRawValues)
                    let downloads = try context.fetch(request)
                    for download in downloads {
                        download.status = status.rawValue
                    }
                    if !downloads.isEmpty {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func completeDownload(
        _ downloadId: NSManagedObjectID,
        filePath: String,
        fileSize: Int64,
        quality: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }

                    // If the previous download had a different file path (e.g. quality re-queue),
                    // clean up the old file now that the new one is ready.
                    if let oldPath = download.filePath, !oldPath.isEmpty, oldPath != filePath {
                        try? FileManager.default.removeItem(atPath: oldPath)
                    }

                    download.status = CDDownload.Status.completed.rawValue
                    download.progress = 1.0
                    download.filePath = filePath
                    download.fileSize = fileSize
                    download.completedAt = Date()
                    if let quality, !quality.isEmpty {
                        download.quality = Self.normalizedQuality(quality)
                    }

                    // Update track local path for offline playback routing.
                    download.track?.localFilePath = filePath

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }
                    download.status = CDDownload.Status.failed.rawValue
                    download.error = error
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws {
        try await deleteDownload(forTrackRatingKey: trackRatingKey, sourceCompositeKey: nil)
    }

    public func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDDownload.fetchRequest()
                request.predicate = Self.downloadPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )

                do {
                    if let download = try context.fetch(request).first {
                        if let filePath = download.filePath {
                            try? FileManager.default.removeItem(atPath: filePath)
                        }

                        download.track?.localFilePath = nil
                        context.delete(download)
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String? {
        try await getLocalFilePath(forTrackRatingKey: trackRatingKey, sourceCompositeKey: nil)
    }

    public func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = Self.trackPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )
                request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

                do {
                    let track = try context.fetch(request).first
                    continuation.resume(returning: track?.localFilePath)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func getTotalDownloadSize() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(format: "status == %@", CDDownload.Status.completed.rawValue)

                do {
                    let downloads = try context.fetch(request)
                    let totalSize = downloads.reduce(0) { $0 + $1.fileSize }
                    continuation.resume(returning: totalSize)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func isClearlyInvalidDownloadedPayload(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), !header.isEmpty else {
            return true
        }

        let leadingText = String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<?xml")
            || leadingText.contains("<h1>400 bad request</h1>")
            || leadingText.contains("<h1>404 not found</h1>")
    }

    private static func normalizedQuality(_ quality: String) -> String {
        switch quality {
        case "original", "high", "medium", "low":
            return quality
        default:
            return "original"
        }
    }

    /// Resolve legacy/stale download paths to an existing local file path when possible.
    /// This repairs records that kept an outdated absolute sandbox path.
    private static func resolveExistingDownloadedFilePath(_ storedPath: String) -> String? {
        let normalizedStoredPath: String
        if storedPath.hasPrefix("file://"), let url = URL(string: storedPath), !url.path.isEmpty {
            normalizedStoredPath = url.path
        } else {
            normalizedStoredPath = storedPath
        }

        if FileManager.default.fileExists(atPath: normalizedStoredPath) {
            return normalizedStoredPath
        }

        let fileName = URL(fileURLWithPath: normalizedStoredPath).lastPathComponent
        guard !fileName.isEmpty else { return nil }

        let fallbackPath = downloadsDirectory.appendingPathComponent(fileName, isDirectory: false).path
        if FileManager.default.fileExists(atPath: fallbackPath) {
            return fallbackPath
        }

        return nil
    }

    private static func downloadPredicate(trackRatingKey: String, sourceCompositeKey: String?) -> NSPredicate {
        if let sourceCompositeKey {
            return NSPredicate(
                format: "track.ratingKey == %@ AND track.sourceCompositeKey == %@",
                trackRatingKey,
                sourceCompositeKey
            )
        }
        return NSPredicate(format: "track.ratingKey == %@", trackRatingKey)
    }

    private static func trackPredicate(trackRatingKey: String, sourceCompositeKey: String?) -> NSPredicate {
        if let sourceCompositeKey {
            return NSPredicate(
                format: "ratingKey == %@ AND sourceCompositeKey == %@",
                trackRatingKey,
                sourceCompositeKey
            )
        }
        return NSPredicate(format: "ratingKey == %@", trackRatingKey)
    }
}
