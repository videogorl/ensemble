import CoreData
import EnsembleSupport
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
    func repairDownloads() async throws
    func countDownloads() async throws -> Int
    func fetchPendingDownloads() async throws -> [CDDownload]
    func countPendingDownloads() async throws -> Int
    /// Atomically claim the next pending download by setting its status to `.downloading`.
    /// Returns nil when no pending downloads remain.
    func fetchNextPendingDownload() async throws -> CDDownload?
    func fetchCompletedDownloads() async throws -> [CDDownload]
    func countCompletedDownloads() async throws -> Int
    func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload?
    /// Batch fetch downloads for multiple tracks in a single CoreData query.
    /// Returns a dictionary keyed by "sourceCompositeKey|ratingKey" for O(1) lookup.
    func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDDownload]
    /// Fetch all downloads whose track belongs to the given library (by sourceCompositeKey)
    func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload]
    func countDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> Int

    func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String, quality: String) async throws -> CDDownload

    /// Batch-create download records for multiple tracks in a single CoreData save.
    /// Returns the number of newly created pending downloads.
    func batchCreateDownloads(
        references: [OfflineTrackReference],
        quality: String
    ) async throws -> Int

    func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws
    func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws
    /// Re-queue an existing download at the requested quality while preserving any
    /// completed file until the replacement download finishes.
    func requeueDownload(_ downloadId: NSManagedObjectID, quality: String) async throws
    func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws

    func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws
    func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws

    func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws
    /// Delete source-scoped download records and files in bounded background batches.
    func deleteDownloads(forReferences references: [OfflineTrackReference]) async throws

    func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> String?

    func getTotalDownloadSize() async throws -> Int64

    /// Delete all download records for a given source, removing files on disk.
    func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws

    /// Delete all download records and their associated files on disk.
    func deleteAllDownloads() async throws

    /// Remove files in the downloads directory that are no longer referenced by
    /// any download record, including orphaned sidecar files.
    func removeOrphanedDownloadFiles() async throws -> Int
}

// Convenience defaults for lightweight protocol conformers.
public extension DownloadManagerProtocol {
    func repairDownloads() async throws {
        _ = try await fetchDownloads()
    }

    func countDownloads() async throws -> Int {
        try await fetchDownloads().count
    }

    func countPendingDownloads() async throws -> Int {
        try await fetchPendingDownloads().count
    }

    func countCompletedDownloads() async throws -> Int {
        try await fetchCompletedDownloads().count
    }

    func countDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> Int {
        try await fetchDownloads(forSourceCompositeKey: sourceCompositeKey).count
    }

    func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status) async throws {
        try await updateDownloadStatus(downloadId, status: status, quality: nil)
    }

    func requeueDownload(_ downloadId: NSManagedObjectID, quality: String) async throws {
        try await updateDownloadStatus(downloadId, status: .pending, quality: quality)
    }

    func deleteDownloads(forReferences references: [OfflineTrackReference]) async throws {
        for reference in references {
            try await deleteDownload(
                forTrackRatingKey: reference.trackRatingKey,
                sourceCompositeKey: reference.trackSourceCompositeKey
            )
        }
    }

    func removeOrphanedDownloadFiles() async throws -> Int { 0 }
}

public final class DownloadManager: DownloadManagerProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let creationContext: NSManagedObjectContext

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
        self.creationContext = coreDataStack.newBackgroundContext()
    }

    /// Directory for storing downloaded tracks
    public static let downloadsDirectory: URL = {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsURL = documentsURL.appendingPathComponent("Downloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: downloadsURL.path) {
            try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        }

        do {
            try (downloadsURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        } catch {
            EnsembleLogger.debug("Failed to exclude offline downloads from backup: \(error.localizedDescription)")
        }

        return downloadsURL
    }()

    public func repairDownloads() async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDDownload.fetchRequest()
            request.fetchBatchSize = 50
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
            let existingDownloadFilenames = Self.existingDownloadFilenames()

            for download in downloads {
                guard let storedPath = download.filePath, !storedPath.isEmpty else {
                    continue
                }

                // Migrate legacy absolute paths to filename-only storage.
                let filename = Self.extractFilename(from: storedPath)
                if filename != storedPath {
                    download.filePath = filename
                    healedPathCount += 1
                }

                let absolutePath = Self.absolutePath(forFilename: filename)
                let fileExists = existingDownloadFilenames.contains(filename)
                let isCompleted = download.downloadStatus == .completed
                let isFailed = download.downloadStatus == .failed

                if fileExists {
                    if Self.isClearlyInvalidDownloadedPayload(atPath: absolutePath) {
                        download.downloadStatus = .failed
                        download.error = "Downloaded file is invalid"
                        download.progress = 0
                        download.track?.localFilePath = nil
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

                    // Keep track.localFilePath in sync (filename only).
                    if download.track?.localFilePath != filename {
                        download.track?.localFilePath = filename
                        healedPathCount += 1
                    }

                    if download.fileSize <= 0,
                       let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath),
                       let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
                       actualSize > 0 {
                        download.fileSize = actualSize
                        healedSizeCount += 1
                    }
                } else if isCompleted {
                    download.downloadStatus = .failed
                    download.error = "Downloaded file missing on disk"
                    download.progress = 0
                    download.track?.localFilePath = nil
                    missingFileCount += 1
                }
            }

            if context.hasChanges {
                try context.save()
                EnsembleLogger.debug(
                    "🧰 DownloadManager healed download metadata (path=\(healedPathCount), size=\(healedSizeCount), missing=\(missingFileCount), invalid=\(invalidFileCount), recoveredFailed=\(recoveredFailedCount))"
                )
            }
        }
    }

    public func fetchDownloads() async throws -> [CDDownload] {
        return try await coreDataStack.performViewContext { context in
            let request = CDDownload.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
            request.fetchBatchSize = 50
            return try context.fetch(request)
        }
    }

    public func countDownloads() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                do {
                    continuation.resume(returning: try context.count(for: request))
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
                request.fetchBatchSize = 50
                do {
                    let downloads = try context.fetch(request)
                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countPendingDownloads() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(
                    format: "status == %@ OR status == %@",
                    CDDownload.Status.pending.rawValue,
                    CDDownload.Status.downloading.rawValue
                )
                do {
                    continuation.resume(returning: try context.count(for: request))
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
                request.fetchBatchSize = 50
                do {
                    let downloads = try context.fetch(request)
                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countCompletedDownloads() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(format: "status == %@", CDDownload.Status.completed.rawValue)
                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload? {
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

    public func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDDownload] {
        guard !references.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    // Fetch all downloads whose track ratingKey is in the reference set
                    let ratingKeys = Array(Set(references.map(\.trackRatingKey)))
                    let request = CDDownload.fetchRequest()
                    request.predicate = NSPredicate(format: "track.ratingKey IN %@", ratingKeys)
                    request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]

                    let downloads = try context.fetch(request)

                    let requestedKeys = Set(references.map(\.membershipID))

                    // Index by "sourceCompositeKey|ratingKey" for O(1) lookup
                    var result: [String: CDDownload] = [:]
                    result.reserveCapacity(min(downloads.count, requestedKeys.count))
                    for download in downloads {
                        guard let track = download.track else { continue }
                        let key = "\(track.sourceCompositeKey ?? "")|\(track.ratingKey)"
                        guard requestedKeys.contains(key), result[key] == nil else { continue }
                        result[key] = download
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(
                    format: "track.sourceCompositeKey == %@",
                    sourceCompositeKey
                )
                request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
                do {
                    let downloads = try context.fetch(request)
                    continuation.resume(returning: downloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(
                    format: "track.sourceCompositeKey == %@",
                    sourceCompositeKey
                )
                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func createDownload(
        forTrackRatingKey trackRatingKey: String,
        sourceCompositeKey: String,
        quality: String
    ) async throws -> CDDownload {
        try await withCheckedThrowingContinuation { continuation in
            creationContext.perform {
                let context = self.creationContext
                let trackRequest = CDTrack.fetchRequest()
                trackRequest.predicate = Self.trackPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )
                trackRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

                do {
                    guard let track = try context.fetch(trackRequest).first else {
                        context.reset()
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
                        let existingQuality = existing.quality ?? "original"

                        // Only re-queue if the existing quality is LOWER than desired.
                        // original > high > medium > low — a fallback to "original"
                        // satisfies any lower quality request and should not re-trigger.
                        if !Self.qualitySatisfies(existing: existingQuality, desired: normalizedQuality) {
                            // Keep the old file and localFilePath intact so the track remains
                            // playable at old quality while the new download proceeds.
                            // completeDownload() will update paths and clean up the old file.
                            EnsembleLogger.debug(
                                "📥 createDownload: quality upgrade needed for track=\(trackRatingKey) existing=\(existingQuality) desired=\(normalizedQuality) status=\(existing.status ?? "nil") filePath=\(existing.filePath ?? "nil") — resetting to pending"
                            )
                            existing.quality = normalizedQuality
                            existing.progress = 0
                            existing.error = nil
                            existing.completedAt = nil
                            existing.status = CDDownload.Status.pending.rawValue
                            existing.startedAt = Date()
                            try context.save()
                        }

                        let existingObjectID = existing.objectID
                        context.reset()
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

                    // No CDDownload exists for this track — create a new pending record
                    EnsembleLogger.debug(
                        "📥 createDownload: no existing record for track=\(trackRatingKey) source=\(sourceCompositeKey) — creating new pending download"
                    )
                    let download = CDDownload(context: context)
                    download.status = CDDownload.Status.pending.rawValue
                    download.progress = 0
                    download.startedAt = Date()
                    download.quality = Self.normalizedQuality(quality)
                    download.track = track

                    try context.save()

                    let downloadObjectID = download.objectID
                    context.reset()
                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        if let mainDownload = try? mainContext.existingObject(with: downloadObjectID) as? CDDownload {
                            continuation.resume(returning: mainDownload)
                        } else {
                            continuation.resume(throwing: DownloadError.trackNotFound)
                        }
                    }
                } catch {
                    context.rollback()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func batchCreateDownloads(
        references: [OfflineTrackReference],
        quality: String
    ) async throws -> Int {
        guard !references.isEmpty else { return 0 }

        return try await withCheckedThrowingContinuation { continuation in
            creationContext.perform {
                let context = self.creationContext
                do {
                    let normalizedQuality = Self.normalizedQuality(quality)

                    // 1. Pre-fetch all CDTrack records in one query
                    let ratingKeys = references.map(\.trackRatingKey)
                    let trackRequest = CDTrack.fetchRequest()
                    trackRequest.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
                    let tracks = try context.fetch(trackRequest)

                    // Build lookup: "sourceCompositeKey|ratingKey" → CDTrack
                    var trackLookup: [String: CDTrack] = [:]
                    trackLookup.reserveCapacity(tracks.count)
                    for track in tracks {
                        let key = "\(track.sourceCompositeKey ?? "")|\(track.ratingKey)"
                        trackLookup[key] = track
                    }

                    // 2. Pre-fetch all existing CDDownload records in one query
                    let downloadRequest = CDDownload.fetchRequest()
                    downloadRequest.predicate = NSPredicate(format: "track.ratingKey IN %@", ratingKeys)
                    let existingDownloads = try context.fetch(downloadRequest)

                    // Build lookup: "sourceCompositeKey|ratingKey" → CDDownload
                    var downloadLookup: [String: CDDownload] = [:]
                    downloadLookup.reserveCapacity(existingDownloads.count)
                    for download in existingDownloads {
                        guard let track = download.track else { continue }
                        let key = "\(track.sourceCompositeKey ?? "")|\(track.ratingKey)"
                        downloadLookup[key] = download
                    }

                    // 3. Loop through references, creating/updating records in memory
                    var newlyCreated = 0
                    let now = Date()
                    for ref in references {
                        let lookupKey = "\(ref.trackSourceCompositeKey)|\(ref.trackRatingKey)"

                        guard let track = trackLookup[lookupKey] else {
                            // Track not in CoreData — skip (don't fail the batch)
                            continue
                        }

                        if let existing = downloadLookup[lookupKey] {
                            // Existing download — only re-queue if quality upgrade needed
                            let existingQuality = existing.quality ?? "original"
                            if !Self.qualitySatisfies(existing: existingQuality, desired: normalizedQuality) {
                                existing.quality = normalizedQuality
                                existing.progress = 0
                                existing.error = nil
                                existing.completedAt = nil
                                existing.status = CDDownload.Status.pending.rawValue
                                existing.startedAt = now
                                newlyCreated += 1
                            }
                        } else {
                            // No existing download — create new pending record
                            let download = CDDownload(context: context)
                            download.status = CDDownload.Status.pending.rawValue
                            download.progress = 0
                            download.startedAt = now
                            download.quality = normalizedQuality
                            download.track = track
                            downloadLookup[lookupKey] = download
                            newlyCreated += 1
                        }
                    }

                    // 4. Single save for all changes
                    if context.hasChanges {
                        try context.save()
                    }

                    context.reset()
                    continuation.resume(returning: newlyCreated)
                } catch {
                    context.rollback()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {
        try await updateDownload(downloadId) { download in
            download.progress = progress
            download.status = CDDownload.Status.downloading.rawValue
        }
    }

    public func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String? = nil) async throws {
        try await updateDownload(downloadId) { download in
            download.status = status.rawValue
            // Update quality when provided (e.g., cancelled download re-queued
            // at new quality after a quality setting change)
            if let quality {
                download.quality = Self.normalizedQuality(quality)
            }
        }
    }

    public func requeueDownload(_ downloadId: NSManagedObjectID, quality: String) async throws {
        try await updateDownload(downloadId) { download in
            download.status = CDDownload.Status.pending.rawValue
            download.quality = Self.normalizedQuality(quality)
            download.progress = 0
            download.error = nil
            download.completedAt = nil
            download.startedAt = Date()
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
        try await updateDownload(downloadId) { download in
            // Normalize to filename-only for storage (sandbox-stable).
            let filename = Self.extractFilename(from: filePath)

            // If the previous download had a different file (e.g. quality re-queue),
            // clean up the old file now that the new one is ready.
            if let oldStored = download.filePath, !oldStored.isEmpty {
                let oldFilename = Self.extractFilename(from: oldStored)
                if oldFilename != filename {
                    Self.removeStoredDownloadFileAndSidecar(oldStored)
                }
            }

            download.status = CDDownload.Status.completed.rawValue
            download.progress = 1.0
            download.filePath = filename
            download.fileSize = fileSize
            download.completedAt = Date()
            if let quality, !quality.isEmpty {
                download.quality = Self.normalizedQuality(quality)
            }

            // Update track local path for offline playback routing (filename only).
            download.track?.localFilePath = filename
        }
    }

    public func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {
        try await updateDownload(downloadId) { download in
            download.status = CDDownload.Status.failed.rawValue
            download.error = error
        }
    }

    public func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDDownload.fetchRequest()
                request.predicate = Self.downloadPredicate(
                    trackRatingKey: trackRatingKey,
                    sourceCompositeKey: sourceCompositeKey
                )

                do {
                    if let download = try context.fetch(request).first {
                        Self.removeStoredDownloadFileAndSidecar(download.filePath)

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

    public func deleteDownloads(forReferences references: [OfflineTrackReference]) async throws {
        let uniqueReferences = Array(Set(references))
        guard !uniqueReferences.isEmpty else { return }

        try await coreDataStack.performBackgroundContext { context in
            let grouped = Dictionary(grouping: uniqueReferences, by: \.trackSourceCompositeKey)

            for (sourceKey, sourceReferences) in grouped {
                let ratingKeys = sourceReferences.map(\.trackRatingKey)
                for start in stride(from: 0, to: ratingKeys.count, by: 500) {
                    let batch = Array(ratingKeys[start..<min(start + 500, ratingKeys.count)])
                    let request = CDDownload.fetchRequest()
                    request.predicate = NSPredicate(
                        format: "track.sourceCompositeKey == %@ AND track.ratingKey IN %@",
                        sourceKey,
                        batch
                    )

                    for download in try context.fetch(request) {
                        Self.removeStoredDownloadFileAndSidecar(download.filePath)
                        download.track?.localFilePath = nil
                        context.delete(download)
                    }

                    if context.hasChanges {
                        try context.save()
                    }
                    context.reset()
                }
            }
        }
    }

    public func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> String? {
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
                    guard let track = try context.fetch(request).first,
                          let storedPath = track.localFilePath, !storedPath.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Migrate legacy absolute paths to filename-only.
                    let filename = Self.extractFilename(from: storedPath)
                    if filename != storedPath {
                        track.localFilePath = filename
                        try? context.save()
                    }

                    // Resolve filename to current absolute path.
                    let absolutePath = Self.absolutePath(forFilename: filename)
                    if FileManager.default.fileExists(atPath: absolutePath) {
                        continuation.resume(returning: absolutePath)
                    } else {
                        continuation.resume(returning: nil)
                    }
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

    public func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDDownload.fetchRequest()
                    request.predicate = NSPredicate(
                        format: "track.sourceCompositeKey == %@",
                        sourceCompositeKey
                    )
                    let downloads = try context.fetch(request)

                    for download in downloads {
                        Self.removeStoredDownloadFileAndSidecar(download.filePath)
                        download.track?.localFilePath = nil
                        context.delete(download)
                    }

                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllDownloads() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDDownload.fetchRequest()
                    let downloads = try context.fetch(request)

                    // Remove downloaded files and sidecars from disk
                    for download in downloads {
                        Self.removeStoredDownloadFileAndSidecar(download.filePath)
                        // Clear the track's local file path so it's no longer treated as offline
                        download.track?.localFilePath = nil
                        context.delete(download)
                    }

                    let trackRequest = CDTrack.fetchRequest()
                    trackRequest.predicate = NSPredicate(format: "localFilePath != nil AND localFilePath != ''")
                    for track in try context.fetch(trackRequest) {
                        track.localFilePath = nil
                    }

                    if context.hasChanges {
                        try context.save()
                    }

                    try Self.removeAllDownloadDirectoryFiles()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedDownloadFiles() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDDownload.fetchRequest()
                    let downloads = try context.fetch(request)
                    let referencedFilenames = Set(downloads.compactMap { download -> String? in
                        guard let filePath = download.filePath, !filePath.isEmpty else { return nil }
                        return Self.extractFilename(from: filePath)
                    })

                    let contents = (try? FileManager.default.contentsOfDirectory(
                        at: Self.downloadsDirectory,
                        includingPropertiesForKeys: nil,
                        options: []
                    )) ?? []

                    var removedCount = 0
                    for url in contents {
                        let filename = url.lastPathComponent
                        let ownerFilename = filename.hasSuffix(".freq")
                            ? String(filename.dropLast(".freq".count))
                            : filename
                        guard !referencedFilenames.contains(ownerFilename) else { continue }

                        try? FileManager.default.removeItem(at: url)
                        removedCount += 1
                    }

                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func removeAllDownloadDirectoryFiles() throws {
        guard FileManager.default.fileExists(atPath: downloadsDirectory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func updateDownload(
        _ downloadId: NSManagedObjectID,
        mutate: @escaping (CDDownload) throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }

                    try mutate(download)
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func removeStoredDownloadFileAndSidecar(_ storedPath: String?) {
        guard let storedPath, !storedPath.isEmpty else { return }

        let filename = extractFilename(from: storedPath)
        let absolutePath = absolutePath(forFilename: filename)
        try? FileManager.default.removeItem(atPath: absolutePath)
        try? FileManager.default.removeItem(atPath: absolutePath + ".freq")
    }

    private static func existingDownloadFilenames() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return Set(contents.map(\.lastPathComponent))
    }

    private static func isClearlyInvalidDownloadedPayload(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), !header.isEmpty else {
            return true
        }

        return EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(header)
    }

    private static func normalizedQuality(_ quality: String) -> String {
        switch quality {
        case "original", "high", "medium", "low":
            return quality
        default:
            return "original"
        }
    }

    /// Returns true when `existing` quality is equal to or higher than `desired`.
    /// Quality ranking: original > high > medium > low.
    /// Used to prevent re-downloading when a fallback stored original quality
    /// but the user's setting is medium/high — the file already exceeds the request.
    public static func qualitySatisfies(existing: String, desired: String) -> Bool {
        let ranking = ["low": 0, "medium": 1, "high": 2, "original": 3]
        let existingRank = ranking[existing] ?? 3
        let desiredRank = ranking[desired] ?? 3
        return existingRank >= desiredRank
    }

    /// Build the current absolute path for a download filename.
    /// Stored paths in CoreData should be filenames only (not absolute paths).
    /// This reconstructs the full path using the current sandbox's downloads directory.
    public static func absolutePath(forFilename filename: String) -> String {
        downloadsDirectory.appendingPathComponent(filename, isDirectory: false).path
    }

    /// Extract just the filename from a stored path, whether it's already a bare
    /// filename or a legacy absolute/file-URL path.
    public static func extractFilename(from storedPath: String) -> String {
        // Handle file:// URLs
        if storedPath.hasPrefix("file://"), let url = URL(string: storedPath), !url.path.isEmpty {
            return URL(fileURLWithPath: url.path).lastPathComponent
        }
        // Handle absolute paths — extract last component
        if storedPath.contains("/") {
            return URL(fileURLWithPath: storedPath).lastPathComponent
        }
        // Already a bare filename
        return storedPath
    }

    /// Resolve a stored path (filename or legacy absolute path) to a validated
    /// absolute path on disk, or nil if the file doesn't exist.
    public static func resolveExistingDownloadedFilePath(_ storedPath: String) -> String? {
        let filename = extractFilename(from: storedPath)
        guard !filename.isEmpty else { return nil }

        let absolutePath = self.absolutePath(forFilename: filename)
        if FileManager.default.fileExists(atPath: absolutePath) {
            return absolutePath
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
