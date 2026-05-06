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

/// Describes a track whose album association changed during a sync upsert.
/// Used to trigger downstream artwork cache invalidation.
public struct TrackReparentInfo: Sendable {
    public let trackRatingKey: String
    public let oldAlbumRatingKey: String
    public let newAlbumRatingKey: String?

    public init(trackRatingKey: String, oldAlbumRatingKey: String, newAlbumRatingKey: String?) {
        self.trackRatingKey = trackRatingKey
        self.oldAlbumRatingKey = oldAlbumRatingKey
        self.newAlbumRatingKey = newAlbumRatingKey
    }
}

/// Summarizes how much persisted album/track genre metadata exists for a source.
/// Used to detect restored stores that have the genre catalog but not the per-item genre fields.
public struct GenreCoverageStats: Sendable, Equatable {
    public let albumCount: Int
    public let albumsWithGenreNames: Int
    public let trackCount: Int
    public let tracksWithGenreNames: Int
    public let genreCatalogCount: Int

    public init(
        albumCount: Int,
        albumsWithGenreNames: Int,
        trackCount: Int,
        tracksWithGenreNames: Int,
        genreCatalogCount: Int
    ) {
        self.albumCount = albumCount
        self.albumsWithGenreNames = albumsWithGenreNames
        self.trackCount = trackCount
        self.tracksWithGenreNames = tracksWithGenreNames
        self.genreCatalogCount = genreCatalogCount
    }
}

public protocol LibraryRepositoryProtocol: Sendable {
    /// Refresh the context to ensure fresh data from the store
    func refreshContext() async

    // Artists
    func fetchArtists() async throws -> [CDArtist]
    func fetchArtist(ratingKey: String) async throws -> CDArtist?
    func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist?
    func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws
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
    func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum?
    func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws
    func deleteAlbum(ratingKey: String, sourceCompositeKey: String?) async throws
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
    func updateTrackTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws
    func deleteTrack(ratingKey: String, sourceCompositeKey: String?) async throws
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
    func fetchGenreCoverageStats(forSource sourceKey: String) async throws -> GenreCoverageStats?
    func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int

    // Batch upserts (single context + single save for full sync performance)
    func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws
    func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws
    func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws

    /// Returns and clears any track reparent events accumulated during upsert operations.
    /// Called after sync to trigger artwork invalidation for tracks whose album changed.
    func drainTrackReparentInfo() -> [TrackReparentInfo]
}

public extension LibraryRepositoryProtocol {
    func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist? {
        try await fetchArtist(ratingKey: ratingKey)
    }

    func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum? {
        try await fetchAlbum(ratingKey: ratingKey)
    }
}

public extension LibraryRepositoryProtocol {
    func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws {}
    func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {}
    func deleteAlbum(ratingKey: String, sourceCompositeKey: String?) async throws {}
    func updateTrackTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {}
    func deleteTrack(ratingKey: String, sourceCompositeKey: String?) async throws {}
    func fetchGenreCoverageStats(forSource sourceKey: String) async throws -> GenreCoverageStats? { nil }
}

public final class LibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
    let coreDataStack: CoreDataStack

    // Accumulator for tracks whose album changed during upsert.
    // Protected by reparentLock; drained by SyncCoordinator after sync.
    private var pendingReparentInfo: [TrackReparentInfo] = []
    private let reparentLock = NSLock()

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func drainTrackReparentInfo() -> [TrackReparentInfo] {
        reparentLock.lock()
        defer { reparentLock.unlock() }
        let info = pendingReparentInfo
        pendingReparentInfo = []
        return info
    }

    func recordReparent(_ info: TrackReparentInfo) {
        reparentLock.lock()
        defer { reparentLock.unlock() }
        pendingReparentInfo.append(info)
    }

    // MARK: - Context Refresh

    public func refreshContext() async {
        await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                context.stalenessInterval = 0
                context.refreshAllObjects()
                context.stalenessInterval = 5.0
                continuation.resume()
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

}

extension LibraryRepository {
    func deleteTrackManagedObject(_ track: CDTrack, in context: NSManagedObjectContext) {
        if let playlistTracks = track.playlistTracks as? Set<CDPlaylistTrack> {
            for playlistTrack in playlistTracks {
                context.delete(playlistTrack)
            }
        }

        if let memberships = track.offlineMemberships as? Set<CDOfflineDownloadMembership> {
            for membership in memberships {
                context.delete(membership)
            }
        }

        if let download = track.download {
            context.delete(download)
        }

        context.delete(track)
    }

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
