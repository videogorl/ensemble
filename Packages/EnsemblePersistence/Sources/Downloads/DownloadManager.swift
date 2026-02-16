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
    func fetchCompletedDownloads() async throws -> [CDDownload]
    func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload
    func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws
    func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64) async throws
    func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws
    func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws
    func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String?
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
                request.predicate = NSPredicate(format: "status == %@ OR status == %@",
                                                CDDownload.Status.pending.rawValue,
                                                CDDownload.Status.downloading.rawValue)
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

    public func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                // Find the track
                let trackRequest = CDTrack.fetchRequest()
                trackRequest.predicate = NSPredicate(format: "ratingKey == %@", trackRatingKey)

                do {
                    guard let track = try context.fetch(trackRequest).first else {
                        continuation.resume(throwing: DownloadError.trackNotFound)
                        return
                    }

                    // Check if download already exists
                    let downloadRequest = CDDownload.fetchRequest()
                    downloadRequest.predicate = NSPredicate(format: "track.ratingKey == %@", trackRatingKey)
                    if let existing = try context.fetch(downloadRequest).first {
                        // Return existing download on main context
                        let mainContext = self.coreDataStack.viewContext
                        mainContext.perform {
                            if let mainDownload = try? mainContext.existingObject(with: existing.objectID) as? CDDownload {
                                continuation.resume(returning: mainDownload)
                            } else {
                                continuation.resume(throwing: DownloadError.trackNotFound)
                            }
                        }
                        return
                    }

                    // Create new download
                    let download = CDDownload(context: context)
                    download.status = CDDownload.Status.pending.rawValue
                    download.progress = 0
                    download.startedAt = Date()
                    download.track = track

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        if let mainDownload = try? mainContext.existingObject(with: download.objectID) as? CDDownload {
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

    public func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    guard let download = try context.existingObject(with: downloadId) as? CDDownload else {
                        continuation.resume()
                        return
                    }
                    download.status = CDDownload.Status.completed.rawValue
                    download.progress = 1.0
                    download.filePath = filePath
                    download.fileSize = fileSize
                    download.completedAt = Date()

                    // Update track's local file path
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDDownload.fetchRequest()
                request.predicate = NSPredicate(format: "track.ratingKey == %@", trackRatingKey)

                do {
                    if let download = try context.fetch(request).first {
                        // Delete the file if it exists
                        if let filePath = download.filePath {
                            try? FileManager.default.removeItem(atPath: filePath)
                        }

                        // Clear track's local file path
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
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", trackRatingKey)

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
}
