import CoreData
import Foundation

public protocol PlaylistRepositoryProtocol: Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist]
    func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist]
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist?
    func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist?
    func searchPlaylists(query: String) async throws -> [CDPlaylist]
    func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist]
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
    func deletePlaylists(sourceCompositeKey: String) async throws
    func removeDuplicatePlaylists() async throws
    func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int
}

public final class PlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchPlaylists() async throws -> [CDPlaylist] {
        try await fetchPlaylists(sourceCompositeKey: nil)
    }

    public func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                }
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

    public func searchPlaylists(query: String) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
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

    public func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.predicate = Self.scopedTitleSearchPredicate(query: title, sourceCompositeKeys: sourceCompositeKeys)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "updatedAt", ascending: false)
                ]
                do {
                    let playlists = try context.fetch(request)
                    continuation.resume(returning: playlists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func scopedTitleSearchPredicate(query: String, sourceCompositeKeys: Set<String>?) -> NSPredicate {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let base: NSPredicate
        if trimmed.isEmpty {
            base = NSPredicate(value: false)
        } else {
            base = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "title ==[cd] %@", trimmed),
                NSPredicate(format: "title BEGINSWITH[cd] %@", trimmed),
                NSPredicate(format: "title CONTAINS[cd] %@", trimmed)
            ])
        }

        guard let sourceCompositeKeys, !sourceCompositeKeys.isEmpty else {
            return base
        }

        let scoped = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, scoped])
    }

    public func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? {
        try await fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    // Prefer the freshest copy if multiple servers share a rating key.
                    request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                }
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
            self.coreDataStack.performBackgroundTask { context in
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
            self.coreDataStack.performBackgroundTask { context in
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

                    // Update trackCount to match what was actually stored locally.
                    // The Plex API's leafCount (stored at upsert time) can be stale or mismatched
                    // for smart playlists, and we can only link tracks that exist in the local library.
                    playlist.trackCount = Int32(foundCount)

                    try context.save()
                    #if DEBUG
                    EnsembleLogger.debug("✅ Saved \(foundCount) tracks for playlist \(playlistRatingKey) (out of \(trackRatingKeys.count) requested)")
                    #endif
                    continuation.resume()
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("❌ Error saving playlist tracks: \(error)")
                    #endif
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deletePlaylist(ratingKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
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

    public func deletePlaylists(sourceCompositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)

                do {
                    let playlists = try context.fetch(request)
                    for playlist in playlists {
                        context.delete(playlist)
                    }
                    if !playlists.isEmpty {
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
            self.coreDataStack.performBackgroundTask { context in
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

    public func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDPlaylist> = CDPlaylist.fetchRequest()
                    request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                    let localPlaylists = try context.fetch(request)

                    var removedCount = 0
                    for playlist in localPlaylists {
                        if !validRatingKeys.contains(playlist.ratingKey) {
                            context.delete(playlist)
                            removedCount += 1
                        }
                    }

                    if removedCount > 0 {
                        try context.save()
                    }
                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
