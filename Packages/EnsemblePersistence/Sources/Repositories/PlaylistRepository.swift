import CoreData
import Foundation

public protocol PlaylistRepositoryProtocol: Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist]
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist?
        func searchPlaylists(query: String) async throws -> [CDPlaylist]
    func upsertPlaylist(
        ratingKey: String,
        key: String,
        title: String,
        summary: String?,
        compositePath: String?,
        isSmart: Bool,
        duration: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        sourceCompositeKey: String?
    ) async throws -> CDPlaylist
    func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws
    func deletePlaylist(ratingKey: String) async throws
    func removeDuplicatePlaylists() async throws
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

                    public func searchPlaylists(query: String) async throws -> [CDPlaylist] {
                        try await withCheckedThrowingContinuation { continuation in
                            let context = coreDataStack.viewContext
                            context.perform {
                                let request = CDPlaylist.fetchRequest()
                                request.predicate = NSPredicate(format: "title CONTAINS[cd] %@", query)
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
                request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track"]
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
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDPlaylist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

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
                    playlist.dateAdded = dateAdded
                    playlist.dateModified = dateModified
                    playlist.lastPlayed = lastPlayed
                    playlist.updatedAt = Date()
                    playlist.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        playlist.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDPlaylist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
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

    public func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let playlistRequest = CDPlaylist.fetchRequest()
                    if let sourceKey = sourceCompositeKey {
                        playlistRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", playlistRatingKey, sourceKey)
                    } else {
                        playlistRequest.predicate = NSPredicate(format: "ratingKey == %@", playlistRatingKey)
                    }
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
                    var foundCount = 0
                    for (index, trackKey) in trackRatingKeys.enumerated() {
                        let trackRequest = CDTrack.fetchRequest()
                        // Don't filter by sourceCompositeKey since playlists use server-level keys
                        // but tracks use library-level keys. Track ratingKeys are unique anyway.
                        trackRequest.predicate = NSPredicate(format: "ratingKey == %@", trackKey)
                        if let track = try context.fetch(trackRequest).first {
                            foundCount += 1
                            let playlistTrack = CDPlaylistTrack(context: context)
                            playlistTrack.order = Int32(index)
                            playlistTrack.playlist = playlist
                            playlistTrack.track = track
                        }
                    }

                    try context.save()
                    print("✅ Saved \(foundCount) tracks for playlist \(playlistRatingKey) (out of \(trackRatingKeys.count) requested)")
                    continuation.resume()
                } catch {
                    print("❌ Error saving playlist tracks: \(error)")
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
    
    public func removeDuplicatePlaylists() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDPlaylist.fetchRequest()
                    request.sortDescriptors = [
                        NSSortDescriptor(key: "ratingKey", ascending: true),
                        NSSortDescriptor(key: "updatedAt", ascending: false)
                    ]
                    
                    let allPlaylists = try context.fetch(request)
                    var seenRatingKeys = Set<String>()
                    var playlistsToDelete: [CDPlaylist] = []
                    
                    // Keep the first (most recently updated) playlist for each ratingKey
                    for playlist in allPlaylists {
                        if seenRatingKeys.contains(playlist.ratingKey) {
                            playlistsToDelete.append(playlist)
                        } else {
                            seenRatingKeys.insert(playlist.ratingKey)
                        }
                    }
                    
                    // Delete duplicates
                    for playlist in playlistsToDelete {
                        context.delete(playlist)
                    }
                    
                    if !playlistsToDelete.isEmpty {
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
