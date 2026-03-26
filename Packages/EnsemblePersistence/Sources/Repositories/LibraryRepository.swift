import CoreData
import Foundation

// MARK: - Batch Upsert Input Types

/// Lightweight input for batch artist upsert (avoids per-item CoreData round-trips)
public struct ArtistUpsertInput: Sendable {
    public let ratingKey: String
    public let key: String
    public let name: String
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?

    public init(ratingKey: String, key: String, name: String, summary: String?, thumbPath: String?, artPath: String?, dateAdded: Date?, dateModified: Date?) {
        self.ratingKey = ratingKey
        self.key = key
        self.name = name
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
    }
}

/// Lightweight input for batch album upsert
public struct AlbumUpsertInput: Sendable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumArtist: String?
    public let artistRatingKey: String?
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let year: Int?
    public let trackCount: Int?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let rating: Int?
    public let genreNames: String?

    public init(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, genreNames: String? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumArtist = albumArtist
        self.artistRatingKey = artistRatingKey
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.year = year
        self.trackCount = trackCount
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.rating = rating
        self.genreNames = genreNames
    }
}

/// Lightweight input for batch track upsert
public struct TrackUpsertInput: Sendable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let albumRatingKey: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let duration: Int?
    public let thumbPath: String?
    public let streamKey: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let lastRatedAt: Date?
    public let rating: Int?
    public let playCount: Int?
    public let genreNames: String?

    public init(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date? = nil, rating: Int?, playCount: Int?, genreNames: String? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumRatingKey = albumRatingKey
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.thumbPath = thumbPath
        self.streamKey = streamKey
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.lastRatedAt = lastRatedAt
        self.rating = rating
        self.playCount = playCount
        self.genreNames = genreNames
    }
}

public protocol LibraryRepositoryProtocol: Sendable {
    /// Refresh the context to ensure fresh data from the store
    func refreshContext() async

    // Artists
    func fetchArtists() async throws -> [CDArtist]
    func fetchArtist(ratingKey: String) async throws -> CDArtist?
    func upsertArtist(
        ratingKey: String,
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        dateAdded: Date?,
        dateModified: Date?,
        sourceCompositeKey: String?
    ) async throws -> CDArtist

    // Albums
    func fetchAlbums() async throws -> [CDAlbum]
    func fetchAlbum(ratingKey: String) async throws -> CDAlbum?
    func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum]
    func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int?,
        genreNames: String?,
        sourceCompositeKey: String?
    ) async throws -> CDAlbum

    // Tracks
    func fetchTracks() async throws -> [CDTrack]
    func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchSiriEligibleTracks() async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack]
    func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchFavoriteTracks() async throws -> [CDTrack]
    func fetchTrack(ratingKey: String) async throws -> CDTrack?
    func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack?
    func upsertTrack(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Int?,
        thumbPath: String?,
        streamKey: String?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        lastRatedAt: Date?,
        rating: Int?,
        playCount: Int?,
        genreNames: String?,
        sourceCompositeKey: String?
    ) async throws -> CDTrack

    // Genres
    func fetchGenres() async throws -> [CDGenre]
    func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre

    // Search
    func searchTracks(query: String) async throws -> [CDTrack]
    func searchArtists(query: String) async throws -> [CDArtist]
    func searchAlbums(query: String) async throws -> [CDAlbum]
    func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack]
    func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist]
    func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum]

    // Source management
    func fetchMusicSources() async throws -> [CDMusicSource]

    func upsertMusicSource(
        compositeKey: String,
        type: String,
        accountId: String,
        serverId: String,
        libraryId: String,
        displayName: String?,
        accountName: String?
    ) async throws -> CDMusicSource

    func updateMusicSourceSyncTimestamp(compositeKey: String) async throws

    func deleteAllData(forSourceCompositeKey: String) async throws

    func deleteAllLibraryData() async throws

    // Orphan removal - delete items not in the provided set of valid ratingKeys
    func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int
    func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int
    func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int

    // Bulk timestamp lookups (for incremental sync change detection)
    func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date]
    func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date]
    func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date]
    func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16]
    func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int

    // Batch upserts (single context + single save for full sync performance)
    func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws
    func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws
    func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws
}

public final class LibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Context Refresh

    public func refreshContext() async {
        await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                // refreshAllObjects() iterates registeredObjects internally,
                // which can crash if a background deletion merged a nil entry.
                // reset() clears all registered objects without iterating them.
                // Callers re-fetch immediately after this call, so this is safe.
                context.stalenessInterval = 0
                context.reset()
                context.stalenessInterval = 5.0
                continuation.resume()
            }
        }
    }

    // MARK: - Artists

    public func fetchArtists() async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                request.relationshipKeyPathsForPrefetching = ["albums"]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: artists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchArtist(ratingKey: String) async throws -> CDArtist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let artist = try context.fetch(request).first
                    continuation.resume(returning: artist)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertArtist(
        ratingKey: String,
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        dateAdded: Date?,
        dateModified: Date?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDArtist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDArtist.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let artist = existing ?? CDArtist(context: context)

                    artist.ratingKey = ratingKey
                    artist.key = key
                    artist.name = name
                    artist.summary = summary
                    artist.thumbPath = thumbPath
                    artist.artPath = artPath
                    
                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        artist.dateAdded = added
                    }
                    
                    artist.dateModified = dateModified
                    artist.updatedAt = Date()
                    artist.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        artist.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
                        if let mainArtist = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainArtist)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch upserted artist"]))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Albums

    public func fetchAlbums() async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "year", ascending: false)
                ]
                request.relationshipKeyPathsForPrefetching = ["artist"]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbum(ratingKey: String) async throws -> CDAlbum? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let album = try context.fetch(request).first
                    continuation.resume(returning: album)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "artist.ratingKey == %@", artistRatingKey)
                request.sortDescriptors = [NSSortDescriptor(key: "year", ascending: false)]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int?,
        genreNames: String? = nil,
        sourceCompositeKey: String? = nil
    ) async throws -> CDAlbum {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDAlbum.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let album = existing ?? CDAlbum(context: context)

                    album.ratingKey = ratingKey
                    album.key = key
                    album.title = title
                    album.artistName = artistName
                    album.albumArtist = albumArtist
                    album.summary = summary
                    album.thumbPath = thumbPath
                    album.artPath = artPath
                    album.year = Int32(year ?? 0)
                    album.trackCount = Int32(trackCount ?? 0)
                    album.genreNames = genreNames

                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        album.dateAdded = added
                    }

                    album.dateModified = dateModified
                    album.rating = Int16(rating ?? 0)
                    album.updatedAt = Date()
                    album.sourceCompositeKey = sourceCompositeKey

                    if let artistKey = artistRatingKey {
                        let artistRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", artistKey, sourceKey)
                        } else {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@", artistKey)
                        }
                        album.artist = try context.fetch(artistRequest).first
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        album.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDAlbum.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
                        if let mainAlbum = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainAlbum)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Tracks

    public func fetchTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "albumName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchSiriEligibleTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                // Favorite tracks (rating >= 8) OR any tracks with play count/last played.
                request.predicate = NSPredicate(format: "rating >= 8 OR playCount > 0 OR lastPlayed != nil")
                request.sortDescriptors = [
                    NSSortDescriptor(key: "lastPlayed", ascending: false),
                    NSSortDescriptor(key: "playCount", ascending: false),
                    NSSortDescriptor(key: "rating", ascending: false)
                ]
                request.fetchLimit = 2000
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.ratingKey == %@", albumRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(
                    format: "album.ratingKey == %@ AND sourceCompositeKey == %@",
                    albumRatingKey,
                    sourceCompositeKey
                )
                request.sortDescriptors = [
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.artist.ratingKey == %@", artistRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "album.year", ascending: false),
                    NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(
                    format: "album.artist.ratingKey == %@ AND sourceCompositeKey == %@",
                    artistRatingKey,
                    sourceCompositeKey
                )
                request.sortDescriptors = [
                    NSSortDescriptor(key: "album.year", ascending: false),
                    NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchFavoriteTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                // Rating 8+ is 4+ stars
                request.predicate = NSPredicate(format: "rating >= 8")
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTrack(ratingKey: String) async throws -> CDTrack? {
        try await fetchTrack(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(
                        format: "ratingKey == %@ AND sourceCompositeKey == %@",
                        ratingKey,
                        sourceCompositeKey
                    )
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                }
                do {
                    let track = try context.fetch(request).first
                    continuation.resume(returning: track)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertTrack(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Int?,
        thumbPath: String?,
        streamKey: String?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        lastRatedAt: Date? = nil,
        rating: Int?,
        playCount: Int?,
        genreNames: String? = nil,
        sourceCompositeKey: String? = nil
    ) async throws -> CDTrack {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDTrack.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let track = existing ?? CDTrack(context: context)

                    track.ratingKey = ratingKey
                    track.key = key
                    track.title = Self.normalizedTrackTitle(title, streamKey: streamKey)
                    track.artistName = artistName
                    track.albumName = albumName
                    track.trackNumber = Int32(trackNumber ?? 0)
                    track.discNumber = Int32(discNumber ?? 1)
                    track.duration = Int64(duration ?? 0)
                    track.thumbPath = thumbPath
                    track.streamKey = streamKey
                    track.genreNames = genreNames

                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        track.dateAdded = added
                    }

                    track.dateModified = dateModified
                    track.lastPlayed = lastPlayed
                    track.lastRatedAt = lastRatedAt
                    track.rating = Int16(rating ?? 0)
                    track.playCount = Int32(playCount ?? 0)
                    track.updatedAt = Date()
                    track.sourceCompositeKey = sourceCompositeKey

                    if let albumKey = albumRatingKey {
                        let albumRequest = CDAlbum.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", albumKey, sourceKey)
                        } else {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@", albumKey)
                        }
                        track.album = try context.fetch(albumRequest).first

                        // If album metadata arrived without a usable title, backfill from track-level album name.
                        if
                            let album = track.album,
                            let resolvedAlbumName = albumName?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !resolvedAlbumName.isEmpty
                        {
                            let existingAlbumTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if existingAlbumTitle.isEmpty || existingAlbumTitle == "Unknown Album" {
                                album.title = resolvedAlbumName
                            }
                        }
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        track.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDTrack.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
                        if let mainTrack = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainTrack)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Genres

    public func fetchGenres() async throws -> [CDGenre] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDGenre.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let genres = try context.fetch(request)
                    continuation.resume(returning: genres)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String? = nil) async throws -> CDGenre {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDGenre.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "key == %@", key)
                }

                do {
                    let existing = try context.fetch(request).first
                    let genre = existing ?? CDGenre(context: context)

                    genre.ratingKey = ratingKey
                    genre.key = key
                    genre.title = title
                    genre.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        genre.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDGenre.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "key == %@", key)
                        }
                        if let mainGenre = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainGenre)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Search

    public func searchTracks(query: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                 request.predicate = Self.tokenizedSearchPredicate(
                    query: query,
                    fieldNames: ["title", "artistName", "albumName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "title",
                    query: title,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "title")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func searchArtists(query: String) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = Self.tokenizedSearchPredicate(
                    query: query,
                    fieldNames: ["name"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: artists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "name",
                    query: name,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "name")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func searchAlbums(query: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = Self.tokenizedSearchPredicate(
                    query: query,
                    fieldNames: ["title", "artistName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "title",
                    query: title,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "title")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Builds a search predicate that requires all whitespace-separated tokens
    /// to appear (in any order) across the given fields.
    private static func tokenizedSearchPredicate(
        query: String,
        fieldNames: [String]
    ) -> NSPredicate {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return NSPredicate(value: false)
        }

        // For each token, require it to appear in at least one searchable field
        let tokenPredicates = tokens.map { token in
            NSCompoundPredicate(orPredicateWithSubpredicates:
                fieldNames.map { field in
                    NSPredicate(format: "%K CONTAINS[cd] %@", field, token)
                }
            )
        }

        // All tokens must match
        return NSCompoundPredicate(andPredicateWithSubpredicates: tokenPredicates)
    }

    private static func scopedNameSearchPredicate(
        fieldName: String,
        query: String,
        sourceCompositeKeys: Set<String>?
    ) -> NSPredicate {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let base: NSPredicate
        if trimmed.isEmpty {
            base = NSPredicate(value: false)
        } else {
            base = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "%K ==[cd] %@", fieldName, trimmed),
                NSPredicate(format: "%K BEGINSWITH[cd] %@", fieldName, trimmed),
                NSPredicate(format: "%K CONTAINS[cd] %@", fieldName, trimmed)
            ])
        }

        guard let sourceCompositeKeys, !sourceCompositeKeys.isEmpty else {
            return base
        }

        let scoped = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, scoped])
    }

    private static func precisionSortDescriptors(primaryName: String) -> [NSSortDescriptor] {
        [
            NSSortDescriptor(
                key: primaryName,
                ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            ),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
    }

    // MARK: - Music Source

    public func fetchMusicSources() async throws -> [CDMusicSource] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDMusicSource.fetchRequest()
                do {
                    let sources = try context.fetch(request)
                    continuation.resume(returning: sources)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertMusicSource(
        compositeKey: String,
        type: String,
        accountId: String,
        serverId: String,
        libraryId: String,
        displayName: String?,
        accountName: String?
    ) async throws -> CDMusicSource {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
                    let existing = try context.fetch(request).first
                    let source = existing ?? CDMusicSource(context: context)

                    source.compositeKey = compositeKey
                    source.type = type
                    source.accountId = accountId
                    source.serverId = serverId
                    source.libraryId = libraryId
                    source.displayName = displayName
                    source.accountName = accountName

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDMusicSource.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)
                        if let mainSource = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainSource)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
                    if let source = try context.fetch(request).first {
                        source.lastSyncedAt = Date()
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllData(forSourceCompositeKey sourceKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDPlaylist"] {
                        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                        request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                        let objects = try context.fetch(request)
                        for object in objects {
                            context.delete(object)
                        }
                    }

                    let sourceRequest = CDMusicSource.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                    if let source = try context.fetch(sourceRequest).first {
                        context.delete(source)
                    }

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func deleteAllLibraryData() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Delete all library entities regardless of source
                    for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDPlaylist", "CDMusicSource", "CDServer"] {
                        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                        let objects = try context.fetch(request)
                        for object in objects {
                            context.delete(object)
                        }
                        #if DEBUG
                        EnsembleLogger.debug("🗑️ Deleted \(objects.count) \(entityName) objects")
                        #endif
                    }
                    
                    try context.save()
                    #if DEBUG
                    EnsembleLogger.debug("✅ All library data deleted successfully")
                    #endif
                    continuation.resume()
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("❌ Failed to delete library data: \(error)")
                    #endif
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Orphan Removal

    public func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localArtists = try context.fetch(request)

                    var removedCount = 0
                    for artist in localArtists {
                        if !validRatingKeys.contains(artist.ratingKey) {
                            context.delete(artist)
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

    public func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localAlbums = try context.fetch(request)

                    var removedCount = 0
                    for album in localAlbums {
                        if !validRatingKeys.contains(album.ratingKey) {
                            context.delete(album)
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

    public func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localTracks = try context.fetch(request)

                    var removedCount = 0
                    for track in localTracks {
                        if !validRatingKeys.contains(track.ratingKey) {
                            context.delete(track)
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

    // MARK: - Bulk Timestamp Lookups

    /// Fetch all artist ratingKey → dateModified pairs for a source (single query for change detection)
    public func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let artists = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(artists.count)
                    for artist in artists {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[artist.ratingKey] = artist.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all album ratingKey → dateModified pairs for a source (single query for change detection)
    public func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let albums = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(albums.count)
                    for album in albums {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[album.ratingKey] = album.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all track ratingKey → dateModified pairs for a source (single query for change detection)
    public func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let tracks = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(tracks.count)
                    for track in tracks {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[track.ratingKey] = track.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all track ratingKey → rating pairs for a source (for detecting rating changes)
    public func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "rating"]
                    let tracks = try context.fetch(request)
                    var result: [String: Int16] = [:]
                    result.reserveCapacity(tracks.count)
                    for track in tracks {
                        result[track.ratingKey] = track.rating
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localGenres = try context.fetch(request)

                    var removedCount = 0
                    for genre in localGenres {
                        if let ratingKey = genre.ratingKey, !validRatingKeys.contains(ratingKey) {
                            context.delete(genre)
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
    // MARK: - Batch Upserts

    /// Upsert all artists in a single background context with one save.
    /// Much faster than per-item upserts for full sync (eliminates N individual fetches + saves).
    public func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing artists for this source into a lookup dictionary
                    let existingRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingArtists = try context.fetch(existingRequest)
                    var artistsByKey: [String: CDArtist] = [:]
                    artistsByKey.reserveCapacity(existingArtists.count)
                    for artist in existingArtists {
                        artistsByKey[artist.ratingKey] = artist
                    }

                    // Pre-fetch the CDMusicSource once
                    let sourceRequest = CDMusicSource.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
                    let source = try context.fetch(sourceRequest).first

                    let now = Date()
                    for input in inputs {
                        let existing = artistsByKey[input.ratingKey]
                        let artist = existing ?? CDArtist(context: context)

                        artist.ratingKey = input.ratingKey
                        artist.key = input.key
                        artist.name = input.name
                        artist.summary = input.summary
                        artist.thumbPath = input.thumbPath
                        artist.artPath = input.artPath
                        if existing == nil, let added = input.dateAdded {
                            artist.dateAdded = added
                        }
                        artist.dateModified = input.dateModified
                        artist.updatedAt = now
                        artist.sourceCompositeKey = sourceCompositeKey
                        artist.source = source
                    }

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upsert all albums in a single background context with one save.
    public func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing albums for this source
                    let existingRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingAlbums = try context.fetch(existingRequest)
                    var albumsByKey: [String: CDAlbum] = [:]
                    albumsByKey.reserveCapacity(existingAlbums.count)
                    for album in existingAlbums {
                        albumsByKey[album.ratingKey] = album
                    }

                    // Pre-fetch all artists for this source (for relationship linking)
                    let artistRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    artistRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingArtists = try context.fetch(artistRequest)
                    var artistsByKey: [String: CDArtist] = [:]
                    artistsByKey.reserveCapacity(existingArtists.count)
                    for artist in existingArtists {
                        artistsByKey[artist.ratingKey] = artist
                    }

                    // Pre-fetch the CDMusicSource once
                    let sourceRequest = CDMusicSource.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
                    let source = try context.fetch(sourceRequest).first

                    let now = Date()
                    for input in inputs {
                        let existing = albumsByKey[input.ratingKey]
                        let album = existing ?? CDAlbum(context: context)

                        album.ratingKey = input.ratingKey
                        album.key = input.key
                        album.title = input.title
                        album.artistName = input.artistName
                        album.albumArtist = input.albumArtist
                        album.summary = input.summary
                        album.thumbPath = input.thumbPath
                        album.artPath = input.artPath
                        album.year = Int32(input.year ?? 0)
                        album.trackCount = Int32(input.trackCount ?? 0)
                        album.genreNames = input.genreNames
                        if existing == nil, let added = input.dateAdded {
                            album.dateAdded = added
                        }
                        album.dateModified = input.dateModified
                        album.rating = Int16(input.rating ?? 0)
                        album.updatedAt = now
                        album.sourceCompositeKey = sourceCompositeKey
                        album.source = source

                        if let artistKey = input.artistRatingKey {
                            album.artist = artistsByKey[artistKey]
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

    /// Upsert all tracks in a single background context with one save.
    /// This is the biggest performance win — tracks go from ~24s to ~2-3s for 1400+ items.
    public func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing tracks for this source
                    let existingRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingTracks = try context.fetch(existingRequest)
                    var tracksByKey: [String: CDTrack] = [:]
                    tracksByKey.reserveCapacity(existingTracks.count)
                    for track in existingTracks {
                        tracksByKey[track.ratingKey] = track
                    }

                    // Pre-fetch all albums for this source (for relationship linking)
                    let albumRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    albumRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingAlbums = try context.fetch(albumRequest)
                    var albumsByKey: [String: CDAlbum] = [:]
                    albumsByKey.reserveCapacity(existingAlbums.count)
                    for album in existingAlbums {
                        albumsByKey[album.ratingKey] = album
                    }

                    // Pre-fetch the CDMusicSource once
                    let sourceRequest = CDMusicSource.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
                    let source = try context.fetch(sourceRequest).first

                    let now = Date()
                    for input in inputs {
                        let existing = tracksByKey[input.ratingKey]
                        let track = existing ?? CDTrack(context: context)

                        track.ratingKey = input.ratingKey
                        track.key = input.key
                        track.title = Self.normalizedTrackTitle(input.title, streamKey: input.streamKey)
                        track.artistName = input.artistName
                        track.albumName = input.albumName
                        track.trackNumber = Int32(input.trackNumber ?? 0)
                        track.discNumber = Int32(input.discNumber ?? 1)
                        track.duration = Int64(input.duration ?? 0)
                        track.thumbPath = input.thumbPath
                        track.streamKey = input.streamKey
                        track.genreNames = input.genreNames
                        if existing == nil, let added = input.dateAdded {
                            track.dateAdded = added
                        }
                        track.dateModified = input.dateModified
                        track.lastPlayed = input.lastPlayed
                        track.lastRatedAt = input.lastRatedAt
                        track.rating = Int16(input.rating ?? 0)
                        track.playCount = Int32(input.playCount ?? 0)
                        track.updatedAt = now
                        track.sourceCompositeKey = sourceCompositeKey
                        track.source = source

                        if let albumKey = input.albumRatingKey {
                            let album = albumsByKey[albumKey]
                            track.album = album

                            // Backfill empty album titles from track-level album name
                            if let album = album,
                               let resolvedAlbumName = input.albumName?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !resolvedAlbumName.isEmpty {
                                let existingTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                if existingTitle.isEmpty || existingTitle == "Unknown Album" {
                                    album.title = resolvedAlbumName
                                }
                            }
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
}

private extension LibraryRepository {
    static func normalizedTrackTitle(_ title: String, streamKey: String?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if let streamKey = streamKey?.trimmingCharacters(in: .whitespacesAndNewlines), !streamKey.isEmpty {
            if
                let components = URLComponents(string: streamKey),
                let path = components.percentEncodedPath.removingPercentEncoding,
                !path.isEmpty
            {
                let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if !filename.isEmpty {
                    return filename
                }
            }

            let filename = URL(fileURLWithPath: streamKey).deletingPathExtension().lastPathComponent
            if !filename.isEmpty {
                return filename
            }
        }

        return "Unknown Track"
    }
}
