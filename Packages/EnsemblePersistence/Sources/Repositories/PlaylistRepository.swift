import CoreData
import Foundation

public protocol PlaylistRepositoryProtocol: Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist]
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist?
    func upsertPlaylist(
        ratingKey: String,
        key: String,
        title: String,
        summary: String?,
        compositePath: String?,
        isSmart: Bool,
        duration: Int?,
        trackCount: Int?
    ) async throws -> CDPlaylist
    func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String) async throws
    func deletePlaylist(ratingKey: String) async throws
}

public final class PlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchPlaylists() async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                do {
                    let playlists = try context.fetch(request)
                    continuation.resume(returning: playlists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let playlist = try context.fetch(request).first
                    continuation.resume(returning: playlist)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertPlaylist(
        ratingKey: String,
        key: String,
        title: String,
        summary: String?,
        compositePath: String?,
        isSmart: Bool,
        duration: Int?,
        trackCount: Int?
    ) async throws -> CDPlaylist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    let existing = try context.fetch(request).first
                    let playlist = existing ?? CDPlaylist(context: context)

                    playlist.ratingKey = ratingKey
                    playlist.key = key
                    playlist.title = title
                    playlist.summary = summary
                    playlist.compositePath = compositePath
                    playlist.isSmart = isSmart
                    playlist.duration = Int64(duration ?? 0)
                    playlist.trackCount = Int32(trackCount ?? 0)
                    playlist.updatedAt = Date()

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDPlaylist.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        if let mainPlaylist = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainPlaylist)
                        } else {
                            continuation.resume(throwing: NSError(domain: "PlaylistRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Find playlist
                    let playlistRequest = CDPlaylist.fetchRequest()
                    playlistRequest.predicate = NSPredicate(format: "ratingKey == %@", playlistRatingKey)
                    guard let playlist = try context.fetch(playlistRequest).first else {
                        continuation.resume(throwing: NSError(domain: "PlaylistRepository", code: 2, userInfo: [NSLocalizedDescriptionKey: "Playlist not found"]))
                        return
                    }

                    // Remove existing playlist tracks
                    if let existingTracks = playlist.playlistTracks as? Set<CDPlaylistTrack> {
                        for pt in existingTracks {
                            context.delete(pt)
                        }
                    }

                    // Add new playlist tracks
                    for (index, trackKey) in trackRatingKeys.enumerated() {
                        let trackRequest = CDTrack.fetchRequest()
                        trackRequest.predicate = NSPredicate(format: "ratingKey == %@", trackKey)
                        if let track = try context.fetch(trackRequest).first {
                            let playlistTrack = CDPlaylistTrack(context: context)
                            playlistTrack.order = Int32(index)
                            playlistTrack.playlist = playlist
                            playlistTrack.track = track
                        }
                    }

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deletePlaylist(ratingKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    if let playlist = try context.fetch(request).first {
                        context.delete(playlist)
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
