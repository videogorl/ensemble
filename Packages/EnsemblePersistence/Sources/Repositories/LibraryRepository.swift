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
    public let updatesDateAdded: Bool
    /// Opaque provider capability payload. `nil` preserves persisted overrides;
    /// an encoded empty capability set clears them.
    public let actionCapabilitiesData: Data?

    public init(ratingKey: String, key: String, name: String, summary: String?, thumbPath: String?, artPath: String?, dateAdded: Date?, dateModified: Date?, updatesDateAdded: Bool = false, actionCapabilitiesData: Data? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.name = name
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.updatesDateAdded = updatesDateAdded
        self.actionCapabilitiesData = actionCapabilitiesData
    }
}

/// Artist fields Plex can change without advancing the item's `updatedAt` timestamp.
public struct ArtistSyncMetadata: Sendable, Equatable {
    public let key: String
    public let name: String
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let actionCapabilitiesData: Data?

    public init(
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        dateAdded: Date? = nil,
        dateModified: Date?,
        actionCapabilitiesData: Data? = nil
    ) {
        self.key = key
        self.name = name
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.actionCapabilitiesData = actionCapabilitiesData
    }

    public init(_ input: ArtistUpsertInput) {
        self.init(
            key: input.key,
            name: input.name,
            summary: input.summary,
            thumbPath: input.thumbPath,
            artPath: input.artPath,
            dateAdded: input.dateAdded,
            dateModified: input.dateModified,
            actionCapabilitiesData: input.actionCapabilitiesData
        )
    }

    /// Compares an input using the repository's merge semantics.
    public func matches(_ input: ArtistUpsertInput) -> Bool {
        key == input.key &&
            name == input.name &&
            summary == input.summary &&
            thumbPath == input.thumbPath &&
            artPath == input.artPath &&
            (input.updatesDateAdded
                ? dateAdded == input.dateAdded
                : !(dateAdded == nil && input.dateAdded != nil)) &&
            dateModified == input.dateModified &&
            (input.actionCapabilitiesData == nil || actionCapabilitiesData == input.actionCapabilitiesData)
    }
}

/// Source-scoped album fields used to skip unchanged persistence work.
public struct AlbumSyncMetadata: Sendable, Equatable {
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumArtist: String?
    public let artistRatingKey: String?
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let year: Int?
    public let trackCount: Int
    public let dateAdded: Date?
    public let dateModified: Date?
    public let rating: Int
    public let genreNames: String?
    public let releaseFormat: String?
    public let actionCapabilitiesData: Data?

    public init(
        key: String,
        title: String,
        artistName: String?,
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int,
        genreNames: String?,
        releaseFormat: String?,
        actionCapabilitiesData: Data? = nil
    ) {
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
        self.releaseFormat = releaseFormat
        self.actionCapabilitiesData = actionCapabilitiesData
    }

    public init(_ input: AlbumUpsertInput) {
        self.init(
            key: input.key,
            title: input.title,
            artistName: input.artistName,
            albumArtist: input.albumArtist,
            artistRatingKey: input.artistRatingKey,
            summary: input.summary,
            thumbPath: input.thumbPath,
            artPath: input.artPath,
            year: input.year,
            trackCount: input.trackCount ?? 0,
            dateAdded: input.dateAdded,
            dateModified: input.dateModified,
            rating: input.rating ?? 0,
            genreNames: input.genreNames,
            releaseFormat: input.updatesReleaseFormat ? input.releaseFormat : nil,
            actionCapabilitiesData: input.actionCapabilitiesData
        )
    }

    /// Compares an input using the repository's merge semantics.
    public func matches(_ input: AlbumUpsertInput) -> Bool {
        key == input.key &&
            title == input.title &&
            artistName == input.artistName &&
            albumArtist == input.albumArtist &&
            artistRatingKey == input.artistRatingKey &&
            summary == input.summary &&
            thumbPath == input.thumbPath &&
            artPath == input.artPath &&
            year == input.year &&
            (input.trackCount == nil || trackCount == input.trackCount) &&
            (input.updatesDateAdded
                ? dateAdded == input.dateAdded
                : !(dateAdded == nil && input.dateAdded != nil)) &&
            dateModified == input.dateModified &&
            rating == (input.rating ?? 0) &&
            genreNames == input.genreNames &&
            (!input.updatesReleaseFormat || releaseFormat == input.releaseFormat) &&
            (input.actionCapabilitiesData == nil || actionCapabilitiesData == input.actionCapabilitiesData)
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
    public let releaseFormat: String?
    public let updatesReleaseFormat: Bool
    public let updatesDateAdded: Bool
    /// Opaque provider capability payload. `nil` preserves persisted overrides;
    /// an encoded empty capability set clears them.
    public let actionCapabilitiesData: Data?

    public init(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, genreNames: String? = nil, releaseFormat: String? = nil, updatesReleaseFormat: Bool = false, updatesDateAdded: Bool = false, actionCapabilitiesData: Data? = nil) {
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
        self.releaseFormat = releaseFormat
        self.updatesReleaseFormat = updatesReleaseFormat
        self.updatesDateAdded = updatesDateAdded
        self.actionCapabilitiesData = actionCapabilitiesData
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
    public let streamId: Int?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let lastRatedAt: Date?
    public let rating: Int?
    public let isFavorite: Bool?
    public let playCount: Int?
    public let genreNames: String?
    public let updatesDateAdded: Bool
    /// Opaque provider capability payload. `nil` preserves persisted overrides;
    /// an encoded empty capability set clears them.
    public let actionCapabilitiesData: Data?

    public init(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, streamId: Int? = nil, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date? = nil, rating: Int?, isFavorite: Bool? = nil, playCount: Int?, genreNames: String? = nil, updatesDateAdded: Bool = false, actionCapabilitiesData: Data? = nil) {
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
        self.streamId = streamId
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.lastRatedAt = lastRatedAt
        self.rating = rating
        self.isFavorite = isFavorite
        self.playCount = playCount
        self.genreNames = genreNames
        self.updatesDateAdded = updatesDateAdded
        self.actionCapabilitiesData = actionCapabilitiesData
    }
}

/// Source-scoped track fields used to skip unchanged persistence work.
public struct TrackSyncMetadata: Sendable, Equatable {
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let albumRatingKey: String?
    public let trackNumber: Int
    public let discNumber: Int
    public let duration: Int
    public let thumbPath: String?
    public let streamKey: String?
    public let streamId: Int?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let lastRatedAt: Date?
    public let rating: Int
    public let isFavorite: Bool?
    public let playCount: Int
    public let genreNames: String?
    public let actionCapabilitiesData: Data?

    public init(
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int,
        discNumber: Int,
        duration: Int,
        thumbPath: String?,
        streamKey: String?,
        streamId: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        lastRatedAt: Date?,
        rating: Int,
        isFavorite: Bool?,
        playCount: Int,
        genreNames: String?,
        actionCapabilitiesData: Data? = nil
    ) {
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
        self.streamId = streamId
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.lastRatedAt = lastRatedAt
        self.rating = rating
        self.isFavorite = isFavorite
        self.playCount = playCount
        self.genreNames = genreNames
        self.actionCapabilitiesData = actionCapabilitiesData
    }

    public init(_ input: TrackUpsertInput) {
        self.init(
            key: input.key,
            title: input.title,
            artistName: input.artistName,
            albumName: input.albumName,
            albumRatingKey: input.albumRatingKey,
            trackNumber: input.trackNumber ?? 0,
            discNumber: input.discNumber ?? 1,
            duration: input.duration ?? 0,
            thumbPath: input.thumbPath,
            streamKey: input.streamKey,
            streamId: input.streamId.flatMap { $0 > 0 ? $0 : nil },
            dateAdded: input.dateAdded,
            dateModified: input.dateModified,
            lastPlayed: input.lastPlayed,
            lastRatedAt: input.lastRatedAt,
            rating: input.rating ?? 0,
            isFavorite: input.isFavorite,
            playCount: input.playCount ?? 0,
            genreNames: input.genreNames,
            actionCapabilitiesData: input.actionCapabilitiesData
        )
    }

    /// Compares an input using the repository's merge semantics.
    public func matches(_ input: TrackUpsertInput) -> Bool {
        key == input.key &&
            title == input.title &&
            artistName == input.artistName &&
            albumName == input.albumName &&
            albumRatingKey == input.albumRatingKey &&
            trackNumber == (input.trackNumber ?? 0) &&
            discNumber == (input.discNumber ?? 1) &&
            duration == (input.duration ?? 0) &&
            thumbPath == input.thumbPath &&
            streamKey == input.streamKey &&
            streamId == input.streamId.flatMap { $0 > 0 ? $0 : nil } &&
            (input.updatesDateAdded
                ? dateAdded == input.dateAdded
                : !(dateAdded == nil && input.dateAdded != nil)) &&
            dateModified == input.dateModified &&
            lastPlayed == input.lastPlayed &&
            lastRatedAt == input.lastRatedAt &&
            rating == (input.rating ?? 0) &&
            (input.isFavorite == nil || isFavorite == input.isFavorite) &&
            playCount == (input.playCount ?? 0) &&
            genreNames == input.genreNames &&
            (input.actionCapabilitiesData == nil || actionCapabilitiesData == input.actionCapabilitiesData)
    }
}

/// Lightweight genre input for one-context batch persistence.
public struct GenreUpsertInput: Sendable, Equatable {
    public let ratingKey: String?
    public let key: String
    public let title: String

    public init(ratingKey: String?, key: String, title: String) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
    }
}

/// Source-scoped media identity used for batched lightweight metadata lookups.
public struct SourceScopedArtworkReference: Sendable, Hashable {
    public let ratingKey: String
    public let sourceCompositeKey: String

    public init(ratingKey: String, sourceCompositeKey: String) {
        self.ratingKey = ratingKey
        self.sourceCompositeKey = sourceCompositeKey
    }

    public var lookupKey: String {
        "\(sourceCompositeKey)|\(ratingKey)"
    }
}

/// Describes a track whose album association changed during a sync upsert.
/// Used to trigger downstream artwork cache invalidation.
public struct TrackReparentInfo: Sendable {
    public let trackRatingKey: String
    public let oldAlbumRatingKey: String
    public let newAlbumRatingKey: String?
    public let sourceCompositeKey: String?

    public init(
        trackRatingKey: String,
        oldAlbumRatingKey: String,
        newAlbumRatingKey: String?,
        sourceCompositeKey: String? = nil
    ) {
        self.trackRatingKey = trackRatingKey
        self.oldAlbumRatingKey = oldAlbumRatingKey
        self.newAlbumRatingKey = newAlbumRatingKey
        self.sourceCompositeKey = sourceCompositeKey
    }
}

public enum ArtworkInvalidationReason: String, Sendable, Hashable {
    case pathChanged
    case metadataModified
    case removed
}

/// Describes artwork that should be evicted after sync metadata changes.
public struct ArtworkInvalidationInfo: Sendable, Hashable {
    public let ratingKey: String
    public let type: ArtworkType
    public let reason: ArtworkInvalidationReason
    public let sourceCompositeKey: String?

    public init(
        ratingKey: String,
        type: ArtworkType,
        reason: ArtworkInvalidationReason,
        sourceCompositeKey: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.type = type
        self.reason = reason
        self.sourceCompositeKey = sourceCompositeKey
    }
}

final class ArtworkInvalidationBuffer: @unchecked Sendable {
    private var pendingInfo: [ArtworkInvalidationInfo] = []
    private let lock = NSLock()

    func drain() -> [ArtworkInvalidationInfo] {
        lock.lock()
        defer { lock.unlock() }
        let info = pendingInfo
        pendingInfo = []
        return info
    }

    func record(_ info: ArtworkInvalidationInfo) {
        lock.lock()
        defer { lock.unlock() }
        if let index = pendingInfo.firstIndex(where: {
            $0.ratingKey == info.ratingKey
                && $0.type == info.type
                && $0.sourceCompositeKey == info.sourceCompositeKey
        }) {
            if info.reason == .removed {
                pendingInfo[index] = info
            }
            return
        }
        pendingInfo.append(info)
    }

    func discard(sourceCompositeKey: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingInfo.removeAll { $0.sourceCompositeKey == sourceCompositeKey }
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

/// Aggregated track metadata for a single music source.
public struct TrackSourceStats: Sendable, Equatable {
    public let trackCount: Int
    public let totalDurationMs: Int64

    public init(trackCount: Int, totalDurationMs: Int64) {
        self.trackCount = trackCount
        self.totalDurationMs = totalDurationMs
    }
}

public protocol LibraryRepositoryProtocol: Sendable {
    /// Refresh the context to ensure fresh data from the store
    func refreshContext() async

    // Artists
    func fetchArtists() async throws -> [CDArtist]
    func fetchArtists(forSource sourceCompositeKey: String) async throws -> [CDArtist]
    func countArtists(sourceCompositeKeys: Set<String>?) async throws -> Int
    func fetchArtist(ratingKey: String) async throws -> CDArtist?
    func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist?
    func fetchArtists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDArtist]
    func fetchArtistThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String]
    func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws

    // Albums
    func fetchAlbums() async throws -> [CDAlbum]
    func fetchAlbums(forSource sourceCompositeKey: String) async throws -> [CDAlbum]
    func countAlbums(sourceCompositeKeys: Set<String>?) async throws -> Int
    func fetchAlbum(ratingKey: String) async throws -> CDAlbum?
    func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum?
    func fetchAlbums(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDAlbum]
    func fetchAlbumThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String]
    func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws
    func deleteAlbum(ratingKey: String, sourceCompositeKey: String?) async throws
    func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum]
    func fetchAlbums(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDAlbum]

    // Tracks
    func fetchTracks() async throws -> [CDTrack]
    func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchTracksBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDTrack]
    func fetchTrackStatsBySource(sourceCompositeKeys: Set<String>) async throws -> [String: TrackSourceStats]
    func countTracks(sourceCompositeKeys: Set<String>?) async throws -> Int
    func countTracks(forSource sourceCompositeKey: String) async throws -> Int
    func fetchSiriEligibleTracks() async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack]
    func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack]
    func fetchFavoriteTracks() async throws -> [CDTrack]
    func fetchTrack(ratingKey: String) async throws -> CDTrack?
    func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack?
    func fetchTrackArtworkFallback(
        title: String,
        albumName: String?,
        artistName: String?,
        excludingRatingKey: String,
        excludingSourceCompositeKey: String?
    ) async throws -> CDTrack?
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
    func batchUpsertGenres(_ inputs: [GenreUpsertInput], sourceCompositeKey: String) async throws

    // Search
    func searchTracks(query: String) async throws -> [CDTrack]
    func searchArtists(query: String) async throws -> [CDArtist]
    func searchAlbums(query: String) async throws -> [CDAlbum]
    func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack]
    func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist]
    func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum]

    // Source management
    func fetchMusicSources() async throws -> [CDMusicSource]
    func countMusicSources() async throws -> Int
    func countLibraryMetadataItems() async throws -> Int

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
    func fetchArtistSyncMetadata(forSource sourceKey: String) async throws -> [String: ArtistSyncMetadata]
    func fetchAlbumSyncMetadata(forSource sourceKey: String) async throws -> [String: AlbumSyncMetadata]
    func fetchTrackSyncMetadata(forSource sourceKey: String) async throws -> [String: TrackSyncMetadata]
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

    /// Returns and clears artwork invalidations accumulated during artist/album upserts.
    func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo]

    /// Discards pending artwork invalidations owned by a removed source.
    func discardArtworkInvalidations(forSourceCompositeKey sourceCompositeKey: String)
}

public extension LibraryRepositoryProtocol {
    func fetchArtists(forSource sourceCompositeKey: String) async throws -> [CDArtist] {
        try await fetchArtists().filter { $0.sourceCompositeKey == sourceCompositeKey }
    }

    func fetchAlbums(forSource sourceCompositeKey: String) async throws -> [CDAlbum] {
        try await fetchAlbums().filter { $0.sourceCompositeKey == sourceCompositeKey }
    }

    func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist? {
        guard let sourceCompositeKey,
              let artist = try await fetchArtist(ratingKey: ratingKey),
              artist.sourceCompositeKey == sourceCompositeKey else { return nil }
        return artist
    }

    func fetchArtists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDArtist] {
        guard !references.isEmpty else { return [:] }
        var result: [String: CDArtist] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let artist = try await fetchArtist(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            ) {
                result[reference.lookupKey] = artist
            }
        }
        return result
    }

    func fetchArtistThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let thumbPath = try await fetchArtist(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            )?.thumbPath {
                result[reference.lookupKey] = thumbPath
            }
        }
        return result
    }

    func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum? {
        guard let sourceCompositeKey,
              let album = try await fetchAlbum(ratingKey: ratingKey),
              album.sourceCompositeKey == sourceCompositeKey else { return nil }
        return album
    }

    func fetchAlbums(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDAlbum] {
        guard !references.isEmpty else { return [:] }
        var result: [String: CDAlbum] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let album = try await fetchAlbum(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            ) {
                result[reference.lookupKey] = album
            }
        }
        return result
    }

    func fetchAlbumThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let thumbPath = try await fetchAlbum(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            )?.thumbPath {
                result[reference.lookupKey] = thumbPath
            }
        }
        return result
    }

    func fetchAlbums(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDAlbum] {
        try await fetchAlbums(forArtist: artistRatingKey).filter {
            $0.sourceCompositeKey == sourceCompositeKey
        }
    }
}

public extension LibraryRepositoryProtocol {
    func countArtists(sourceCompositeKeys: Set<String>?) async throws -> Int {
        let artists = try await fetchArtists()
        guard let sourceCompositeKeys else { return artists.count }
        guard !sourceCompositeKeys.isEmpty else { return 0 }
        return artists.filter {
            guard let sourceCompositeKey = $0.sourceCompositeKey else { return false }
            return sourceCompositeKeys.contains(sourceCompositeKey)
        }.count
    }

    func countAlbums(sourceCompositeKeys: Set<String>?) async throws -> Int {
        let albums = try await fetchAlbums()
        guard let sourceCompositeKeys else { return albums.count }
        guard !sourceCompositeKeys.isEmpty else { return 0 }
        return albums.filter {
            guard let sourceCompositeKey = $0.sourceCompositeKey else { return false }
            return sourceCompositeKeys.contains(sourceCompositeKey)
        }.count
    }

    func countTracks(sourceCompositeKeys: Set<String>?) async throws -> Int {
        let tracks = try await fetchTracks()
        guard let sourceCompositeKeys else { return tracks.count }
        guard !sourceCompositeKeys.isEmpty else { return 0 }
        return tracks.filter {
            guard let sourceCompositeKey = $0.sourceCompositeKey else { return false }
            return sourceCompositeKeys.contains(sourceCompositeKey)
        }.count
    }

    func fetchTracksBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDTrack] {
        guard !references.isEmpty else { return [:] }
        var result: [String: CDTrack] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let track = try await fetchTrack(
                ratingKey: reference.trackRatingKey,
                sourceCompositeKey: reference.trackSourceCompositeKey
            ) {
                result[reference.membershipID] = track
            }
        }
        return result
    }

    func fetchTrackStatsBySource(sourceCompositeKeys: Set<String>) async throws -> [String: TrackSourceStats] {
        guard !sourceCompositeKeys.isEmpty else { return [:] }
        var result: [String: TrackSourceStats] = [:]
        result.reserveCapacity(sourceCompositeKeys.count)
        for sourceCompositeKey in sourceCompositeKeys {
            let tracks = try await fetchTracks(forSource: sourceCompositeKey)
            let durationMs = tracks.reduce(Int64(0)) { $0 + $1.duration }
            result[sourceCompositeKey] = TrackSourceStats(trackCount: tracks.count, totalDurationMs: durationMs)
        }
        return result
    }

    func countTracks(forSource sourceCompositeKey: String) async throws -> Int {
        try await fetchTracks(forSource: sourceCompositeKey).count
    }

    func countMusicSources() async throws -> Int {
        try await fetchMusicSources().count
    }

    func countLibraryMetadataItems() async throws -> Int {
        async let artists = fetchArtists()
        async let albums = fetchAlbums()
        async let tracks = fetchTracks()
        async let genres = fetchGenres()
        let artistCount = try await artists.count
        let albumCount = try await albums.count
        let trackCount = try await tracks.count
        let genreCount = try await genres.count
        return artistCount + albumCount + trackCount + genreCount
    }

    func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws {}
    func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {}
    func deleteAlbum(ratingKey: String, sourceCompositeKey: String?) async throws {}
    func updateTrackTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {}
    func deleteTrack(ratingKey: String, sourceCompositeKey: String?) async throws {}
    func fetchTrackArtworkFallback(
        title _: String,
        albumName _: String?,
        artistName _: String?,
        excludingRatingKey _: String,
        excludingSourceCompositeKey _: String?
    ) async throws -> CDTrack? { nil }
    func fetchGenreCoverageStats(forSource sourceKey: String) async throws -> GenreCoverageStats? { nil }
    func fetchArtistSyncMetadata(forSource sourceKey: String) async throws -> [String: ArtistSyncMetadata] { [:] }
    func fetchAlbumSyncMetadata(forSource sourceKey: String) async throws -> [String: AlbumSyncMetadata] { [:] }
    func fetchTrackSyncMetadata(forSource sourceKey: String) async throws -> [String: TrackSyncMetadata] { [:] }
    func batchUpsertGenres(_ inputs: [GenreUpsertInput], sourceCompositeKey: String) async throws {
        for input in inputs {
            _ = try await upsertGenre(
                ratingKey: input.ratingKey,
                key: input.key,
                title: input.title,
                sourceCompositeKey: sourceCompositeKey
            )
        }
    }
    func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo] { [] }
    func discardArtworkInvalidations(forSourceCompositeKey sourceCompositeKey: String) {}
}

public final class LibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
    let coreDataStack: CoreDataStack

    public var backingCoreDataStack: CoreDataStack {
        coreDataStack
    }

    // Accumulator for tracks whose album changed during upsert.
    // Protected by reparentLock; drained by SyncCoordinator after sync.
    private var pendingReparentInfo: [TrackReparentInfo] = []
    private let reparentLock = NSLock()
    private let artworkInvalidations = ArtworkInvalidationBuffer()

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

    public func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo] {
        artworkInvalidations.drain()
    }

    public func discardArtworkInvalidations(forSourceCompositeKey sourceCompositeKey: String) {
        artworkInvalidations.discard(sourceCompositeKey: sourceCompositeKey)
    }

    func recordArtworkInvalidation(_ info: ArtworkInvalidationInfo) {
        artworkInvalidations.record(info)
    }

    func recordArtworkInvalidationIfNeeded(
        ratingKey: String,
        type: ArtworkType,
        sourceCompositeKey: String,
        oldThumbPath: String?,
        oldArtPath: String?,
        oldDateModified: Date?,
        newThumbPath: String?,
        newArtPath: String?,
        newDateModified: Date?
    ) {
        if oldThumbPath != newThumbPath || oldArtPath != newArtPath {
            recordArtworkInvalidation(ArtworkInvalidationInfo(
                ratingKey: ratingKey,
                type: type,
                reason: .pathChanged,
                sourceCompositeKey: sourceCompositeKey
            ))
            return
        }

        let hasArtworkPath = !(newThumbPath ?? oldThumbPath ?? newArtPath ?? oldArtPath ?? "").isEmpty
        guard hasArtworkPath,
              Self.dateModifiedSeconds(oldDateModified) != Self.dateModifiedSeconds(newDateModified) else {
            return
        }

        recordArtworkInvalidation(ArtworkInvalidationInfo(
            ratingKey: ratingKey,
            type: type,
            reason: .metadataModified,
            sourceCompositeKey: sourceCompositeKey
        ))
    }

    private static func dateModifiedSeconds(_ date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    // MARK: - Context Refresh

    public func refreshContext() async {
        await withCheckedContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                // Background saves are merged automatically. Drain those merges
                // without invalidating objects still retained by visible views.
                context.processPendingChanges()
                continuation.resume()
            }
        }
    }

}

extension LibraryRepository {
    func relinkPlaylistMemberships(
        to tracksByRatingKey: [String: CDTrack],
        sourceCompositeKey: String,
        in context: NSManagedObjectContext
    ) throws {
        guard !tracksByRatingKey.isEmpty else { return }

        let request = CDPlaylistTrack.fetchRequest()
        request.predicate = NSPredicate(
            format: "track == nil AND trackSourceCompositeKey == %@ AND trackRatingKey IN %@",
            sourceCompositeKey,
            Array(tracksByRatingKey.keys)
        )
        for membership in try context.fetch(request) {
            guard let ratingKey = membership.trackRatingKey else { continue }
            guard let track = tracksByRatingKey[ratingKey] else { continue }
            membership.track = track
            guard let playlist = membership.playlist,
                  playlist.fallbackArtworkPath?.isEmpty != false else { continue }
            if let album = track.album,
               let path = album.thumbPath,
               !path.isEmpty {
                playlist.fallbackArtworkPath = path
                playlist.fallbackArtworkRatingKey = album.ratingKey
                playlist.fallbackArtworkSourceCompositeKey = album.sourceCompositeKey
                    ?? track.sourceCompositeKey
            } else if let path = track.thumbPath ?? membership.trackThumbPath,
                      !path.isEmpty {
                playlist.fallbackArtworkPath = path
                playlist.fallbackArtworkRatingKey = nil
                playlist.fallbackArtworkSourceCompositeKey = track.sourceCompositeKey
            }
        }
    }

    func deleteTrackManagedObject(_ track: CDTrack, in context: NSManagedObjectContext) {
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
