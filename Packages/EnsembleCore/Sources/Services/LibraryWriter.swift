import EnsemblePersistence
import Foundation

/// What a connector needs to fetch a library. Built from the cursor and the
/// store so a connector never holds a repository.
public struct LibrarySyncPlan: Sendable {
    /// Fetch items changed after this date; nil fetches the whole library.
    public let since: Date?
    /// The last complete inventory is older than a day, or never happened.
    public let inventoryDue: Bool
    /// Every row's metadata is due for a full comparison.
    public let fullMetadataDue: Bool
    public let stored: StoredLibrary

    public init(since: Date?, inventoryDue: Bool, fullMetadataDue: Bool, stored: StoredLibrary) {
        self.since = since
        self.inventoryDue = inventoryDue
        self.fullMetadataDue = fullMetadataDue
        self.stored = stored
    }
}

/// The source's stored rows, as the change-detection fields a connector compares.
public struct StoredLibrary: Sendable {
    public var artists: [String: ArtistSyncMetadata]
    public var albums: [String: AlbumSyncMetadata]
    public var tracks: [String: TrackSyncSummary]

    public init(
        artists: [String: ArtistSyncMetadata] = [:],
        albums: [String: AlbumSyncMetadata] = [:],
        tracks: [String: TrackSyncSummary] = [:]
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

public enum LibraryWriterError: Error, Equatable {
    /// An inventory with blank or repeated IDs, or a track whose album is not in it, is not complete.
    case invalidInventory(String)
}

/// Every ID the source holds, proven complete by the connector. The only input
/// from which `LibraryWriter` deletes.
public struct LibraryInventory: Sendable, Equatable {
    public let artistIDs: Set<String>
    public let albumIDs: Set<String>
    /// Track ID to album ID.
    public let trackParents: [String: String]
    /// Nil when the source does not list genres in this pass.
    public let genreIDs: Set<String>?

    /// Track count per album, including albums with no tracks.
    public var trackCounts: [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: albumIDs.map { ($0, 0) })
        for parent in trackParents.values { counts[parent, default: 0] += 1 }
        return counts
    }

    /// Throws `invalidInventory` for blank IDs, repeated album or track IDs, or a
    /// track without an album in `albumIDs`.
    public init(
        artistIDs: [String],
        albumIDs: [String],
        tracks: [(id: String, albumID: String?)],
        genreIDs: [String]? = nil
    ) throws {
        func isBlank(_ id: String) -> Bool { id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !artistIDs.contains(where: isBlank) else { throw LibraryWriterError.invalidInventory("blank artist ID") }
        let albums = Set(albumIDs)
        guard albums.count == albumIDs.count, !albumIDs.contains(where: isBlank) else {
            throw LibraryWriterError.invalidInventory("blank or repeated album ID")
        }
        var parents: [String: String] = [:]
        parents.reserveCapacity(tracks.count)
        for track in tracks {
            guard !isBlank(track.id), let album = track.albumID, albums.contains(album),
                  parents.updateValue(album, forKey: track.id) == nil
            else { throw LibraryWriterError.invalidInventory("blank or repeated track ID, or track without an album") }
        }
        self.artistIDs = Set(artistIDs)
        self.albumIDs = albums
        self.trackParents = parents
        self.genreIDs = genreIDs.map(Set.init)
    }
}

/// Rows a connector fetched, ready to write. Without an inventory a batch is a
/// delta and never deletes.
public struct LibraryBatch: Sendable {
    public var artists: [ArtistUpsertInput] = []
    public var albums: [AlbumUpsertInput] = []
    public var tracks: [TrackUpsertInput] = []
    public var genres: [GenreUpsertInput]?
    public var inventory: LibraryInventory?
    /// Every row's metadata was fetched and compared, not only the changed ones.
    public var isFullMetadataPass = false
    /// When the connector began its queries; the cursors record this date.
    public var queryStartedAt: Date

    public init(
        artists: [ArtistUpsertInput] = [],
        albums: [AlbumUpsertInput] = [],
        tracks: [TrackUpsertInput] = [],
        genres: [GenreUpsertInput]? = nil,
        inventory: LibraryInventory? = nil,
        isFullMetadataPass: Bool = false,
        queryStartedAt: Date
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.genres = genres
        self.inventory = inventory
        self.isFullMetadataPass = isFullMetadataPass
        self.queryStartedAt = queryStartedAt
    }
}

/// The only code that writes synced library rows, deletes from an inventory or
/// moves a library sync cursor. One batch is applied at a time, so sync paths
/// cannot race a fetch against an insert.
///
/// Deletion contract: rows are deleted only from a complete inventory. An empty
/// inventory never deletes, a stale batch is ignored whole, and a failed,
/// partial or cancelled pass leaves the cursor due.
public actor LibraryWriter {
    static let inventoryInterval: TimeInterval = 24 * 60 * 60

    private let libraryRepository: LibraryRepositoryProtocol
    private let cursors: SyncCursorRepositoryProtocol?
    private let pendingMutations: PendingMutationRepositoryProtocol?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        syncCursorRepository: SyncCursorRepositoryProtocol?,
        pendingMutationRepository: PendingMutationRepositoryProtocol? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.cursors = syncCursorRepository
        self.pendingMutations = pendingMutationRepository
    }

    /// Plans a fetch. A nil `since` plans a full library fetch.
    public func libraryPlan(for source: MusicSourceIdentifier, since: Date?, now: Date = Date()) async throws -> LibrarySyncPlan {
        let key = source.compositeKey
        let cursor = try await cursors?.fetchCursor(scopeKey: key, scopeType: .library)
        async let artists = libraryRepository.fetchArtistSyncMetadata(forSource: key)
        async let albums = libraryRepository.fetchAlbumSyncMetadata(forSource: key)
        async let tracks = libraryRepository.fetchTrackSummaries(forSource: key)
        return LibrarySyncPlan(
            since: since,
            inventoryDue: since == nil || Self.isDue(cursor?.lastInventorySyncAt, now: now),
            fullMetadataDue: since == nil || Self.isDue(cursor?.lastFullSyncAt, now: now),
            stored: StoredLibrary(artists: try await artists, albums: try await albums, tracks: try await tracks)
        )
    }

    /// Applies a sync pass and advances the cursors after everything committed.
    @discardableResult
    public func apply(_ batch: LibraryBatch, to source: MusicSourceIdentifier) async throws -> LibrarySyncResult {
        let key = source.compositeKey
        // A cursor dated in the future means the clock went backwards, not that this batch is old.
        if let newest = try await cursors?.fetchCursor(scopeKey: key, scopeType: .library)?.lastSuccessfulSyncAt,
           batch.queryStartedAt <= newest, newest <= Date() {
            EnsembleLogger.info("Ignoring a stale library batch for \(key): query started before the last committed pass")
            return LibrarySyncResult()
        }
        try await ensureSource(source)
        var result = try await writeRows(batch, key: key)

        var inventoryApplied = false
        if let inventory = batch.inventory {
            if inventory.cannotProveDeletion {
                EnsembleLogger.info("A complete but empty library inventory for \(key) deletes nothing")
            } else {
                result = try await removeMissing(inventory, key: key, after: result)
                inventoryApplied = true
            }
        }

        try RefreshExecution.checkCancellation()
        if inventoryApplied {
            if batch.isFullMetadataPass {
                try await cursors?.recordFullSync(scopeKey: key, scopeType: .library, at: batch.queryStartedAt)
            } else {
                try await cursors?.recordInventorySync(scopeKey: key, scopeType: .library, at: batch.queryStartedAt)
            }
        }
        try await cursors?.recordIncrementalSync(scopeKey: key, scopeType: .library, at: batch.queryStartedAt)
        try RefreshExecution.checkCancellation()
        try await libraryRepository.updateMusicSourceSyncTimestamp(compositeKey: key)
        return result
    }

    /// Applies a delta from a live channel. It never deletes and moves no cursor
    /// except to mark the inventory due.
    @discardableResult
    public func applyChanges(_ batch: LibraryBatch, to source: MusicSourceIdentifier) async throws -> LibrarySyncResult {
        try await ensureSource(source)
        return try await writeRows(batch, key: source.compositeKey)
    }

    /// Marks the next pass as owing a complete inventory.
    public func invalidateInventory(for source: MusicSourceIdentifier) async throws {
        try await cursors?.invalidateInventorySync(scopeKey: source.compositeKey, scopeType: .library)
    }

    /// Forgets the library cursor, so the next pass is authoritative.
    public func removeCursor(for source: MusicSourceIdentifier) async throws {
        try await cursors?.deleteCursor(scopeKey: source.compositeKey, scopeType: .library)
    }

    // MARK: - Rows

    private func ensureSource(_ source: MusicSourceIdentifier) async throws {
        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: source.compositeKey,
            type: source.type.rawValue,
            accountId: source.accountId,
            serverId: source.serverId,
            libraryId: source.libraryId,
            displayName: nil,
            accountName: nil
        )
    }

    /// Writes the inputs that differ from the stored rows. A delta that adds a
    /// track, moves one to another album, or changes an album's count marks the
    /// inventory due first, so a cancelled pass still reconciles.
    private func writeRows(_ batch: LibraryBatch, key: String) async throws -> LibrarySyncResult {
        async let storedArtists = metadata(batch.artists.map(\.ratingKey)) {
            try await self.libraryRepository.fetchArtistSyncMetadata(forSource: key, ratingKeys: $0)
        }
        async let storedAlbums = metadata(batch.albums.map(\.ratingKey)) {
            try await self.libraryRepository.fetchAlbumSyncMetadata(forSource: key, ratingKeys: $0)
        }
        async let storedTracks = metadata(batch.tracks.map(\.ratingKey)) {
            try await self.libraryRepository.fetchTrackSyncMetadata(forSource: key, ratingKeys: $0)
        }
        let existingArtists = try await storedArtists
        let existingAlbums = try await storedAlbums
        let existingTracks = try await storedTracks

        let artists = batch.artists.filter { existingArtists[$0.ratingKey]?.matches($0) != true }
        let albums = batch.albums.filter { existingAlbums[$0.ratingKey]?.matches($0) != true }
        // A rating or favourite still waiting to upload is newer than the server's value.
        let pendingRatings = try await trackKeysWithQueuedRating(source: key)
        let tracks = batch.tracks
            .map { pendingRatings.contains($0.ratingKey) ? $0.keepingRating(of: existingTracks[$0.ratingKey]) : $0 }
            .filter { existingTracks[$0.ratingKey]?.matches($0) != true }

        let membershipChanged = tracks.contains { existingTracks[$0.ratingKey]?.albumRatingKey != $0.albumRatingKey }
            || albums.contains { album in
                guard let stored = existingAlbums[album.ratingKey] else { return true }
                return album.trackCount.map { $0 != stored.trackCount } == true
            }
        if membershipChanged {
            try RefreshExecution.checkCancellation()
            try await cursors?.invalidateInventorySync(scopeKey: key, scopeType: .library)
        }

        try RefreshExecution.checkCancellation()
        try await libraryRepository.batchUpsertArtists(artists, sourceCompositeKey: key)
        try RefreshExecution.checkCancellation()
        try await libraryRepository.batchUpsertAlbums(albums, sourceCompositeKey: key)
        try RefreshExecution.checkCancellation()
        try await libraryRepository.batchUpsertTracks(tracks, sourceCompositeKey: key)
        if let genres = batch.genres {
            try RefreshExecution.checkCancellation()
            try await libraryRepository.batchUpsertGenres(genres, sourceCompositeKey: key)
        }
        return LibrarySyncResult(
            changedArtists: artists.count,
            changedAlbums: albums.count,
            changedTracks: tracks.count,
            changedGenres: batch.genres?.count ?? 0
        )
    }

    private func trackKeysWithQueuedRating(source key: String) async throws -> Set<String> {
        guard let pendingMutations else { return [] }
        return Set(try await pendingMutations.fetchPendingMutationRecords().compactMap { record in
            guard record.mutationType == .trackRating,
                  let payload = try? JSONDecoder().decode(TrackRatingMutationPayload.self, from: record.payload),
                  payload.sourceCompositeKey == key
            else { return nil }
            return payload.trackRatingKey
        })
    }

    /// An empty key set would read the whole source, so no keys reads nothing.
    private func metadata<Value>(
        _ ratingKeys: [String],
        _ fetch: (Set<String>) async throws -> [String: Value]
    ) async throws -> [String: Value] {
        ratingKeys.isEmpty ? [:] : try await fetch(Set(ratingKeys))
    }

    // MARK: - Deletion

    private func removeMissing(
        _ inventory: LibraryInventory,
        key: String,
        after written: LibrarySyncResult
    ) async throws -> LibrarySyncResult {
        let trackIDs = Set(inventory.trackParents.keys)
        let removedTrackIDs = Set(try await libraryRepository.fetchTrackSummaries(forSource: key).keys)
            .subtracting(trackIDs)

        try RefreshExecution.checkCancellation()
        let removedTracks = try await libraryRepository.removeOrphanedTracks(notIn: trackIDs, forSource: key)
        try RefreshExecution.checkCancellation()
        let removedAlbums = try await libraryRepository.removeOrphanedAlbums(notIn: inventory.albumIDs, forSource: key)
        try RefreshExecution.checkCancellation()
        // Removing an artist cascades into its albums and their tracks. The inventory proves
        // track-to-album closure but not album-to-artist (the album inventory carries no
        // parent), so an artist missing from it is kept while a surviving album still has it.
        let albumArtists = try await libraryRepository.fetchAlbumSyncMetadata(forSource: key)
            .values.compactMap(\.artistRatingKey)
        let keptArtistIDs = inventory.artistIDs.union(albumArtists)
        let removedArtists = try await libraryRepository.removeOrphanedArtists(notIn: keptArtistIDs, forSource: key)
        var removedGenres = 0
        if let genreIDs = inventory.genreIDs, !genreIDs.isEmpty {
            try RefreshExecution.checkCancellation()
            removedGenres = try await libraryRepository.removeOrphanedGenres(notIn: genreIDs, forSource: key)
        }
        try RefreshExecution.checkCancellation()
        let recounted = try await libraryRepository.batchUpdateAlbumTrackCounts(inventory.trackCounts, forSource: key)

        await MainActor.run {
            HiddenMediaStore.shared.removeMissing(kind: .artist, sourceKey: key, survivingItemIDs: keptArtistIDs)
            HiddenMediaStore.shared.removeMissing(kind: .album, sourceKey: key, survivingItemIDs: inventory.albumIDs)
            HiddenMediaStore.shared.removeMissing(kind: .track, sourceKey: key, survivingItemIDs: trackIDs)
        }
        if removedArtists + removedAlbums + removedTracks + removedGenres > 0 {
            EnsembleLogger.debug(
                "🧹 Removed from \(key): \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks, \(removedGenres) genres"
            )
        }
        return LibrarySyncResult(
            changedArtists: written.changedArtists,
            changedAlbums: written.changedAlbums + recounted,
            changedTracks: written.changedTracks,
            changedGenres: written.changedGenres,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks,
            removedTrackRatingKeys: removedTrackIDs,
            removedGenres: removedGenres
        )
    }

    static func isDue(_ lastAt: Date?, now: Date, interval: TimeInterval = inventoryInterval) -> Bool {
        guard let lastAt else { return true }
        let age = now.timeIntervalSince(lastAt)
        return age < 0 || age >= interval
    }
}

extension TrackUpsertInput {
    /// The input with the stored row's rating, favourite flag and rating date; unchanged for a new track.
    func keepingRating(of stored: TrackSyncMetadata?) -> TrackUpsertInput {
        guard let stored else { return self }
        return TrackUpsertInput(
            ratingKey: ratingKey, key: key, title: title, artistName: artistName, albumName: albumName,
            albumRatingKey: albumRatingKey, trackNumber: trackNumber, discNumber: discNumber, duration: duration,
            thumbPath: thumbPath, streamKey: streamKey, streamId: streamId, dateAdded: dateAdded,
            dateModified: dateModified, lastPlayed: lastPlayed, lastRatedAt: stored.lastRatedAt,
            rating: stored.rating, isFavorite: stored.isFavorite, playCount: playCount, genreNames: genreNames,
            updatesDateAdded: updatesDateAdded, actionCapabilitiesData: actionCapabilitiesData
        )
    }
}

extension LibraryInventory {
    /// An inventory with no artists, albums or tracks cannot show that a stored row is gone.
    var cannotProveDeletion: Bool { artistIDs.isEmpty || albumIDs.isEmpty || trackParents.isEmpty }
}
