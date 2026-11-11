import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Syncs a single Plex server+library to CoreData
public final class PlexConnector:
    MusicSourceConnector,
    MusicSourceChangeFetching,
    MusicSourceTwoPhasePlaybackResolving,
    MusicSourceRatingMutating,
    MusicSourceCollectionRatingMutating,
    MusicSourcePlaylistMutating,
    MusicSourcePlaybackReporting,
    MusicSourceDetailProviding,
    MusicSourceFileInfoProviding,
    MusicSourceLyricsProviding,
    MusicSourceRadioProviding,
    @unchecked Sendable
{
    public let sourceIdentifier: MusicSourceIdentifier
    private let apiClient: PlexAPIClient
    private let enabledSectionKeys: [String]
    /// Library section key used for API calls. Internal for WebSocket-triggered sync matching.
    let sectionKey: String

    public init(
        sourceIdentifier: MusicSourceIdentifier,
        apiClient: PlexAPIClient,
        sectionKey: String,
        enabledSectionKeys: [String] = []
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.apiClient = apiClient
        self.sectionKey = sectionKey
        self.enabledSectionKeys = Self.playlistSeedSectionKeys(
            primary: sectionKey,
            enabled: enabledSectionKeys
        )
    }

    enum PlaylistEditOperation: Equatable {
        case remove(itemID: String)
        case move(itemID: String, afterItemID: String?)
    }

    static func playlistSeedSectionKeys(primary: String, enabled: [String]) -> [String] {
        var seen = Set<String>()
        return ([primary] + enabled).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isConvergedPlaylistDeleteError(_ error: Error) -> Bool {
        guard let error = error as? PlexAPIError,
              case .httpError(statusCode: 404) = error else {
            return false
        }
        return true
    }

    static func playlistEditOperations(
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) throws -> [PlaylistEditOperation] {
        guard originalItems.allSatisfy({ $0.playlistItemID != nil }),
              editedItems.allSatisfy({ $0.playlistItemID != nil }) else {
            throw PlaylistMutationError.incompletePlaylistContents
        }

        let originalIDs = originalItems.compactMap(\.playlistItemID)
        let desiredIDs = editedItems.compactMap(\.playlistItemID)
        guard Set(originalIDs).count == originalIDs.count,
              Set(desiredIDs).count == desiredIDs.count,
              Set(desiredIDs).isSubset(of: Set(originalIDs)) else {
            throw PlaylistMutationError.incompletePlaylistContents
        }

        let desiredSet = Set(desiredIDs)
        var operations = originalIDs
            .filter { !desiredSet.contains($0) }
            .map { PlaylistEditOperation.remove(itemID: $0) }
        var currentIDs = originalIDs.filter(desiredSet.contains)
        for (targetIndex, itemID) in desiredIDs.enumerated() where currentIDs[targetIndex] != itemID {
            guard let currentIndex = currentIDs.firstIndex(of: itemID) else { continue }
            currentIDs.remove(at: currentIndex)
            currentIDs.insert(itemID, at: targetIndex)
            operations.append(.move(
                itemID: itemID,
                afterItemID: targetIndex == 0 ? nil : desiredIDs[targetIndex - 1]
            ))
        }
        return operations
    }

    /// Creates a regular Plex audio playlist, including Plex's empty-playlist seed workaround.
    public func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
        let trackIDs = tracks.map(\.id)
        var seededEmptyPlaylist = false
        do {
            try await apiClient.createPlaylist(
                title: title,
                trackRatingKeys: trackIDs,
                serverIdentifier: sourceIdentifier.serverId
            )
        } catch let error as PlexAPIError {
            guard trackIDs.isEmpty,
                  case .httpError(statusCode: 400) = error,
                  let seedTrackID = await playlistSeedTrackID() else {
                throw error
            }

            try await apiClient.createPlaylist(
                title: title,
                trackRatingKeys: [seedTrackID],
                serverIdentifier: sourceIdentifier.serverId
            )
            seededEmptyPlaylist = true
        }

        guard let playlist = try await Self.pollForCreatedPlaylist(
            title: title,
            seededEmptyPlaylist: seededEmptyPlaylist,
            fetchPlaylists: { try await self.apiClient.getPlaylists() },
            clearPlaylistItems: { try await self.apiClient.clearPlaylistItems(playlistId: $0) }
        ) else { return nil }
        return Playlist(
            id: playlist.ratingKey,
            key: playlist.key,
            title: playlist.title,
            summary: playlist.summary,
            trackCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            compositePath: playlist.composite,
            dateAdded: playlist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: playlist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: playlist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            sourceCompositeKey: "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)",
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: true,
                canRename: true,
                canReorder: true,
                canDelete: true
            )
        )
    }

    static func pollForCreatedPlaylist(
        title: String,
        seededEmptyPlaylist: Bool,
        retryDelays: [UInt64] = [0, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000],
        fetchPlaylists: @escaping @Sendable () async throws -> [PlexPlaylist],
        clearPlaylistItems: @escaping @Sendable (String) async throws -> Void,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> PlexPlaylist? {
        for delay in retryDelays {
            if delay > 0 { try await sleep(delay) }
            let playlists: [PlexPlaylist]
            do {
                playlists = try await fetchPlaylists()
            } catch {
                if PlexErrorClassification.classify(error) == .cancelled { throw error }
                continue
            }
            guard let playlist = playlists.first(where: {
                $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) else { continue }
            if seededEmptyPlaylist {
                try await clearPlaylistItems(playlist.ratingKey)
            }
            return playlist
        }
        if seededEmptyPlaylist { throw PlexAPIError.invalidResponse }
        return nil
    }

    /// Adds source-compatible tracks to a Plex playlist.
    public func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
        guard !tracks.isEmpty else { return 0 }
        // A previous append may have succeeded even when its acknowledgment was lost.
        // Read server membership, never the optimistic local cache, before replaying.
        var present = Set(try await apiClient.getPlaylistTracks(playlistKey: playlistID).map(\.ratingKey))
        let missing = tracks.filter { present.insert($0.id).inserted }
        guard !missing.isEmpty else { return 0 }
        try await apiClient.addItemsToPlaylist(
            playlistId: playlistID,
            trackRatingKeys: missing.map(\.id),
            serverIdentifier: sourceIdentifier.serverId
        )
        return missing.count
    }

    /// Renames a Plex playlist.
    public func renamePlaylist(_ playlistID: String, title: String) async throws {
        try await apiClient.renamePlaylist(playlistId: playlistID, newTitle: title)
    }

    /// Deletes a Plex playlist, treating an absent or inaccessible playlist as converged.
    public func deletePlaylist(_ playlistID: String) async throws {
        do {
            try await apiClient.deletePlaylist(playlistId: playlistID)
        } catch where Self.isConvergedPlaylistDeleteError(error) {
            EnsembleLogger.debug("Playlist \(playlistID) already absent or inaccessible; converging local deletion")
        }
    }

    /// Replaces all Plex playlist memberships while preserving the requested order.
    public func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
        let currentItems = try await apiClient.getPlaylistTracks(playlistKey: playlistID)
        let playlistItemIDs = currentItems.compactMap(\.playlistItemID)
        if playlistItemIDs.count == currentItems.count {
            for playlistItemID in playlistItemIDs {
                try await apiClient.removePlaylistItem(
                    playlistId: playlistID,
                    playlistItemId: playlistItemID
                )
            }
        } else {
            EnsembleLogger.debug("Playlist \(playlistID) has items without playlistItemID; falling back to bulk clear")
            try await apiClient.clearPlaylistItems(playlistId: playlistID)
        }
        if !tracks.isEmpty {
            try await apiClient.addItemsToPlaylist(
                playlistId: playlistID,
                trackRatingKeys: tracks.map(\.id),
                serverIdentifier: sourceIdentifier.serverId
            )
        }
    }

    /// Applies removals and moves through Plex's stable playlist membership IDs.
    public func editPlaylistItems(
        _ playlistID: String,
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) async throws {
        for operation in try Self.playlistEditOperations(
            originalItems: originalItems,
            editedItems: editedItems
        ) {
            switch operation {
            case .remove(let itemID):
                try await apiClient.removePlaylistItem(
                    playlistId: playlistID,
                    playlistItemId: itemID
                )
            case .move(let itemID, let afterItemID):
                try await apiClient.movePlaylistItem(
                    playlistId: playlistID,
                    playlistItemId: itemID,
                    afterItemId: afterItemID
                )
            }
        }
    }

    private func playlistSeedTrackID() async -> String? {
        for sectionKey in enabledSectionKeys {
            if let inventory = try? await apiClient.getTrackInventory(sectionKey: sectionKey),
               let trackID = inventory.first?.ratingKey {
                return trackID
            }
        }
        return nil
    }

    public func getRecommendedTracks(basedOn track: Track, limit: Int) async -> [Track]? {
        await PlexRadioProvider(
            sourceKey: sourceIdentifier.compositeKey,
            apiClient: apiClient,
            sectionKey: sectionKey
        ).getRecommendedTracks(basedOn: track, limit: limit)
    }

    public func getHomeHubs(limit: Int) async throws -> [Hub] {
        let sourceKey = sourceIdentifier.compositeKey
        return try await apiClient.getHubs(sectionKey: sectionKey, count: String(limit)).compactMap { plexHub in
            let items = (plexHub.metadata ?? [])
                .filter { metadata in
                    let type = metadata.type?.lowercased() ?? ""
                    return type.isEmpty || ["track", "album", "artist", "playlist", "music", "audio"].contains(type)
                }
                .map { HubItem(from: $0, sourceKey: sourceKey) }
            guard !items.isEmpty else { return nil }
            let semanticKind = HubSemanticKind.provider(
                identifier: plexHub.id,
                title: plexHub.title,
                context: plexHub.context
            )
            return Hub(
                id: "\(sourceKey):\(plexHub.id)",
                title: semanticKind.displayTitle(fallback: plexHub.title),
                type: plexHub.type ?? "mixed",
                items: items,
                context: plexHub.context,
                semanticKind: semanticKind,
                sourceScope: HubSourceScope(source: sourceIdentifier)
            )
        }
    }

    // MARK: - Library fetch

    /// Fetches the whole library, or only what changed since `plan.since`, plus the
    /// complete inventory when one is due. Reads and returns values; the writer
    /// decides what to store and delete.
    public func fetchLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch {
        if let since = plan.since { return try await fetchChangedLibrary(plan: plan, since: since) }
        return try await fetchFullLibrary(plan: plan)
    }

    /// A list read once, or twice when the first read would remove cached keys.
    struct Confirmed<Item> {
        /// The latest read: what every non-deletion step uses.
        let items: [Item]
        /// The latest read plus rows only the first read listed. Deletion uses this, so a row
        /// must be absent from both reads to be removed.
        let all: [Item]
    }

    private func confirmed<Item, Stored>(
        _ first: [Item],
        storedKeys: Dictionary<String, Stored>.Keys,
        key: (Item) -> String,
        what: String,
        reread: () async throws -> [Item]
    ) async throws -> Confirmed<Item> {
        guard !Set(storedKeys).isSubset(of: first.map(key)) else { return Confirmed(items: first, all: first) }
        EnsembleLogger.debug("🔄 Confirming Plex \(what) inventory before orphan removal")
        let second = try await reread()
        let secondKeys = Set(second.map(key))
        return Confirmed(items: second, all: second + first.filter { !secondKeys.contains(key($0)) })
    }

    private func fetchFullLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch {
        let queryStartedAt = Date()
        let stored = plan.stored
        EnsembleLogger.debug("🔄 Full library fetch starting for \(sourceIdentifier.compositeKey)")

        let artists = try await confirmed(
            try await apiClient.getArtists(sectionKey: sectionKey),
            storedKeys: stored.artists.keys, key: \.ratingKey, what: "artist"
        ) { try await apiClient.getArtists(sectionKey: sectionKey) }
        let albums = try await confirmed(
            try await apiClient.getAlbums(sectionKey: sectionKey),
            storedKeys: stored.albums.keys, key: \.ratingKey, what: "album"
        ) { try await apiClient.getAlbums(sectionKey: sectionKey) }
        let tracks = try await confirmed(
            try await apiClient.getTracks(sectionKey: sectionKey),
            storedKeys: stored.tracks.keys, key: \.ratingKey, what: "track"
        ) { try await apiClient.getTracks(sectionKey: sectionKey) }
        let genres = try await apiClient.getGenres(sectionKey: sectionKey)

        let inventory = try LibraryInventory(
            artistIDs: artists.all.map(\.ratingKey),
            albumIDs: albums.all.map(\.ratingKey),
            tracks: tracks.all.map { ($0.ratingKey, $0.parentRatingKey) },
            genreIDs: genres.compactMap(\.ratingKey)
        )
        let complete = await completeInputs(albums: albums.items, tracks: tracks.items, counts: inventory.trackCounts)
        return LibraryBatch(
            artists: artists.items.map(Self.artistUpsertInput),
            albums: complete.albums,
            tracks: complete.tracks,
            genres: genres.map { GenreUpsertInput(ratingKey: $0.ratingKey, key: $0.key, title: $0.title) },
            inventory: inventory,
            isFullMetadataPass: true,
            queryStartedAt: queryStartedAt
        )
    }

    /// Inputs for a complete album and track fetch: track counts from the inventory, and
    /// tracks copying their album's genres, since Plex returns genres only on albums.
    private func completeInputs(
        albums: [PlexAlbum],
        tracks: [PlexTrack],
        counts: [String: Int]
    ) async -> (albums: [AlbumUpsertInput], tracks: [TrackUpsertInput]) {
        let releaseFormats = await libraryAlbumReleaseFormats()
        let albumInputs = albums.map {
            Self.albumUpsertInput(
                from: $0,
                trackCount: counts[$0.ratingKey],
                releaseFormat: releaseFormats?[$0.ratingKey],
                updatesReleaseFormat: releaseFormats != nil
            )
        }
        let albumGenres = Self.genresByAlbum(albumInputs)
        return (albumInputs, tracks.map { Self.trackUpsertInput(from: $0, genreNames: $0.parentRatingKey.flatMap { albumGenres[$0] }) })
    }

    private func fetchChangedLibrary(plan: LibrarySyncPlan, since: Date) async throws -> LibraryBatch {
        let queryStartedAt = Date()
        let stored = plan.stored
        let timestamp = since.timeIntervalSince1970
        EnsembleLogger.debug("🔄 Incremental fetch for \(sourceIdentifier.compositeKey) since \(since)")

        // Plex can change artist fields without advancing artist or section timestamps,
        // so the small artist catalog is compared directly beside the item-level queries.
        let artists = try await confirmed(
            try await apiClient.getArtists(sectionKey: sectionKey),
            storedKeys: stored.artists.keys, key: \.ratingKey, what: "artist"
        ) { try await apiClient.getArtists(sectionKey: sectionKey) }
        let artistInputs = artists.items.map(Self.artistUpsertInput)

        let albumChanges = Self.deduplicatedChangedItems(
            added: try await apiClient.getAlbums(sectionKey: sectionKey, addedAfter: timestamp),
            updated: try await apiClient.getAlbums(sectionKey: sectionKey, updatedAfter: timestamp),
            existingTimestamps: stored.albums.mapValues { $0.dateModified ?? .distantPast },
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )
        let releaseFormats = albumChanges.changedItems.isEmpty ? nil : await libraryAlbumReleaseFormats()
        let albumInputs = albumChanges.changedItems.map {
            Self.albumUpsertInput(from: $0, releaseFormat: releaseFormats?[$0.ratingKey], updatesReleaseFormat: releaseFormats != nil)
        }
        // A track's genre is its album's: a changed album's own, otherwise the stored album's.
        var albumGenres = stored.albums.compactMapValues(\.genreNames)
        for album in albumInputs { albumGenres[album.ratingKey] = album.genreNames }

        // Rating changes made on other clients are caught by the next full metadata pass:
        // the ratedAfter filter returns every rated track whatever the date, which costs
        // about 1 MB and 3 seconds per cycle for nothing.
        let trackChanges = Self.deduplicatedChangedItems(
            added: try await apiClient.getTracks(sectionKey: sectionKey, addedAfter: timestamp),
            updated: try await apiClient.getTracks(sectionKey: sectionKey, updatedAfter: timestamp),
            existingTimestamps: stored.tracks.mapValues(\.dateModified),
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt },
            hasAdditionalChange: { track in
                stored.tracks[track.ratingKey].map { $0.rating != Int16(track.userRating.map { Int($0) } ?? 0) } ?? false
            }
        )
        let trackInputs = trackChanges.changedItems.map {
            Self.trackUpsertInput(from: $0, genreNames: $0.parentRatingKey.flatMap { albumGenres[$0] })
        }

        var batch = LibraryBatch(artists: artistInputs, albums: albumInputs, tracks: trackInputs, queryStartedAt: queryStartedAt)
        let changedCount = artistInputs.filter { stored.artists[$0.ratingKey]?.matches($0) != true }.count
            + albumInputs.count + trackInputs.count
        guard changedCount > 0 || plan.inventoryDue || plan.fullMetadataDue else { return batch }

        // Delete only from a complete inventory: after a change, or once a day.
        if plan.fullMetadataDue {
            async let allAlbums = apiClient.getAlbums(sectionKey: sectionKey)
            async let allTracks = apiClient.getTracks(sectionKey: sectionKey)
            let albums = try await confirmed(
                try await allAlbums, storedKeys: stored.albums.keys, key: \.ratingKey, what: "album"
            ) { try await apiClient.getAlbums(sectionKey: sectionKey) }
            let tracks = try await confirmed(
                try await allTracks, storedKeys: stored.tracks.keys, key: \.ratingKey, what: "track"
            ) { try await apiClient.getTracks(sectionKey: sectionKey) }
            let inventory = try LibraryInventory(
                artistIDs: artists.all.map(\.ratingKey),
                albumIDs: albums.all.map(\.ratingKey),
                tracks: tracks.all.map { ($0.ratingKey, $0.parentRatingKey) }
            )
            let complete = await completeInputs(albums: albums.items, tracks: tracks.items, counts: inventory.trackCounts)
            batch.albums = complete.albums
            batch.tracks = complete.tracks
            batch.inventory = inventory
            batch.isFullMetadataPass = true
        } else {
            let albums = try await confirmed(
                try await apiClient.getAlbumInventory(sectionKey: sectionKey),
                storedKeys: stored.albums.keys, key: \.ratingKey, what: "album"
            ) { try await apiClient.getAlbumInventory(sectionKey: sectionKey) }
            let tracks = try await confirmed(
                try await apiClient.getTrackInventory(sectionKey: sectionKey),
                storedKeys: stored.tracks.keys, key: \.ratingKey, what: "track"
            ) { try await apiClient.getTrackInventory(sectionKey: sectionKey) }
            let inventory = try LibraryInventory(
                artistIDs: artists.all.map(\.ratingKey),
                albumIDs: albums.all.map(\.ratingKey),
                tracks: tracks.all.map { ($0.ratingKey, $0.parentRatingKey) }
            )
            let repaired = try await membershipRepairs(
                inventory: inventory, tracks: tracks.all, plan: plan, fetchedAlbums: albumInputs, fetchedTracks: trackInputs,
                albumGenres: albumGenres
            )
            batch.albums += repaired.albums
            batch.tracks += repaired.tracks
            batch.inventory = inventory
        }
        EnsembleLogger.info(
            "Plex membership reconciliation tracks=\(batch.inventory?.trackParents.count ?? 0) albums=\(batch.inventory?.albumIDs.count ?? 0) fullMetadata=\(batch.isFullMetadataPass)"
        )
        return batch
    }

    /// Fetches the albums and tracks the inventory shows missing from the store or under
    /// another album, so the writer can repair them before it deletes.
    private func membershipRepairs(
        inventory: LibraryInventory,
        tracks: [PlexInventoryItem],
        plan: LibrarySyncPlan,
        fetchedAlbums: [AlbumUpsertInput],
        fetchedTracks: [TrackUpsertInput],
        albumGenres: [String: String]
    ) async throws -> (albums: [AlbumUpsertInput], tracks: [TrackUpsertInput]) {
        let counts = inventory.trackCounts
        let knownAlbums = Set(plan.stored.albums.keys).union(fetchedAlbums.map(\.ratingKey))
        var albumInputs: [AlbumUpsertInput] = []
        var genres = albumGenres
        for key in Set(counts.keys).subtracting(knownAlbums).sorted() {
            try RefreshExecution.checkCancellation()
            guard let album = try await apiClient.getAlbum(albumKey: key), album.ratingKey == key else {
                throw PlexAPIError.invalidResponse
            }
            let input = Self.albumUpsertInput(from: album, trackCount: counts[key])
            albumInputs.append(input)
            genres[key] = input.genreNames
        }
        // The inventory wins: a track needs repair unless the album it will have after this
        // batch (the delta's, else the stored one) is the album the inventory lists. A delta
        // fetched before Plex moved the track would otherwise keep the old album.
        let fetchedParents = Dictionary(fetchedTracks.map { ($0.ratingKey, $0.albumRatingKey) }) { $1 }
        let repairs = tracks.filter {
            let parentAfterBatch = fetchedParents.keys.contains($0.ratingKey)
                ? fetchedParents[$0.ratingKey] ?? nil
                : plan.stored.tracks[$0.ratingKey]?.albumRatingKey
            return parentAfterBatch != $0.parentRatingKey
        }
        var trackInputs: [TrackUpsertInput] = []
        for start in stride(from: 0, to: repairs.count, by: 500) {
            try RefreshExecution.checkCancellation()
            let batch = Array(repairs[start..<min(start + 500, repairs.count)])
            let expectedParents = Dictionary(uniqueKeysWithValues: batch.map { ($0.ratingKey, $0.parentRatingKey) })
            let fetched = try await apiClient.getTracks(ratingKeys: batch.map(\.ratingKey))
            guard fetched.count == batch.count,
                  Set(fetched.map(\.ratingKey)) == Set(expectedParents.keys),
                  fetched.allSatisfy({ $0.parentRatingKey == expectedParents[$0.ratingKey] ?? nil }) else {
                throw PlexAPIError.invalidResponse
            }
            trackInputs += fetched.map { Self.trackUpsertInput(from: $0, genreNames: $0.parentRatingKey.flatMap { genres[$0] }) }
        }
        return (albumInputs, trackInputs)
    }

    private static func genresByAlbum(_ albums: [AlbumUpsertInput]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: albums.compactMap { album in album.genreNames.map { (album.ratingKey, $0) } })
    }

    // MARK: - Live changes

    /// Fetches what a WebSocket notice names, plus the albums and artists above it.
    /// Deletion hints fetch nothing; the caller marks the inventory due for them.
    public func fetchChanges(_ hints: Set<LibraryChangeHint>) async throws -> LibraryBatch {
        let queryStartedAt = Date()
        let actionable = hints.filter { !$0.isDeleted }
        guard !actionable.isEmpty else { return LibraryBatch(queryStartedAt: queryStartedAt) }

        func ids(_ kind: LibraryChangeHint.Kind) -> Set<String> { Set(actionable.filter { $0.kind == kind }.map(\.itemID)) }
        var artistsByKey: [String: PlexArtist] = [:]
        var albumsByKey: [String: PlexAlbum] = [:]
        var tracksByKey: [String: PlexTrack] = [:]

        for artistKey in ids(.artist).sorted() {
            if let artist = try await apiClient.getArtist(artistKey: artistKey) {
                artistsByKey[artist.ratingKey] = artist
            }
            for album in try await apiClient.getArtistAlbums(artistKey: artistKey) { albumsByKey[album.ratingKey] = album }
            for track in try await apiClient.getArtistTracks(artistKey: artistKey) { tracksByKey[track.ratingKey] = track }
        }
        for albumKey in ids(.album).sorted() {
            if let album = try await apiClient.getAlbum(albumKey: albumKey) { albumsByKey[album.ratingKey] = album }
            for track in try await apiClient.getAlbumTracks(albumKey: albumKey) { tracksByKey[track.ratingKey] = track }
        }
        let trackKeys = ids(.track)
        if !trackKeys.isEmpty {
            for track in try await apiClient.getTracks(ratingKeys: trackKeys.sorted()) { tracksByKey[track.ratingKey] = track }
        }
        for albumKey in Set(tracksByKey.values.compactMap(\.parentRatingKey)).subtracting(albumsByKey.keys).sorted() {
            if let album = try await apiClient.getAlbum(albumKey: albumKey) { albumsByKey[album.ratingKey] = album }
        }
        for artistKey in Set(albumsByKey.values.compactMap(\.parentRatingKey)).subtracting(artistsByKey.keys).sorted() {
            if let artist = try await apiClient.getArtist(artistKey: artistKey) { artistsByKey[artist.ratingKey] = artist }
        }

        let albumInputs = albumsByKey.values.map { Self.albumUpsertInput(from: $0) }
        let albumGenres = Self.genresByAlbum(albumInputs)
        return LibraryBatch(
            artists: artistsByKey.values.map(Self.artistUpsertInput),
            albums: albumInputs,
            tracks: tracksByKey.values.map { Self.trackUpsertInput(from: $0, genreNames: $0.parentRatingKey.flatMap { albumGenres[$0] }) },
            queryStartedAt: queryStartedAt
        )
    }

    struct IncrementalChangeSet<Item> {
        let uniqueItems: [Item]
        let changedItems: [Item]
    }

    static func deduplicatedChangedItems<Item>(
        added: [Item],
        updated: [Item],
        existingTimestamps: [String: Date],
        ratingKey: (Item) -> String,
        updatedAt: (Item) -> Int?,
        hasAdditionalChange: (Item) -> Bool = { _ in false }
    ) -> IncrementalChangeSet<Item> {
        var itemsByRatingKey: [String: Item] = [:]
        for item in added {
            itemsByRatingKey[ratingKey(item)] = item
        }
        for item in updated {
            itemsByRatingKey[ratingKey(item)] = item
        }

        let uniqueItems = Array(itemsByRatingKey.values)
        let changedItems = uniqueItems.filter { item in
            if hasAdditionalChange(item) {
                return true
            }

            let key = ratingKey(item)
            guard let serverUpdated = updatedAt(item) else {
                return existingTimestamps[key] == nil
            }
            guard let localDate = existingTimestamps[key] else {
                return true
            }
            return serverUpdated != Int(localDate.timeIntervalSince1970)
        }

        return IncrementalChangeSet(uniqueItems: uniqueItems, changedItems: changedItems)
    }

    private static func artistUpsertInput(from artist: PlexArtist) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: artist.ratingKey,
            key: artist.key,
            name: artist.title,
            summary: artist.summary,
            thumbPath: artist.thumb,
            artPath: artist.art,
            dateAdded: artist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: artist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    static func albumUpsertInput(
        from album: PlexAlbum,
        trackCount: Int? = nil,
        releaseFormat: AlbumReleaseFormat? = nil,
        updatesReleaseFormat: Bool = false
    ) -> AlbumUpsertInput {
        AlbumUpsertInput(
            ratingKey: album.ratingKey,
            key: album.key,
            title: album.title,
            artistName: album.parentTitle,
            albumArtist: album.parentTitle,
            artistRatingKey: album.parentRatingKey,
            summary: album.summary,
            thumbPath: album.thumb,
            artPath: album.art,
            year: album.year,
            trackCount: trackCount ?? album.leafCount,
            dateAdded: album.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: album.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastRatedAt: album.lastRatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: Int(album.userRating ?? 0),
            genreNames: album.genreNames.isEmpty ? nil : album.genreNames.joined(separator: ", "),
            releaseFormat: releaseFormat?.rawValue,
            updatesReleaseFormat: updatesReleaseFormat
        )
    }

    static func trackUpsertInput(from track: PlexTrack, genreNames: String?) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: track.ratingKey,
            key: track.key,
            title: track.title,
            artistName: track.originalTitle ?? track.grandparentTitle,  // Prefer track artist over album artist
            albumName: track.parentTitle,
            albumRatingKey: track.parentRatingKey,
            trackNumber: track.index,
            discNumber: track.parentIndex,
            duration: track.duration,
            thumbPath: track.thumb ?? track.parentThumb,
            streamKey: track.streamURL,
            streamId: track.audioStreamId,
            dateAdded: track.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: track.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: track.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastRatedAt: track.lastRatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: track.userRating.map { Int($0) } ?? 0,
            playCount: track.viewCount ?? 0,
            genreNames: genreNames
        )
    }
    
    // MARK: - Playlist fetch

    /// Reads the server's whole audio-playlist list: one request that returns every header, so a
    /// pass needs no change queries. Plex playlists belong to the server, not to a library section.
    public func fetchPlaylistHeaders() async throws -> PlaylistHeaderList {
        let queryStartedAt = Date()
        let list = try await apiClient.getPlaylistList()
        let headers = list.playlists.map(Self.playlistUpsertInput)
        var inventory: PlaylistInventory?
        if list.isComplete {
            inventory = try? PlaylistInventory(playlistIDs: headers.map(\.ratingKey))
        }
        if inventory == nil { EnsembleLogger.info("Plex playlist list for \(sourceIdentifier.compositeKey) is not proven complete; nothing will be deleted from it") }
        return PlaylistHeaderList(headers: headers, inventory: inventory, queryStartedAt: queryStartedAt)
    }

    /// Reads each playlist's items, which the client accepts only when the container's size and total
    /// match the items received (an empty playlist is a complete, empty read). A failed read leaves that
    /// playlist out, so its stored body stays and the next pass reads it again.
    public func fetchPlaylistBodies(for headers: [PlaylistUpsertInput]) async throws -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        for header in headers {
            try RefreshExecution.checkCancellation()
            do {
                let tracks = try await apiClient.getPlaylistTracks(playlistKey: header.ratingKey)
                entries.append(PlaylistEntry(header: header, body: tracks.map(Self.playlistTrackSnapshot)))
            } catch {
                try RefreshExecution.checkCancellation()
                EnsembleLogger.error("Plex playlist \(header.ratingKey) body unavailable, keeping the stored one: \(error.localizedDescription)")
            }
        }
        return entries
    }

    static func playlistTrackSnapshot(_ track: PlexTrack) -> PlaylistTrackSnapshot {
        PlaylistTrackSnapshot(
            ratingKey: track.ratingKey,
            playlistItemID: track.playlistItemID,
            key: track.key,
            title: track.title,
            artistName: track.originalTitle ?? track.grandparentTitle,
            albumName: track.parentTitle,
            duration: track.durationSeconds,
            thumbPath: track.thumb ?? track.parentThumb ?? track.grandparentThumb,
            librarySectionID: track.librarySectionID.map(String.init)
        )
    }

    static func playlistUpsertInput(_ playlist: PlexPlaylist) -> PlaylistUpsertInput {
        let isSmart = playlist.smart ?? false
        return PlaylistUpsertInput(
            ratingKey: playlist.ratingKey,
            key: playlist.key,
            title: playlist.title,
            summary: playlist.summary,
            compositePath: playlist.composite,
            isSmart: isSmart,
            duration: playlist.duration,
            trackCount: playlist.leafCount,
            dateAdded: playlist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: playlist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: playlist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastRatedAt: playlist.lastRatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: Int(playlist.userRating ?? 0),
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: !isSmart,
                canRename: !isSmart,
                canReorder: !isSmart,
                canDelete: !isSmart,
                unavailableReason: isSmart ? "Smart playlists are read-only." : nil
            )
        )
    }

public func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double? = nil
    ) async throws -> StreamResolution {
        EnsembleLogger.debug("🎵 PlexProvider.getStreamURL: ratingKey=\(trackRatingKey), quality=\(quality.rawValue)")

        // Try smart routing: direct stream for compatible tracks, progressive transcode
        // for transcodes. Direct stream gives instant playback (~<1s) because PMS serves
        // direct files with Accept-Ranges: bytes and Content-Length. Progressive transcode
        // gives ~1-2s startup by streaming chunks via AVAssetResourceLoaderDelegate.
        do {
            let resolution = try await apiClient.resolveStreamURL(
                ratingKey: trackRatingKey,
                trackStreamKey: trackStreamKey,
                quality: quality,
                metadataDurationSeconds: metadataDurationSeconds
            )
            switch resolution {
            case .directStream:
                EnsembleLogger.debug("🎵 PlexProvider: Using direct stream (quality=\(quality.rawValue))")
            case .downloadedFile:
                EnsembleLogger.debug("🎵 PlexProvider: Downloaded transcode to file (quality=\(quality.rawValue))")
            case .progressiveTranscode:
                EnsembleLogger.debug("🎵 PlexProvider: Progressive transcode (quality=\(quality.rawValue))")
            }
            return resolution
        } catch {
            EnsembleLogger.debug("⚠️ PlexProvider: resolveStreamURL failed: \(error). Falling back to direct stream.")
        }

        // Last resort fallback: direct file URL (always original quality)
        if let trackStreamKey, !trackStreamKey.isEmpty {
            EnsembleLogger.debug("🔍 PlexProvider: Last resort — using direct stream key: \(trackStreamKey)")
            let url = try await apiClient.getStreamURL(trackKey: trackStreamKey)
            return .directStream(url)
        }

        EnsembleLogger.debug("⚠️ PlexProvider: Fallback fetching track metadata for stream key")
        guard let track = try await apiClient.getTrack(trackKey: trackRatingKey),
              let streamKey = track.streamURL else {
            EnsembleLogger.debug("❌ PlexProvider: Could not get stream URL from track metadata")
            throw PlexAPIError.invalidURL
        }
        let url = try await apiClient.getStreamURL(trackKey: streamKey)
        return .directStream(url)
    }

    // MARK: - Two-Phase Stream Resolution

    /// Phase 1: Make a streaming decision without embedding the server endpoint URL.
    /// Applies the same direct/progressive routing as `getStreamURL()`.
    /// The returned decision can be cached across network transitions.
    public func makeStreamDecision(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double? = nil,
        startTime: TimeInterval = 0,
        forceTranscode: Bool = false
    ) async throws -> StreamDecision {
        EnsembleLogger.debug("[PlexProvider] makeStreamDecision: ratingKey=\(trackRatingKey), quality=\(quality.rawValue), forceTranscode=\(forceTranscode)")

        let decision = try await apiClient.makeStreamDecision(
            ratingKey: trackRatingKey,
            trackStreamKey: trackStreamKey,
            quality: quality,
            metadataDurationSeconds: metadataDurationSeconds,
            startTime: startTime,
            forceTranscode: forceTranscode
        )
        switch decision {
        case .directStream:
            EnsembleLogger.debug("[PlexProvider] Decision: directStream (quality=\(quality.rawValue))")
        case .progressiveTranscode:
            EnsembleLogger.debug("[PlexProvider] Decision: progressiveTranscode (quality=\(quality.rawValue))")
        }
        return decision
    }

    /// Phase 2: Assemble a StreamResolution from a cached StreamDecision.
    /// Uses the canonical client's current endpoint and credentials.
    public func assembleStreamResolution(from decision: StreamDecision) async throws -> StreamResolution {
        return try await apiClient.assembleStreamResolution(from: decision)
    }

    /// Get a download URL for offline use. Skips the transcode decision endpoint
    /// since URLSession downloads don't need session warmup.
    /// Falls back to the direct file URL if universal URL construction fails.
    public func getDownloadURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality
    ) async throws -> URL {
        // Original downloads use the stable file resource, which can support validated ranges.
        // Universal transcodes remain available for quality conversion and missing file keys.
        if quality == .original {
            let streamKey: String?
            if let trackStreamKey, !trackStreamKey.isEmpty {
                streamKey = trackStreamKey
            } else {
                streamKey = try await apiClient.getTrack(trackKey: trackRatingKey)?.streamURL
            }
            if let streamKey, !streamKey.isEmpty {
                return try await apiClient.getStreamURL(trackKey: streamKey, download: true)
            }
        }

        // Try the universal download URL (no decision call)
        do {
            let url = try await apiClient.getUniversalDownloadURL(
                ratingKey: trackRatingKey,
                quality: quality
            )
            EnsembleLogger.debug("🎵 PlexProvider: Using universal download URL (quality=\(quality.rawValue))")
            return url
        } catch {
            EnsembleLogger.debug("⚠️ PlexProvider: Universal download URL failed: \(error). Falling back to direct stream.")
        }

        // Fallback: direct file URL (always original quality)
        if let trackStreamKey, !trackStreamKey.isEmpty {
            return try await apiClient.getStreamURL(trackKey: trackStreamKey, download: true)
        }

        // Last resort: fetch track metadata for stream key
        guard let track = try await apiClient.getTrack(trackKey: trackRatingKey),
              let streamKey = track.streamURL else {
            throw PlexAPIError.invalidURL
        }
        return try await apiClient.getStreamURL(trackKey: streamKey, download: true)
    }

    public func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        try await apiClient.getArtworkURL(path: path, size: size)
    }

    public func rateTrack(
        _ track: Track,
        rating: Int?
    ) async throws -> MusicSourceRatingMutationEffects {
        try await apiClient.rateItem(ratingKey: track.id, rating: rating)
        return .refreshPlaylistsAndFavoriteDownloads
    }

    public func rateCollection(ratingKey: String, rating: Int?) async throws {
        try await apiClient.rateItem(ratingKey: ratingKey, rating: rating)
    }

    public func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {
        try await apiClient.reportTimeline(ratingKey: ratingKey, key: key, state: state, time: time, duration: duration)
    }

    public func scrobble(ratingKey: String) async throws {
        try await apiClient.scrobble(ratingKey: ratingKey)
    }

    public func getAudioFileInfo(trackID: String) async throws -> AudioFileInfo? {
        guard let track = try await apiClient.getTrack(trackKey: trackID) else { return nil }
        return AudioFileInfo(from: track)
    }

    public func getAlbumFolderPath(albumID: String) async throws -> String? {
        let tracks = try await apiClient.getAlbumTracks(albumKey: albumID)
        let paths = tracks.compactMap { $0.media?.first?.part?.first?.file }
        return Self.albumFolderPath(from: paths)
    }

    static func albumFolderPath(from filePaths: [String]) -> String? {
        var seen = Set<String>()
        let directoryComponents = filePaths
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().pathComponents }
        guard var commonComponents = directoryComponents.first else { return nil }

        for components in directoryComponents.dropFirst() {
            commonComponents = Array(
                zip(commonComponents, components)
                    .prefix { $0 == $1 }
                    .map(\.0)
            )
            if commonComponents.isEmpty { return nil }
        }

        return NSString.path(withComponents: commonComponents)
    }

    public func getLyricsMetadata(trackID: String) async throws -> MusicSourceLyricsMetadata? {
        guard let track = try await apiClient.getTrack(trackKey: trackID) else { return nil }
        return MusicSourceLyricsMetadata(
            title: track.title,
            dateModified: track.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            normalAssets: track.normalLyricsStreams.compactMap(Self.lyricsAsset),
            chordCandidateAssets: track.chordCandidateStreams.compactMap(Self.lyricsAsset)
        )
    }

    public func getLyricsContent(asset: MusicSourceLyricsAsset, raw: Bool) async throws -> String? {
        if raw || asset.isLocalMedia {
            return try await apiClient.getRawLyricsContent(streamKey: asset.key)
        }
        return try await apiClient.getLyricsContent(streamKey: asset.key)
    }

    private static func lyricsAsset(_ stream: PlexStream) -> MusicSourceLyricsAsset? {
        guard let key = stream.key else { return nil }
        return MusicSourceLyricsAsset(
            id: String(stream.id),
            key: key,
            codec: stream.codec,
            format: stream.format,
            provider: stream.provider,
            file: stream.file,
            isTimed: stream.timed == 1,
            isLocalMedia: stream.isLocalMediaLyricsStream
        )
    }

    public func getAlbumTracks(albumKey: String) async throws -> [Track] {
        let plexTracks = try await apiClient.getAlbumTracks(albumKey: albumKey)
        return plexTracks.map { Track(from: $0, sourceKey: sourceIdentifier.compositeKey) }
    }

    public func getArtistAlbums(artistKey: String) async throws -> [Album] {
        let childAlbums = try await apiClient.getArtistAlbums(artistKey: artistKey)
        guard let artistTitle = childAlbums.first?.parentTitle, !artistTitle.isEmpty else {
            return childAlbums.map { Album(from: $0, sourceKey: sourceIdentifier.compositeKey) }
        }

        do {
            let sectionAlbums = try await apiClient.getArtistAlbums(sectionKey: sectionKey, artistTitle: artistTitle)
            if sectionAlbums.count >= childAlbums.count {
                let releaseFormats: [String: AlbumReleaseFormat]
                do {
                    releaseFormats = try await artistAlbumReleaseFormats(artistTitle: artistTitle)
                } catch {
                    EnsembleLogger.debug("PlexConnector: Album format query failed for \(artistKey): \(error.localizedDescription)")
                    releaseFormats = [:]
                }
                return sectionAlbums.map {
                    Album(
                        from: $0,
                        sourceKey: sourceIdentifier.compositeKey,
                        releaseFormat: releaseFormats[$0.ratingKey]
                    )
                }
            }
        } catch {
            EnsembleLogger.debug("PlexConnector: Section artist album query failed for \(artistKey): \(error.localizedDescription)")
        }

        return childAlbums.map { Album(from: $0, sourceKey: sourceIdentifier.compositeKey) }
    }

    private func artistAlbumReleaseFormats(artistTitle: String) async throws -> [String: AlbumReleaseFormat] {
        try await albumReleaseFormats(artistTitle: artistTitle)
    }

    private func libraryAlbumReleaseFormats() async -> [String: AlbumReleaseFormat]? {
        do {
            return try await albumReleaseFormats()
        } catch {
            EnsembleLogger.debug("PlexConnector: Library album format query failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func albumReleaseFormats(artistTitle: String? = nil) async throws -> [String: AlbumReleaseFormat] {
        let formatFilters = try await apiClient.getAlbumFormatFilters(sectionKey: sectionKey)
        var formatsByRatingKey: [String: AlbumReleaseFormat] = [:]

        for filter in formatFilters {
            guard let releaseFormat = AlbumReleaseFormat(plexTag: filter.title), releaseFormat != .album else { continue }
            let formattedAlbums: [PlexAlbum]
            if let artistTitle {
                formattedAlbums = try await apiClient.getArtistAlbums(
                    sectionKey: sectionKey,
                    artistTitle: artistTitle,
                    formatKey: filter.key
                )
            } else {
                formattedAlbums = try await apiClient.getAlbums(
                    sectionKey: sectionKey,
                    formatKey: filter.key
                )
            }
            for album in formattedAlbums {
                formatsByRatingKey[album.ratingKey] = releaseFormat
            }
        }

        return formatsByRatingKey
    }

    public func getArtistTracks(artistKey: String) async throws -> [Track] {
        let plexTracks = try await apiClient.getArtistTracks(artistKey: artistKey)
        return plexTracks.map { Track(from: $0, sourceKey: sourceIdentifier.compositeKey) }
    }

    public func getArtistDetail(artistKey: String) async throws -> ArtistDetail? {
        guard let plexDetail = try await apiClient.getArtistDetail(artistKey: artistKey) else {
            return nil
        }
        return ArtistDetail(from: plexDetail)
    }

    public func getAlbumDetail(albumKey: String) async throws -> AlbumDetail? {
        guard let plexDetail = try await apiClient.getAlbumDetail(albumKey: albumKey) else {
            return nil
        }
        return AlbumDetail(from: plexDetail)
    }

    public func getSimilarAlbums(albumKey: String) async throws -> [Album] {
        let plexAlbums = try await apiClient.getSimilarAlbums(albumKey: albumKey)
        return plexAlbums.map { Album(from: $0, sourceKey: sourceIdentifier.compositeKey) }
    }
}
