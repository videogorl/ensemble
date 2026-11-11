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
    /// The connector vouches that an empty library is the true state, not a fault: it read the whole
    /// library and independent counts agree on zero. Plex never sets this, since an empty section
    /// there is far more likely a server fault.
    public let emptyIsAuthoritative: Bool

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
        genreIDs: [String]? = nil,
        emptyIsAuthoritative: Bool = false
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
        self.emptyIsAuthoritative = emptyIsAuthoritative
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
    /// The source read everything, so the next full read waits its interval even when no inventory was
    /// proved or applied (a withheld or empty one).
    public var readsEverything = false
    /// Tracks whose last played date and play count the source could not read this pass; their stored
    /// values are kept instead of being cleared.
    public var tracksWithoutPlayHistory: Set<String> = []
    /// Names to store on the source row; nil leaves the row's names empty, as for Plex.
    public var sourceDisplayName: String?
    public var sourceAccountName: String?
    /// When the connector began its queries; the cursors record this date.
    public var queryStartedAt: Date

    public init(
        artists: [ArtistUpsertInput] = [],
        albums: [AlbumUpsertInput] = [],
        tracks: [TrackUpsertInput] = [],
        genres: [GenreUpsertInput]? = nil,
        inventory: LibraryInventory? = nil,
        isFullMetadataPass: Bool = false,
        tracksWithoutPlayHistory: Set<String> = [],
        queryStartedAt: Date
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.genres = genres
        self.inventory = inventory
        self.isFullMetadataPass = isFullMetadataPass
        self.tracksWithoutPlayHistory = tracksWithoutPlayHistory
        self.queryStartedAt = queryStartedAt
    }
}

/// The only code that writes synced library rows, deletes from an inventory or
/// moves a library sync cursor. Library batches are not serialized here: an actor
/// lets another call in at every `await`, and `SyncCoordinator`'s per-source single
/// flight is what keeps two library applies for one source apart. Playlist
/// operations, which run alongside library syncs, are serialized by `serialized`.
///
/// Deletion contract: rows are deleted only from a complete inventory. An empty
/// inventory deletes only when its connector marked it authoritative, a stale batch is ignored whole, and a failed,
/// partial or cancelled pass leaves the cursor due.
///
/// Playlists follow the same contract, with these differences: a batch whose read began before the newest
/// committed list read is ignored whole; an empty playlist inventory never
/// deletes (decision 2), and a body deletes membership rows only when the connector attached it,
/// which it does only for a complete read. An empty body is a complete read of an empty playlist.
public actor LibraryWriter {
    static let inventoryInterval: TimeInterval = 24 * 60 * 60

    /// How long a local edit stays in `localEdits` before it is pruned. The map only matters to a read that
    /// began before the edit, and no read stays in flight this long.
    static let localEditRetention: TimeInterval = 60 * 60

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let cursors: SyncCursorRepositoryProtocol?
    private let pendingMutations: PendingMutationRepositoryProtocol?
    /// When each playlist (scope and ID) was last edited locally. It protects the edit from reads that began
    /// before it, in this process only: a restart forgets it, and the optimistic row then waits for the next
    /// read like any other (see ON_DECK.md).
    private var localEdits: [String: Date] = [:]

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCursorRepository: SyncCursorRepositoryProtocol?,
        pendingMutationRepository: PendingMutationRepositoryProtocol? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
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
        try await ensureSource(source, batch: batch)
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
        } else if batch.readsEverything {
            try await cursors?.recordFullRead(scopeKey: key, scopeType: .library, at: batch.queryStartedAt)
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
        try await ensureSource(source, batch: batch)
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

    // MARK: - Playlists

    // Every playlist operation below runs on one serial chain. An actor does not run a call to its end
    // before starting the next: each `await` lets another call in, so a list apply, a local edit and an
    // append would interleave their reads and writes. The chain is separate from the library's, so a
    // long library write never delays a local playlist edit.

    private var playlistChain: Task<Void, Never>?

    /// Runs `operation` after every earlier playlist operation finished, in call order. A cancelled caller
    /// cancels its own operation; the chain goes on.
    private func serialized<Value: Sendable>(_ operation: @escaping () async throws -> Value) async throws -> Value {
        let previous = playlistChain
        let task = Task { () throws -> Value in
            await previous?.value
            try RefreshExecution.checkCancellation()
            return try await operation()
        }
        playlistChain = Task { _ = await task.result }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The listed playlists whose bodies must be read: new ones, ones whose date changed or is missing,
    /// and ones with no stored body under a non-empty header. A header older than the stored one needs none.
    public func playlistsNeedingBodies(_ headers: [PlaylistUpsertInput], for scope: String) async throws -> [PlaylistUpsertInput] {
        let stored = try await playlistRepository.fetchPlaylistSyncStates(forSource: scope)
        return headers.filter { Self.needsBody($0, stored: stored[$0.ratingKey]) }
    }

    /// Applies a playlist read. A batch whose read began before the newest committed full-list read is
    /// ignored whole, so an older read finishing late can neither delete nor resurrect a playlist, and a
    /// targeted read cannot overwrite what a newer pass wrote. A header with a needed but missing body
    /// keeps its stored date, so the next read tries again, and is reported as unresolved; the date
    /// advances only in the save after its body. Deletion needs the batch's complete, non-empty inventory.
    @discardableResult
    public func apply(_ batch: PlaylistBatch, for scope: String) async throws -> PlaylistSyncResult {
        try await serialized { try await self.applyBatch(batch, for: scope) }
    }

    private func applyBatch(_ batch: PlaylistBatch, for scope: String) async throws -> PlaylistSyncResult {
        // A cursor dated in the future means the clock went backwards, not that this batch is old.
        if let newest = try await cursors?.fetchCursor(scopeKey: scope, scopeType: .serverPlaylists)?.lastSuccessfulSyncAt,
           batch.queryStartedAt <= newest, newest <= Date() {
            EnsembleLogger.info("Ignoring a stale playlist batch for \(scope): query started before the last committed list read")
            return PlaylistSyncResult()
        }
        let stored = try await playlistRepository.fetchPlaylistSyncStates(forSource: scope)
        let queued = try await queuedPlaylistMutations(in: scope)
        var changed = 0
        var unresolved: [String] = []
        for entry in batch.entries {
            try RefreshExecution.checkCancellation()
            let id = entry.header.ratingKey
            let existing = stored[id]
            guard !Self.isBlank(id), !isEditedLocally(id, in: scope, since: batch.queryStartedAt),
                  !queued.edited.contains(id),
                  existing.map({ !Self.isStale(entry.header, stored: $0) }) ?? true
            else { continue }

            var header = entry.header
            let body = Self.provenBody(entry.body)
            if body == nil, Self.needsBody(entry.header, stored: existing) { unresolved.append(id) }
            if let existing {
                if queued.renamed.contains(id) { header = header.replacing(title: existing.title) }
                if body == nil {
                    // Nothing new was read: keep what the header cannot state, and the date of the stored body.
                    header = header.replacing(duration: header.duration ?? existing.duration, trackCount: header.trackCount ?? existing.trackCount)
                    if Self.needsBody(entry.header, stored: existing) { header = header.replacing(dateModified: .some(existing.dateModified)) }
                }
            } else if body == nil {
                header = header.replacing(dateModified: .some(nil))
            }
            if try await write(header, body: body, scope: scope, existing: existing) { changed += 1 }
        }

        var removed = 0
        var inventoryApplied = false
        if let inventory = batch.inventory {
            if inventory.playlistIDs.isEmpty {
                EnsembleLogger.info("A complete but empty playlist inventory for \(scope) deletes nothing")
            } else {
                // A playlist edited after this read began, or with an edit still queued to upload, may not be in it yet.
                let survivors = inventory.playlistIDs
                    .union(idsEditedLocally(in: scope, since: batch.queryStartedAt))
                    .union(queued.edited).union(queued.renamed)
                try RefreshExecution.checkCancellation()
                removed = try await playlistRepository.removeOrphanedPlaylists(notIn: survivors, forSource: scope)
                await MainActor.run {
                    HiddenMediaStore.shared.removeMissing(kind: .playlist, sourceKey: scope, survivingItemIDs: survivors)
                }
                inventoryApplied = true
            }
        }

        if batch.readsFullList {
            try RefreshExecution.checkCancellation()
            if inventoryApplied {
                try await cursors?.recordInventorySync(scopeKey: scope, scopeType: .serverPlaylists, at: batch.queryStartedAt)
            } else {
                try await cursors?.recordIncrementalSync(scopeKey: scope, scopeType: .serverPlaylists, at: batch.queryStartedAt)
            }
        }
        if changed + removed > 0 { EnsembleLogger.debug("🎵 Playlists \(scope): wrote \(changed), removed \(removed)") }
        if !unresolved.isEmpty { EnsembleLogger.info("Playlists \(scope): \(unresolved.count) body reads unresolved, to retry next pass") }
        return PlaylistSyncResult(changedPlaylists: changed, removedPlaylists: removed, unresolvedPlaylists: unresolved)
    }

    /// Writes a playlist the user just created or changed, before the server shows it. Reads that began
    /// earlier cannot undo it, and an inventory read earlier cannot delete it.
    public func applyLocalEdit(_ entry: PlaylistEntry, for scope: String) async throws {
        try await serialized {
            let existing = try await self.playlistRepository.fetchPlaylistSyncStates(forSource: scope)[entry.header.ratingKey]
            self.noteLocalEdit(entry.header.ratingKey, in: scope)
            try await self.write(entry.header, body: entry.body, scope: scope, existing: existing)
        }
    }

    /// Appends tracks the user just added to a playlist, before the server shows them. The stored body is
    /// read, merged and saved inside one serialized operation, so two adds in a row both survive. Tracks the
    /// playlist already holds are skipped. Returns the track count afterwards, or nil when the playlist is not stored.
    public func appendLocally(_ tracks: [Track], toPlaylist id: String, for scope: String) async throws -> Int? {
        try await serialized {
            guard let cached = try await self.playlistRepository.fetchPlaylist(ratingKey: id, sourceCompositeKey: scope) else { return nil }
            // The object belongs to the main-queue context.
            let (header, items) = await MainActor.run {
                (PlaylistUpsertInput(
                    ratingKey: cached.ratingKey, key: cached.key, title: cached.title, summary: cached.summary,
                    compositePath: cached.compositePath, isSmart: cached.isSmart, duration: nil, trackCount: nil,
                    dateAdded: cached.dateAdded,
                    // The server's date stays, so the next read of the changed playlist replaces this body.
                    dateModified: cached.dateModified, lastPlayed: cached.lastPlayed
                ), cached.playlistItemsArray.map(PlaylistItem.init(from:)))
            }
            let newTracks = PlaylistActionService().tracks(tracks, excluding: items.map(\.track))
            guard !newTracks.isEmpty else { return items.count }

            let snapshots = items.compactMap { PlaylistTrackSnapshot($0.track, playlistItemID: $0.playlistItemID) }
                + newTracks.compactMap { PlaylistTrackSnapshot($0, playlistItemID: nil) }
            let existing = try await self.playlistRepository.fetchPlaylistSyncStates(forSource: scope)[id]
            self.noteLocalEdit(id, in: scope)
            try await self.write(
                header.replacing(duration: Int(snapshots.reduce(0) { $0 + $1.duration } * 1_000), trackCount: snapshots.count),
                body: snapshots, scope: scope, existing: existing
            )
            return snapshots.count
        }
    }

    /// Removes a playlist the server just confirmed deleted. The inventory cannot do it when it was the
    /// scope's last playlist, because an empty list deletes nothing. Reads that began earlier cannot bring it back.
    public func removePlaylist(_ id: String, for scope: String) async throws {
        try await serialized {
            self.noteLocalEdit(id, in: scope)
            try await self.playlistRepository.deletePlaylist(ratingKey: id, sourceCompositeKey: scope)
            let survivors = Set(try await self.playlistRepository.fetchPlaylistSyncStates(forSource: scope).keys)
            await MainActor.run {
                HiddenMediaStore.shared.removeMissing(kind: .playlist, sourceKey: scope, survivingItemIDs: survivors)
            }
        }
    }

    /// The last complete playlist inventory of a scope.
    public func lastPlaylistInventoryAt(_ scope: String) async throws -> Date? {
        try await cursors?.fetchCursor(scopeKey: scope, scopeType: .serverPlaylists)?.lastInventorySyncAt
    }

    /// Forgets a scope's playlist cursor.
    public func removePlaylistCursor(_ scope: String) async throws {
        try await serialized { try await self.cursors?.deleteCursor(scopeKey: scope, scopeType: .serverPlaylists) }
    }

    @discardableResult
    private func write(_ header: PlaylistUpsertInput, body: [PlaylistTrackSnapshot]?, scope: String, existing: PlaylistSyncState?) async throws -> Bool {
        if let body {
            // A body needs its playlist row; the final save carries the date.
            if existing == nil { _ = try await playlistRepository.upsertPlaylist(header.replacing(dateModified: .some(nil)), sourceCompositeKey: scope) }
            try RefreshExecution.checkCancellation()
            try await playlistRepository.setPlaylistTrackSnapshots(body, forPlaylist: header.ratingKey, sourceCompositeKey: scope)
            try RefreshExecution.checkCancellation()
            _ = try await playlistRepository.upsertPlaylist(header, sourceCompositeKey: scope)
            return true
        }
        guard existing?.headerMatches(header) != true else { return false }
        _ = try await playlistRepository.upsertPlaylist(header, sourceCompositeKey: scope)
        return true
    }

    /// Playlists with a mutation still queued to upload, from the durable pending-mutation records (which
    /// name the playlist in their payload). A queued rename keeps its local title; a queued add, remove or
    /// delete leaves the playlist's header and body alone, so a read of the server cannot undo it, and
    /// none of them can be deleted by an inventory. Creates and reorders are never queued.
    private func queuedPlaylistMutations(in scope: String) async throws -> (renamed: Set<String>, edited: Set<String>) {
        guard let pendingMutations else { return ([], []) }
        var renamed = Set<String>(), edited = Set<String>()
        for record in try await pendingMutations.fetchPendingMutationRecords() {
            let decoder = JSONDecoder()
            switch record.mutationType {
            case .playlistRename:
                if let payload = try? decoder.decode(PlaylistRenameMutationPayload.self, from: record.payload),
                   payload.playlistSourceCompositeKey == scope { renamed.insert(payload.playlistRatingKey) }
            case .playlistAdd, .playlistRemove:
                if let payload = try? decoder.decode(PlaylistMutationPayload.self, from: record.payload),
                   payload.playlistSourceCompositeKey == scope { edited.insert(payload.playlistRatingKey) }
            case .playlistDelete:
                if let payload = try? decoder.decode(PlaylistDeleteMutationPayload.self, from: record.payload),
                   payload.playlistSourceCompositeKey == scope { edited.insert(payload.playlistRatingKey) }
            default:
                continue
            }
        }
        return (renamed, edited)
    }

    private static func editKey(_ id: String, in scope: String) -> String { "\(scope)\u{0}\(id)" }

    private func noteLocalEdit(_ id: String, in scope: String) {
        localEdits = localEdits.filter { $0.value.timeIntervalSinceNow > -Self.localEditRetention }
        localEdits[Self.editKey(id, in: scope)] = Date()
    }

    private func isEditedLocally(_ id: String, in scope: String, since date: Date) -> Bool {
        localEdits[Self.editKey(id, in: scope)].map { $0 > date } ?? false
    }

    private func idsEditedLocally(in scope: String, since date: Date) -> Set<String> {
        let prefix = Self.editKey("", in: scope)
        return Set(localEdits.compactMap { $0.value > date && $0.key.hasPrefix(prefix) ? String($0.key.dropFirst(prefix.count)) : nil })
    }

    private static func isBlank(_ id: String) -> Bool { id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A body whose tracks all have IDs; a blank ID shows the read was malformed, so it is not proof.
    static func provenBody(_ body: [PlaylistTrackSnapshot]?) -> [PlaylistTrackSnapshot]? {
        body.flatMap { $0.contains { isBlank($0.ratingKey) } ? nil : $0 }
    }

    /// An older header describes an older server state than the one stored.
    static func isStale(_ header: PlaylistUpsertInput, stored: PlaylistSyncState) -> Bool {
        guard let incoming = header.dateModified, let existing = stored.dateModified else { return false }
        return incoming < existing
    }

    static func needsBody(_ header: PlaylistUpsertInput, stored: PlaylistSyncState?) -> Bool {
        guard let stored else { return true }
        guard !isStale(header, stored: stored) else { return false }
        if header.dateModified == nil || header.dateModified != stored.dateModified { return true }
        return !stored.hasMemberships && (header.trackCount ?? 0) > 0
    }

    // MARK: - Rows

    private func ensureSource(_ source: MusicSourceIdentifier, batch: LibraryBatch) async throws {
        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: source.compositeKey,
            type: source.type.rawValue,
            accountId: source.accountId,
            serverId: source.serverId,
            libraryId: source.libraryId,
            displayName: batch.sourceDisplayName,
            accountName: batch.sourceAccountName
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
        let queuedRatings = try await trackKeysWithQueuedRating(source: key)
        let tracks = batch.tracks.map { input -> TrackUpsertInput in
            guard let stored = existingTracks[input.ratingKey] else { return input }
            return input.keeping(
                ratingOf: queuedRatings.contains(input.ratingKey) ? stored : nil,
                playHistoryOf: batch.tracksWithoutPlayHistory.contains(input.ratingKey) ? stored : nil
            )
        }.filter { existingTracks[$0.ratingKey]?.matches($0) != true }

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

        // Hidden choices sync to the user's other devices and no later sync can rebuild them, so a
        // library that went wholly empty (Sync Library off, a lapsed subscription) keeps them for its return.
        if !trackIDs.isEmpty {
            await MainActor.run {
                HiddenMediaStore.shared.removeMissing(kind: .artist, sourceKey: key, survivingItemIDs: keptArtistIDs)
                HiddenMediaStore.shared.removeMissing(kind: .album, sourceKey: key, survivingItemIDs: inventory.albumIDs)
                HiddenMediaStore.shared.removeMissing(kind: .track, sourceKey: key, survivingItemIDs: trackIDs)
            }
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
    /// The input with the stored rating, favourite flag and rating date, and/or the stored last played
    /// date and play count, in place of the fetched ones.
    func keeping(ratingOf ratingStored: TrackSyncMetadata?, playHistoryOf historyStored: TrackSyncMetadata?) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: ratingKey, key: key, title: title, artistName: artistName, albumName: albumName,
            albumRatingKey: albumRatingKey, trackNumber: trackNumber, discNumber: discNumber, duration: duration,
            thumbPath: thumbPath, streamKey: streamKey, streamId: streamId, dateAdded: dateAdded,
            dateModified: dateModified, lastPlayed: historyStored.map(\.lastPlayed) ?? lastPlayed,
            lastRatedAt: ratingStored.map(\.lastRatedAt) ?? lastRatedAt,
            rating: ratingStored?.rating ?? rating, isFavorite: ratingStored.map(\.isFavorite) ?? isFavorite,
            playCount: historyStored?.playCount ?? playCount, genreNames: genreNames,
            updatesDateAdded: updatesDateAdded, actionCapabilitiesData: actionCapabilitiesData
        )
    }
}

extension LibraryInventory {
    /// An inventory with no artists, albums or tracks cannot show that a stored row is gone, unless the
    /// connector vouches for a library that is empty throughout. A partly empty one never deletes.
    var cannotProveDeletion: Bool {
        let isEmpty = artistIDs.isEmpty && albumIDs.isEmpty && trackParents.isEmpty
        if isEmpty && emptyIsAuthoritative { return false }
        return artistIDs.isEmpty || albumIDs.isEmpty || trackParents.isEmpty
    }
}
