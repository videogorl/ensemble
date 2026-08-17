import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Syncs a single Plex server+library to CoreData
public final class PlexMusicSourceSyncProvider:
    MusicSourceSyncProvider,
    MusicSourceTwoPhasePlaybackResolving,
    MusicSourceRatingMutating,
    MusicSourcePlaylistMutating,
    MusicSourcePlaybackReporting,
    MusicSourceDetailProviding,
    MusicSourceFileInfoProviding,
    MusicSourceLyricsProviding,
    MusicSourceRadioProviding,
    @unchecked Sendable
{
    static let orphanCheckInterval: TimeInterval = 24 * 60 * 60

    public let sourceIdentifier: MusicSourceIdentifier
    private let apiClient: PlexAPIClient
    private let syncCursorRepository: SyncCursorRepositoryProtocol?
    private let enabledSectionKeys: [String]
    /// Library section key used for API calls. Internal for WebSocket-triggered sync matching.
    let sectionKey: String

    public init(
        sourceIdentifier: MusicSourceIdentifier,
        apiClient: PlexAPIClient,
        sectionKey: String,
        enabledSectionKeys: [String] = [],
        syncCursorRepository: SyncCursorRepositoryProtocol? = nil
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.apiClient = apiClient
        self.sectionKey = sectionKey
        self.enabledSectionKeys = Self.playlistSeedSectionKeys(
            primary: sectionKey,
            enabled: enabledSectionKeys
        )
        self.syncCursorRepository = syncCursorRepository
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
            guard let playlist = try? await fetchPlaylists().first(where: {
                $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) else { continue }
            if seededEmptyPlaylist {
                try? await clearPlaylistItems(playlist.ratingKey)
            }
            return playlist
        }
        return nil
    }

    /// Adds source-compatible tracks to a Plex playlist.
    public func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
        guard !tracks.isEmpty else { return 0 }
        try await apiClient.addItemsToPlaylist(
            playlistId: playlistID,
            trackRatingKeys: tracks.map(\.id),
            serverIdentifier: sourceIdentifier.serverId
        )
        return tracks.count
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

    func reconcileLibraryChanges(
        _ changes: Set<PlexLibraryChange>,
        to repository: LibraryRepositoryProtocol
    ) async throws -> LibrarySyncResult {
        let actionableChanges = changes.filter { !$0.isDeletion }
        guard !actionableChanges.isEmpty else { return LibrarySyncResult() }

        let sourceKey = sourceIdentifier.compositeKey
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: sourceIdentifier.type.rawValue,
            accountId: sourceIdentifier.accountId,
            serverId: sourceIdentifier.serverId,
            libraryId: sourceIdentifier.libraryId,
            displayName: nil,
            accountName: nil
        )

        let explicitArtistKeys = Set(actionableChanges.filter { $0.kind == .artist }.map(\.ratingKey))
        let explicitAlbumKeys = Set(actionableChanges.filter { $0.kind == .album }.map(\.ratingKey))
        let explicitTrackKeys = Set(actionableChanges.filter { $0.kind == .track }.map(\.ratingKey))

        var artistsByKey: [String: PlexArtist] = [:]
        var albumsByKey: [String: PlexAlbum] = [:]
        var tracksByKey: [String: PlexTrack] = [:]

        for artistKey in explicitArtistKeys.sorted() {
            if let artist = try await apiClient.getArtist(artistKey: artistKey) {
                artistsByKey[artist.ratingKey] = artist
            }
            for album in try await apiClient.getArtistAlbums(artistKey: artistKey) {
                albumsByKey[album.ratingKey] = album
            }
            for track in try await apiClient.getArtistTracks(artistKey: artistKey) {
                tracksByKey[track.ratingKey] = track
            }
        }

        for albumKey in explicitAlbumKeys.sorted() {
            if let album = try await apiClient.getAlbum(albumKey: albumKey) {
                albumsByKey[album.ratingKey] = album
            }
            for track in try await apiClient.getAlbumTracks(albumKey: albumKey) {
                tracksByKey[track.ratingKey] = track
            }
        }

        if !explicitTrackKeys.isEmpty {
            for track in try await apiClient.getTracks(ratingKeys: explicitTrackKeys.sorted()) {
                tracksByKey[track.ratingKey] = track
            }
        }

        let missingAlbumKeys = Set(tracksByKey.values.compactMap(\.parentRatingKey))
            .subtracting(albumsByKey.keys)
        for albumKey in missingAlbumKeys.sorted() {
            if let album = try await apiClient.getAlbum(albumKey: albumKey) {
                albumsByKey[album.ratingKey] = album
            }
        }

        let missingArtistKeys = Set(albumsByKey.values.compactMap(\.parentRatingKey))
            .subtracting(artistsByKey.keys)
        for artistKey in missingArtistKeys.sorted() {
            if let artist = try await apiClient.getArtist(artistKey: artistKey) {
                artistsByKey[artist.ratingKey] = artist
            }
        }

        let trackCounts = Self.trackCountsByAlbumRatingKey(Array(tracksByKey.values))
        let albumInputs = albumsByKey.values.map { album in
            Self.albumUpsertInput(
                from: album,
                trackCount: explicitAlbumKeys.contains(album.ratingKey)
                    ? trackCounts[album.ratingKey] ?? album.leafCount
                    : album.leafCount
            )
        }
        let albumGenres = Dictionary(uniqueKeysWithValues: albumInputs.compactMap { input in
            input.genreNames.map { (input.ratingKey, $0) }
        })
        let artistInputs = artistsByKey.values.map(Self.artistUpsertInput)
        let trackInputs = tracksByKey.values.map { track in
            Self.trackUpsertInput(
                from: track,
                genreNames: track.parentRatingKey.flatMap { albumGenres[$0] }
            )
        }

        async let existingArtists: [String: ArtistSyncMetadata] = artistInputs.isEmpty
            ? [:]
            : repository.fetchArtistSyncMetadata(
                forSource: sourceKey,
                ratingKeys: Set(artistInputs.map(\.ratingKey))
            )
        async let existingAlbums: [String: AlbumSyncMetadata] = albumInputs.isEmpty
            ? [:]
            : repository.fetchAlbumSyncMetadata(
                forSource: sourceKey,
                ratingKeys: Set(albumInputs.map(\.ratingKey))
            )
        async let existingTracks: [String: TrackSyncMetadata] = trackInputs.isEmpty
            ? [:]
            : repository.fetchTrackSyncMetadata(
                forSource: sourceKey,
                ratingKeys: Set(trackInputs.map(\.ratingKey))
            )
        let artistsToSync = Self.changedArtistInputs(
            artistInputs,
            existingMetadata: try await existingArtists
        )
        let albumsToSync = Self.changedAlbumInputs(
            albumInputs,
            existingMetadata: try await existingAlbums
        )
        let tracksToSync = Self.changedTrackInputs(
            trackInputs,
            existingMetadata: try await existingTracks
        )

        try await repository.batchUpsertArtists(artistsToSync, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums(albumsToSync, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks(tracksToSync, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug(
            "🔌 Targeted Plex reconciliation for \(sourceKey): artists=\(artistsToSync.count) albums=\(albumsToSync.count) tracks=\(tracksToSync.count)"
        )
        return LibrarySyncResult(
            changedArtists: artistsToSync.count,
            changedAlbums: albumsToSync.count,
            changedTracks: tracksToSync.count
        )
    }

    public func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let sourceKey = sourceIdentifier.compositeKey
        let queryStartedAt = Date()
        EnsembleLogger.debug("🔄 Incremental sync for \(sourceKey) since \(Date(timeIntervalSince1970: timestamp))")

        let syncStart = CFAbsoluteTimeGetCurrent()

        // Ensure CDMusicSource exists
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: sourceIdentifier.type.rawValue,
            accountId: sourceIdentifier.accountId,
            serverId: sourceIdentifier.serverId,
            libraryId: sourceIdentifier.libraryId,
            displayName: nil,
            accountName: nil
        )

        // Plex can change artist fields without advancing artist or section timestamps.
        // Compare the small artist catalog directly alongside item-level incremental queries.
        progressHandler(0.05)
        var phaseStart = CFAbsoluteTimeGetCurrent()
        async let existingArtistMetadataRequest = repository.fetchArtistSyncMetadata(forSource: sourceKey)
        var artists = try await apiClient.getArtists(sectionKey: sectionKey)
        let existingArtistMetadata = try await existingArtistMetadataRequest
        var artistRatingKeys = Set(artists.map(\.ratingKey))
        if !Set(existingArtistMetadata.keys).isSubset(of: artistRatingKeys) {
            EnsembleLogger.debug("🔄 Confirming Plex artist inventory before orphan removal")
            artists = try await apiClient.getArtists(sectionKey: sectionKey)
            artistRatingKeys = Set(artists.map(\.ratingKey))
        }
        let artistInputs = artists.map(Self.artistUpsertInput)
        let artistsToSync = Self.changedArtistInputs(
            artistInputs,
            existingMetadata: existingArtistMetadata
        )
        try await repository.batchUpsertArtists(artistsToSync, sourceCompositeKey: sourceKey)
        EnsembleLogger.debug(
            "⏱️ Incremental sync: artist metadata comparison took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(artists.count) from server, \(artistsToSync.count) changed"
        )

        // Fetch existing timestamps to skip unchanged items (avoids expensive per-item CoreData upserts)
        progressHandler(0.15)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let existingAlbumTimestamps = try await repository.fetchAlbumTimestamps(forSource: sourceKey)
        let existingTrackTimestamps = try await repository.fetchTrackTimestamps(forSource: sourceKey)
        let existingTrackRatings = try await repository.fetchTrackRatings(forSource: sourceKey)
        EnsembleLogger.debug("⏱️ Incremental sync: timestamp prefetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(existingAlbumTimestamps.count) albums, \(existingTrackTimestamps.count) tracks)")

        // Sync albums added or updated since timestamp
        progressHandler(0.25)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newAlbums = try await apiClient.getAlbums(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedAlbums = try await apiClient.getAlbums(sectionKey: sectionKey, updatedAfter: timestamp)

        let albumChanges = Self.deduplicatedChangedItems(
            added: newAlbums,
            updated: updatedAlbums,
            existingTimestamps: existingAlbumTimestamps,
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )
        let albumsToSync = albumChanges.changedItems
        let releaseFormats = albumsToSync.isEmpty ? nil : await libraryAlbumReleaseFormats()

        EnsembleLogger.debug("⏱️ Incremental sync: albums fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(albumChanges.uniqueCount) from server, \(albumsToSync.count) actually changed")
        phaseStart = CFAbsoluteTimeGetCurrent()
        // Build album genre lookup for incremental track upserts
        var incrementalAlbumGenres: [String: String] = [:]
        let albumInputs = albumsToSync.map { album in
            let input = Self.albumUpsertInput(
                from: album,
                releaseFormat: releaseFormats?[album.ratingKey],
                updatesReleaseFormat: releaseFormats != nil
            )
            if let genreString = input.genreNames {
                incrementalAlbumGenres[album.ratingKey] = genreString
            }
            return input
        }
        try await repository.batchUpsertAlbums(albumInputs, sourceCompositeKey: sourceKey)

        // Sync tracks added or updated since timestamp
        progressHandler(0.4)
        if !albumsToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: albums upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newTracks = try await apiClient.getTracks(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedTracks = try await apiClient.getTracks(sectionKey: sectionKey, updatedAfter: timestamp)

        // Note: ratedAfter (lastRatedAt>=) is intentionally omitted. The Plex API filter
        // returns ALL ever-rated tracks regardless of the timestamp argument, wasting ~1MB
        // and 3+ seconds per cycle for zero incremental benefit. Rating changes made on
        // other clients are caught by the next authoritative metadata reconciliation.
        // On-device rating changes go through MutationCoordinator immediately.

        let trackChanges = Self.deduplicatedChangedItems(
            added: newTracks,
            updated: updatedTracks,
            existingTimestamps: existingTrackTimestamps,
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt },
            hasAdditionalChange: { track in
                let serverRating = Int16(track.userRating.map { Int($0) } ?? 0)
                guard let localRating = existingTrackRatings[track.ratingKey] else {
                    return false
                }
                return localRating != serverRating
            }
        )
        let tracksToSync = trackChanges.changedItems

        // Diagnostic: break down WHY items in tracksToSync were flagged
        let tracksNew = tracksToSync.lazy.filter { existingTrackTimestamps[$0.ratingKey] == nil }.count
        let tracksRatingChanged = tracksToSync.lazy.filter { track in
            guard let localRating = existingTrackRatings[track.ratingKey] else { return false }
            return localRating != Int16(track.userRating.map { Int($0) } ?? 0)
        }.count
        let tracksTimestampChanged = tracksToSync.count - tracksNew - tracksRatingChanged
        EnsembleLogger.debug("⏱️ Incremental sync: tracks fetch \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(trackChanges.uniqueCount) from server, \(tracksToSync.count) to sync (new=\(tracksNew), ratingChanged=\(tracksRatingChanged), timestampChanged=\(tracksTimestampChanged))")
        phaseStart = CFAbsoluteTimeGetCurrent()
        let trackInputs = tracksToSync.map { track in
            let trackGenreNames = track.parentRatingKey.flatMap { incrementalAlbumGenres[$0] }
            return Self.trackUpsertInput(from: track, genreNames: trackGenreNames)
        }
        try await repository.batchUpsertTracks(trackInputs, sourceCompositeKey: sourceKey)

        // Orphan removal: fetch server inventory only after changes or on a periodic cleanup.
        progressHandler(0.55)
        if !tracksToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: tracks upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        EnsembleLogger.debug("⏱️ Incremental sync: library phase total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        phaseStart = CFAbsoluteTimeGetCurrent()

        let cursor = try await syncCursorRepository?.fetchCursor(
            scopeKey: sourceKey,
            scopeType: .plexLibrary
        )
        let changedItemCount = artistsToSync.count + albumsToSync.count + tracksToSync.count
        let fullMetadataReconciliationDue = Self.shouldReconcileFullMetadata(
            lastReconciledAt: cursor?.lastFullSyncAt,
            now: Date()
        )
        let shouldCheckOrphans = Self.shouldCheckOrphans(
            changedItemCount: changedItemCount,
            lastCheckedAt: cursor?.lastInventorySyncAt?.timeIntervalSince1970 ?? 0,
            now: Date()
        )

        var authoritativeChangedAlbums = 0
        var authoritativeChangedTracks = 0
        let removedArtists: Int
        let removedAlbums: Int
        let removedTracks: Int
        let removedTrackRatingKeys: Set<String>
        if shouldCheckOrphans || fullMetadataReconciliationDue {
            let albumRatingKeys: Set<String>
            let trackRatingKeys: Set<String>
            progressHandler(0.65)
            if fullMetadataReconciliationDue {
                async let existingAlbumMetadata = repository.fetchAlbumSyncMetadata(forSource: sourceKey)
                async let existingTrackMetadata = repository.fetchTrackSyncMetadata(forSource: sourceKey)
                async let allAlbums = apiClient.getAlbums(sectionKey: sectionKey)
                async let allTracks = apiClient.getTracks(sectionKey: sectionKey)
                let cachedAlbumMetadata = try await existingAlbumMetadata
                let cachedTrackMetadata = try await existingTrackMetadata
                var albums = try await allAlbums
                var tracks = try await allTracks
                var candidateAlbumRatingKeys = Set(albums.map(\.ratingKey))
                var candidateTrackRatingKeys = Set(tracks.map(\.ratingKey))
                if !Set(cachedAlbumMetadata.keys).isSubset(of: candidateAlbumRatingKeys) {
                    EnsembleLogger.debug("🔄 Confirming Plex album inventory before orphan removal")
                    albums = try await apiClient.getAlbums(sectionKey: sectionKey)
                    candidateAlbumRatingKeys = Set(albums.map(\.ratingKey))
                }
                if !Set(cachedTrackMetadata.keys).isSubset(of: candidateTrackRatingKeys) {
                    EnsembleLogger.debug("🔄 Confirming Plex track inventory before orphan removal")
                    tracks = try await apiClient.getTracks(sectionKey: sectionKey)
                    candidateTrackRatingKeys = Set(tracks.map(\.ratingKey))
                }
                let trackCounts = Self.trackCountsByAlbumRatingKey(tracks)
                let releaseFormats = await libraryAlbumReleaseFormats()
                let authoritativeAlbumInputs = albums.map { album in
                    Self.albumUpsertInput(
                        from: album,
                        trackCount: trackCounts[album.ratingKey],
                        releaseFormat: releaseFormats?[album.ratingKey],
                        updatesReleaseFormat: releaseFormats != nil
                    )
                }
                let authoritativeAlbumGenres = Dictionary(
                    uniqueKeysWithValues: authoritativeAlbumInputs.compactMap { input in
                        input.genreNames.map { (input.ratingKey, $0) }
                    }
                )
                let authoritativeTrackInputs = tracks.map { track in
                    Self.trackUpsertInput(
                        from: track,
                        genreNames: track.parentRatingKey.flatMap { authoritativeAlbumGenres[$0] }
                    )
                }
                let authoritativeAlbumsToSync = Self.changedAlbumInputs(
                    authoritativeAlbumInputs,
                    existingMetadata: cachedAlbumMetadata
                )
                let authoritativeTracksToSync = Self.changedTrackInputs(
                    authoritativeTrackInputs,
                    existingMetadata: cachedTrackMetadata
                )
                try await repository.batchUpsertAlbums(
                    authoritativeAlbumsToSync,
                    sourceCompositeKey: sourceKey
                )
                try await repository.batchUpsertTracks(
                    authoritativeTracksToSync,
                    sourceCompositeKey: sourceKey
                )
                authoritativeChangedAlbums = authoritativeAlbumsToSync.count
                authoritativeChangedTracks = authoritativeTracksToSync.count
                albumRatingKeys = candidateAlbumRatingKeys
                trackRatingKeys = candidateTrackRatingKeys
                EnsembleLogger.debug(
                    "🔄 Authoritative Plex metadata reconciliation: albums=\(authoritativeChangedAlbums) tracks=\(authoritativeChangedTracks)"
                )
            } else {
                // Concrete additions/deletions need only the compact identity inventory.
                var albumInventory = try await apiClient.getAlbumInventory(sectionKey: sectionKey)
                var candidateAlbumRatingKeys = Set(albumInventory.map(\.ratingKey))
                if !Set(existingAlbumTimestamps.keys).isSubset(of: candidateAlbumRatingKeys) {
                    EnsembleLogger.debug("🔄 Confirming Plex album inventory before orphan removal")
                    albumInventory = try await apiClient.getAlbumInventory(sectionKey: sectionKey)
                    candidateAlbumRatingKeys = Set(albumInventory.map(\.ratingKey))
                }
                albumRatingKeys = candidateAlbumRatingKeys
                progressHandler(0.75)
                var trackInventory = try await apiClient.getTrackInventory(sectionKey: sectionKey)
                var candidateTrackRatingKeys = Set(trackInventory.map(\.ratingKey))
                if !Set(existingTrackTimestamps.keys).isSubset(of: candidateTrackRatingKeys) {
                    EnsembleLogger.debug("🔄 Confirming Plex track inventory before orphan removal")
                    trackInventory = try await apiClient.getTrackInventory(sectionKey: sectionKey)
                    candidateTrackRatingKeys = Set(trackInventory.map(\.ratingKey))
                }
                trackRatingKeys = candidateTrackRatingKeys
            }
            progressHandler(0.85)

            removedTrackRatingKeys = Set(
                existingTrackTimestamps.keys.lazy.filter { !trackRatingKeys.contains($0) }
            )
            removedTracks = try await repository.removeOrphanedTracks(notIn: trackRatingKeys, forSource: sourceKey)
            removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumRatingKeys, forSource: sourceKey)
            removedArtists = try await repository.removeOrphanedArtists(notIn: artistRatingKeys, forSource: sourceKey)
            let survivingArtistIDs = artistRatingKeys
            let survivingAlbumIDs = albumRatingKeys
            let survivingTrackIDs = trackRatingKeys
            await MainActor.run {
                HiddenMediaStore.shared.removeMissing(kind: .artist, sourceKey: sourceKey, survivingItemIDs: survivingArtistIDs)
                HiddenMediaStore.shared.removeMissing(kind: .album, sourceKey: sourceKey, survivingItemIDs: survivingAlbumIDs)
                HiddenMediaStore.shared.removeMissing(kind: .track, sourceKey: sourceKey, survivingItemIDs: survivingTrackIDs)
            }
            if fullMetadataReconciliationDue {
                try await syncCursorRepository?.recordFullSync(
                    scopeKey: sourceKey,
                    scopeType: .plexLibrary,
                    at: queryStartedAt
                )
            } else {
                try await syncCursorRepository?.recordInventorySync(
                    scopeKey: sourceKey,
                    scopeType: .plexLibrary,
                    at: Date()
                )
            }

            if removedArtists + removedAlbums + removedTracks > 0 {
                EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks")
            } else {
                EnsembleLogger.debug("✅ No orphaned items found")
            }
            EnsembleLogger.debug("⏱️ Incremental sync: orphan check took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        } else {
            removedArtists = 0
            removedAlbums = 0
            removedTracks = 0
            removedTrackRatingKeys = []
            progressHandler(0.9)
            EnsembleLogger.debug("⏭️ Incremental sync: orphan check skipped; no library changes and recent cleanup exists")
        }

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)
        try await syncCursorRepository?.recordIncrementalSync(
            scopeKey: sourceKey,
            scopeType: .plexLibrary,
            at: queryStartedAt
        )

        progressHandler(1.0)
        EnsembleLogger.debug("✅ Incremental sync complete for \(sourceKey) — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        return LibrarySyncResult(
            changedArtists: artistsToSync.count,
            changedAlbums: albumsToSync.count + authoritativeChangedAlbums,
            changedTracks: tracksToSync.count + authoritativeChangedTracks,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks,
            removedTrackRatingKeys: removedTrackRatingKeys
        )
    }

    struct IncrementalChangeSet<Item> {
        let uniqueItems: [Item]
        let changedItems: [Item]

        var uniqueCount: Int {
            uniqueItems.count
        }
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

    static func changedArtistInputs(
        _ inputs: [ArtistUpsertInput],
        existingMetadata: [String: ArtistSyncMetadata]
    ) -> [ArtistUpsertInput] {
        inputs.filter { input in
            existingMetadata[input.ratingKey]?.matches(input) != true
        }
    }

    static func changedAlbumInputs(
        _ inputs: [AlbumUpsertInput],
        existingMetadata: [String: AlbumSyncMetadata]
    ) -> [AlbumUpsertInput] {
        inputs.filter { input in
            existingMetadata[input.ratingKey]?.matches(input) != true
        }
    }

    static func changedTrackInputs(
        _ inputs: [TrackUpsertInput],
        existingMetadata: [String: TrackSyncMetadata]
    ) -> [TrackUpsertInput] {
        inputs.filter { input in
            existingMetadata[input.ratingKey]?.matches(input) != true
        }
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
            rating: 0,
            genreNames: album.genreNames.isEmpty ? nil : album.genreNames.joined(separator: ", "),
            releaseFormat: releaseFormat?.rawValue,
            updatesReleaseFormat: updatesReleaseFormat
        )
    }

    static func trackCountsByAlbumRatingKey(_ tracks: [PlexTrack]) -> [String: Int] {
        tracks.reduce(into: [:]) { counts, track in
            if let albumRatingKey = track.parentRatingKey {
                counts[albumRatingKey, default: 0] += 1
            }
        }
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
    
    public func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let syncStart = CFAbsoluteTimeGetCurrent()
        let queryStartedAt = Date()
        let sourceKey = sourceIdentifier.compositeKey
        EnsembleLogger.debug("🔄 Full library sync starting for \(sourceKey)")

        // Ensure CDMusicSource exists
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: sourceIdentifier.type.rawValue,
            accountId: sourceIdentifier.accountId,
            serverId: sourceIdentifier.serverId,
            libraryId: sourceIdentifier.libraryId,
            displayName: nil,
            accountName: nil
        )

        async let cachedArtistMetadataRequest = repository.fetchArtistSyncMetadata(forSource: sourceKey)
        async let cachedAlbumTimestampsRequest = repository.fetchAlbumTimestamps(forSource: sourceKey)
        async let cachedTrackTimestampsRequest = repository.fetchTrackTimestamps(forSource: sourceKey)

        // Sync artists (batch upsert — single context, single save)
        progressHandler(0.1)
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let cachedArtistMetadata = try await cachedArtistMetadataRequest
        var artists = try await apiClient.getArtists(sectionKey: sectionKey)
        var artistRatingKeys = Set(artists.map { $0.ratingKey })
        if !Set(cachedArtistMetadata.keys).isSubset(of: artistRatingKeys) {
            EnsembleLogger.debug("🔄 Confirming Plex artist inventory before orphan removal")
            artists = try await apiClient.getArtists(sectionKey: sectionKey)
            artistRatingKeys = Set(artists.map { $0.ratingKey })
        }
        let artistInputs = artists.map(Self.artistUpsertInput)
        try await repository.batchUpsertArtists(artistInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: artists \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(artists.count) items)")

        // Sync albums (batch upsert)
        progressHandler(0.3)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let cachedAlbumTimestamps = try await cachedAlbumTimestampsRequest
        let cachedTrackTimestamps = try await cachedTrackTimestampsRequest
        var albums = try await apiClient.getAlbums(sectionKey: sectionKey)
        let releaseFormats = await libraryAlbumReleaseFormats()
        var tracks = try await apiClient.getTracks(sectionKey: sectionKey)
        var albumRatingKeys = Set(albums.map { $0.ratingKey })
        var trackRatingKeys = Set(tracks.map { $0.ratingKey })
        if !Set(cachedAlbumTimestamps.keys).isSubset(of: albumRatingKeys) {
            EnsembleLogger.debug("🔄 Confirming Plex album inventory before orphan removal")
            albums = try await apiClient.getAlbums(sectionKey: sectionKey)
            albumRatingKeys = Set(albums.map { $0.ratingKey })
        }
        if !Set(cachedTrackTimestamps.keys).isSubset(of: trackRatingKeys) {
            EnsembleLogger.debug("🔄 Confirming Plex track inventory before orphan removal")
            tracks = try await apiClient.getTracks(sectionKey: sectionKey)
            trackRatingKeys = Set(tracks.map { $0.ratingKey })
        }
        let trackCountsByAlbum = Self.trackCountsByAlbumRatingKey(tracks)
        // Build album genre lookup for copying genres to tracks (Plex only returns genres on albums)
        var albumGenresByKey: [String: String] = [:]
        let albumInputs = albums.map { album in
            let input = Self.albumUpsertInput(
                from: album,
                trackCount: trackCountsByAlbum[album.ratingKey],
                releaseFormat: releaseFormats?[album.ratingKey],
                updatesReleaseFormat: releaseFormats != nil
            )
            if let genreString = input.genreNames {
                albumGenresByKey[album.ratingKey] = genreString
            }
            return input
        }
        try await repository.batchUpsertAlbums(albumInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: albums \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(albums.count) items)")

        // Sync tracks (batch upsert — biggest win, ~24s → ~2-3s)
        progressHandler(0.5)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let trackInputs = tracks.map { track in
            // Copy genre from parent album (Plex doesn't return genres on tracks)
            let trackGenreNames = track.parentRatingKey.flatMap { albumGenresByKey[$0] }
            return Self.trackUpsertInput(from: track, genreNames: trackGenreNames)
        }
        try await repository.batchUpsertTracks(trackInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: tracks \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(tracks.count) items)")

        // Sync genres
        progressHandler(0.7)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let genres = try await apiClient.getGenres(sectionKey: sectionKey)
        let genreRatingKeys = Set(genres.compactMap { $0.ratingKey })
        try await repository.batchUpsertGenres(
            genres.map { genre in
                GenreUpsertInput(
                    ratingKey: genre.ratingKey,
                    key: genre.key,
                    title: genre.title
                )
            },
            sourceCompositeKey: sourceKey
        )

        EnsembleLogger.debug("⏱️ Full sync: genres \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(genres.count) items)")

        // Remove orphaned items (deleted/merged on server but still in local DB)
        progressHandler(0.85)
        phaseStart = CFAbsoluteTimeGetCurrent()
        EnsembleLogger.debug("🧹 Checking for orphaned items...")
        let removedTrackRatingKeys = Set(
            cachedTrackTimestamps.keys.lazy.filter { !trackRatingKeys.contains($0) }
        )
        let removedTracks = try await repository.removeOrphanedTracks(notIn: trackRatingKeys, forSource: sourceKey)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumRatingKeys, forSource: sourceKey)
        let removedArtists = try await repository.removeOrphanedArtists(notIn: artistRatingKeys, forSource: sourceKey)
        let removedGenres = try await repository.removeOrphanedGenres(notIn: genreRatingKeys, forSource: sourceKey)
        let survivingArtistIDs = artistRatingKeys
        let survivingAlbumIDs = albumRatingKeys
        let survivingTrackIDs = trackRatingKeys
        await MainActor.run {
            HiddenMediaStore.shared.removeMissing(kind: .artist, sourceKey: sourceKey, survivingItemIDs: survivingArtistIDs)
            HiddenMediaStore.shared.removeMissing(kind: .album, sourceKey: sourceKey, survivingItemIDs: survivingAlbumIDs)
            HiddenMediaStore.shared.removeMissing(kind: .track, sourceKey: sourceKey, survivingItemIDs: survivingTrackIDs)
        }

        if removedArtists + removedAlbums + removedTracks + removedGenres > 0 {
            EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks, \(removedGenres) genres")
        } else {
            EnsembleLogger.debug("✅ No orphaned items found")
        }

        EnsembleLogger.debug("⏱️ Full sync: orphan check \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        EnsembleLogger.debug("⏱️ Full sync complete — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s (\(artists.count) artists, \(albums.count) albums, \(tracks.count) tracks, \(genres.count) genres)")

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)
        try await syncCursorRepository?.recordFullSync(
            scopeKey: sourceKey,
            scopeType: .plexLibrary,
            at: queryStartedAt
        )

        progressHandler(1.0)
        return LibrarySyncResult(
            changedArtists: artists.count,
            changedAlbums: albums.count,
            changedTracks: tracks.count,
            changedGenres: genres.count,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks,
            removedTrackRatingKeys: removedTrackRatingKeys,
            removedGenres: removedGenres
        )
    }

    public func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        // Use server-level identifier for playlists (not library-specific)
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"
        let queryStartedAt = Date()

        let playlistSyncStart = CFAbsoluteTimeGetCurrent()
        progressHandler(0.1)
        let existingTimestamps = try await repository.fetchPlaylistTimestamps(forSource: serverSourceKey)
        let localTrackStates = try await repository.fetchPlaylistLocalTrackStates(forSource: serverSourceKey)
        let playlists = try await apiClient.getPlaylists()
        EnsembleLogger.debug("⏱️ Playlist sync: fetched \(playlists.count) playlists in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistSyncStart))s")

        var fetchedTrackLists = 0
        var skippedTrackLists = 0
        for (index, playlist) in playlists.enumerated() {
            let playlistProgress = 0.1 + (0.8 * Double(index) / Double(playlists.count))
            progressHandler(playlistProgress)
            let shouldFetchTracks = Self.shouldFetchPlaylistTracks(
                serverUpdatedAt: playlist.updatedAt,
                existingModifiedAt: existingTimestamps[playlist.ratingKey]
            ) || Self.shouldRepairPlaylistTracks(
                serverTrackCount: playlist.leafCount,
                localMembershipCount: localTrackStates[playlist.ratingKey]?.membershipCount
            )

            try await Self.upsertPlaylist(playlist, to: repository, sourceCompositeKey: serverSourceKey)

            guard shouldFetchTracks else {
                skippedTrackLists += 1
                continue
            }

            let playlistTracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.ratingKey)
            let trackKeys = playlistTracks.map { $0.ratingKey }
            EnsembleLogger.debug("📋 Syncing playlist '\(playlist.title)': \(trackKeys.count) tracks")
            if trackKeys.count > 0 {
                EnsembleLogger.debug("📋 First track key: \(trackKeys[0])")
            }
            try await repository.setPlaylistTrackSnapshots(
                playlistTracks.map(Self.playlistTrackSnapshot),
                forPlaylist: playlist.ratingKey,
                sourceCompositeKey: serverSourceKey
            )
            fetchedTrackLists += 1
        }

        let validPlaylistKeys = Set(playlists.map(\.ratingKey))
        let removedPlaylists = try await repository.removeOrphanedPlaylists(
            notIn: validPlaylistKeys,
            forSource: serverSourceKey
        )
        await MainActor.run {
            HiddenMediaStore.shared.removeMissing(
                kind: .playlist,
                sourceKey: serverSourceKey,
                survivingItemIDs: validPlaylistKeys
            )
        }
        if removedPlaylists > 0 {
            EnsembleLogger.debug("🧹 Full playlist sync removed \(removedPlaylists) orphaned playlists")
        }

        let completedAt = Date()
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
        UserDefaults.standard.set(queryStartedAt.timeIntervalSince1970, forKey: timestampKey)
        UserDefaults.standard.set(completedAt.timeIntervalSince1970, forKey: Self.playlistOrphanCheckKey(for: serverSourceKey))
        try await syncCursorRepository?.recordFullSync(
            scopeKey: serverSourceKey,
            scopeType: .serverPlaylists,
            at: queryStartedAt
        )

        EnsembleLogger.debug("⏱️ Playlist sync: full sync total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistSyncStart))s (\(playlists.count) playlists, fetchedTracks=\(fetchedTrackLists), skippedTracks=\(skippedTrackLists), removed=\(removedPlaylists))")
        progressHandler(1.0)
        return PlaylistSyncResult(
            changedPlaylists: fetchedTrackLists,
            removedPlaylists: removedPlaylists
        )
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

    /// Sync only playlists that changed since last sync (incremental)
    public func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        forceOrphanCheck: Bool = false,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        let syncStart = CFAbsoluteTimeGetCurrent()
        let queryStartedAt = Date()
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
        let orphanTimestampKey = Self.playlistOrphanCheckKey(for: serverSourceKey)

        let cursor = try await syncCursorRepository?.fetchCursor(
            scopeKey: serverSourceKey,
            scopeType: .serverPlaylists
        )
        let legacySyncTimestamp = UserDefaults.standard.double(forKey: timestampKey)
        let lastSyncTimestamp = cursor?.lastIncrementalSyncAt?.timeIntervalSince1970
            ?? cursor?.lastFullSyncAt?.timeIntervalSince1970
            ?? cursor?.lastSuccessfulSyncAt?.timeIntervalSince1970
            ?? legacySyncTimestamp

        // If never synced, fall back to full sync
        guard lastSyncTimestamp > 0 else {
            EnsembleLogger.debug("⚠️ No previous playlist sync found, performing full sync")
            return try await syncPlaylists(to: repository, progressHandler: progressHandler)
        }

        progressHandler(0.1)

        // Fetch existing playlist timestamps for change detection
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let existingTimestamps = try await repository.fetchPlaylistTimestamps(forSource: serverSourceKey)
        // Authoritative refreshes reuse one complete response for change detection and orphan removal.
        let authoritativePlaylists: [PlexPlaylist]?
        let newPlaylists: [PlexPlaylist]
        let updatedPlaylists: [PlexPlaylist]
        if forceOrphanCheck {
            let playlists = try await apiClient.getPlaylists()
            authoritativePlaylists = playlists
            newPlaylists = playlists
            updatedPlaylists = []
        } else {
            authoritativePlaylists = nil
            newPlaylists = try await apiClient.getPlaylists(addedAfter: lastSyncTimestamp)
            updatedPlaylists = try await apiClient.getPlaylists(updatedAfter: lastSyncTimestamp)
        }

        let playlistChanges = Self.deduplicatedChangedItems(
            added: newPlaylists,
            updated: updatedPlaylists,
            existingTimestamps: existingTimestamps,
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )
        let changedPlaylists = playlistChanges.changedItems

        EnsembleLogger.debug("⏱️ Incremental playlist fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(playlistChanges.uniqueCount) from server, \(changedPlaylists.count) actually changed")

        // Sync only changed playlists (only fetch tracks for changed ones)
        phaseStart = CFAbsoluteTimeGetCurrent()
        for (index, playlist) in changedPlaylists.enumerated() {
            let playlistProgress = 0.1 + (0.5 * Double(index) / Double(max(changedPlaylists.count, 1)))
            progressHandler(playlistProgress)

            try await Self.upsertPlaylist(playlist, to: repository, sourceCompositeKey: serverSourceKey)

            let playlistTracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.ratingKey)
            let trackKeys = playlistTracks.map { $0.ratingKey }
            EnsembleLogger.debug("📋 Incremental sync playlist '\(playlist.title)': \(trackKeys.count) tracks")
            try await repository.setPlaylistTrackSnapshots(
                playlistTracks.map(Self.playlistTrackSnapshot),
                forPlaylist: playlist.ratingKey,
                sourceCompositeKey: serverSourceKey
            )
        }

        EnsembleLogger.debug("⏱️ Incremental playlist upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")

        // Orphan removal: fetch inventory only after playlist changes or on a periodic cleanup.
        progressHandler(0.7)
        let shouldCheckOrphans = Self.shouldCheckOrphans(
            changedItemCount: changedPlaylists.count,
            lastCheckedAt: forceOrphanCheck
                ? 0
                : cursor?.lastInventorySyncAt?.timeIntervalSince1970
                    ?? UserDefaults.standard.double(forKey: orphanTimestampKey),
            now: Date()
        )
        let removedPlaylists: Int
        if shouldCheckOrphans {
            phaseStart = CFAbsoluteTimeGetCurrent()
            EnsembleLogger.debug("🧹 Checking for orphaned playlists...")
            let validPlaylistKeys: Set<String>
            if let authoritativePlaylists {
                validPlaylistKeys = Set(authoritativePlaylists.map(\.ratingKey))
            } else {
                validPlaylistKeys = Set(try await apiClient.getPlaylistInventory().map(\.ratingKey))
            }
            progressHandler(0.85)

            removedPlaylists = try await repository.removeOrphanedPlaylists(notIn: validPlaylistKeys, forSource: serverSourceKey)
            await MainActor.run {
                HiddenMediaStore.shared.removeMissing(
                    kind: .playlist,
                    sourceKey: serverSourceKey,
                    survivingItemIDs: validPlaylistKeys
                )
            }
            let inventorySyncedAt = Date()
            UserDefaults.standard.set(inventorySyncedAt.timeIntervalSince1970, forKey: orphanTimestampKey)
            try await syncCursorRepository?.recordInventorySync(
                scopeKey: serverSourceKey,
                scopeType: .serverPlaylists,
                at: inventorySyncedAt
            )
            if removedPlaylists > 0 {
                EnsembleLogger.debug("🧹 Removed \(removedPlaylists) orphaned playlists")
            } else {
                EnsembleLogger.debug("✅ No orphaned playlists found")
            }

            EnsembleLogger.debug("⏱️ Incremental playlist orphan check took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        } else {
            removedPlaylists = 0
            progressHandler(0.9)
            EnsembleLogger.debug("⏭️ Incremental playlist orphan check skipped; no playlist changes and recent cleanup exists")
        }

        UserDefaults.standard.set(queryStartedAt.timeIntervalSince1970, forKey: timestampKey)
        try await syncCursorRepository?.recordIncrementalSync(
            scopeKey: serverSourceKey,
            scopeType: .serverPlaylists,
            at: queryStartedAt
        )

        EnsembleLogger.debug("⏱️ Incremental playlist sync complete — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")

        progressHandler(1.0)
        return PlaylistSyncResult(
            changedPlaylists: changedPlaylists.count,
            removedPlaylists: removedPlaylists
        )
    }

    static func shouldFetchPlaylistTracks(
        serverUpdatedAt: Int?,
        existingModifiedAt: Date?
    ) -> Bool {
        guard let existingModifiedAt else { return true }
        guard let serverUpdatedAt else { return false }
        return serverUpdatedAt != Int(existingModifiedAt.timeIntervalSince1970)
    }

    static func shouldRepairPlaylistTracks(
        serverTrackCount: Int?,
        localMembershipCount: Int?
    ) -> Bool {
        guard let serverTrackCount, serverTrackCount > 0 else { return false }
        return localMembershipCount.map { $0 == 0 || $0 > serverTrackCount } ?? true
    }

    static func shouldCheckOrphans(
        changedItemCount: Int,
        lastCheckedAt: TimeInterval,
        now: Date,
        interval: TimeInterval = orphanCheckInterval
    ) -> Bool {
        guard changedItemCount == 0 else { return true }
        guard lastCheckedAt > 0 else { return true }
        return now.timeIntervalSince1970 - lastCheckedAt >= interval
    }

    static func shouldReconcileFullMetadata(
        lastReconciledAt: Date?,
        now: Date,
        interval: TimeInterval = orphanCheckInterval
    ) -> Bool {
        guard let lastReconciledAt else { return true }
        let age = now.timeIntervalSince(lastReconciledAt)
        return age < 0 || age >= interval
    }

    @discardableResult
    static func upsertPlaylist(
        _ playlist: PlexPlaylist,
        to repository: PlaylistRepositoryProtocol,
        sourceCompositeKey: String,
        trackCount: Int? = nil
    ) async throws -> CDPlaylist {
        let isSmart = playlist.smart ?? false
        return try await repository.upsertPlaylist(
            PlaylistUpsertInput(
                ratingKey: playlist.ratingKey,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.composite,
                isSmart: isSmart,
                duration: playlist.duration,
                trackCount: trackCount ?? playlist.leafCount,
                dateAdded: playlist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: playlist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: playlist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                actionCapabilities: PlaylistActionCapabilities(
                    canAddItems: !isSmart,
                    canRename: !isSmart,
                    canReorder: !isSmart,
                    canDelete: !isSmart,
                    unavailableReason: isSmart ? "Smart playlists are read-only." : nil
                )
            ),
            sourceCompositeKey: sourceCompositeKey
        )
    }

    static func playlistOrphanCheckKey(for serverSourceKey: String) -> String {
        "lastPlaylistOrphanCheckAt_\(serverSourceKey)"
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
        startTime: TimeInterval = 0
    ) async throws -> StreamDecision {
        EnsembleLogger.debug("[PlexProvider] makeStreamDecision: ratingKey=\(trackRatingKey), quality=\(quality.rawValue)")

        do {
            let decision = try await apiClient.makeStreamDecision(
                ratingKey: trackRatingKey,
                trackStreamKey: trackStreamKey,
                quality: quality,
                metadataDurationSeconds: metadataDurationSeconds,
                startTime: startTime
            )
            switch decision {
            case .directStream:
                EnsembleLogger.debug("[PlexProvider] Decision: directStream (quality=\(quality.rawValue))")
            case .progressiveTranscode:
                EnsembleLogger.debug("[PlexProvider] Decision: progressiveTranscode (quality=\(quality.rawValue))")
            }
            return decision
        } catch {
            EnsembleLogger.debug("[PlexProvider] makeStreamDecision failed: \(error). Falling back to direct stream decision.")
        }

        // Fallback: direct stream decision with the stream key
        if let streamKey = trackStreamKey, !streamKey.isEmpty {
            return .directStream(partKey: streamKey)
        }

        // Last resort: fetch track metadata for stream key
        guard let track = try await apiClient.getTrack(trackKey: trackRatingKey),
              let streamKey = track.streamURL else {
            EnsembleLogger.debug("[PlexProvider] Could not get stream key from track metadata for decision")
            throw PlexAPIError.invalidURL
        }
        return .directStream(partKey: streamKey)
    }

    /// Phase 2: Assemble a StreamResolution from a cached StreamDecision.
    /// Reads the freshest endpoint from the registry before building the URL.
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
            return try await apiClient.getStreamURL(trackKey: trackStreamKey)
        }

        // Last resort: fetch track metadata for stream key
        guard let track = try await apiClient.getTrack(trackKey: trackRatingKey),
              let streamKey = track.streamURL else {
            throw PlexAPIError.invalidURL
        }
        return try await apiClient.getStreamURL(trackKey: streamKey)
    }

    public func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        try await apiClient.getArtworkURL(path: path, size: size)
    }

    public func rateTrack(
        _ track: Track,
        rating: Int?
    ) async throws -> MusicSourceRatingMutationEffects {
        try await apiClient.rateTrack(ratingKey: track.id, rating: rating)
        return .refreshPlaylistsAndFavoriteDownloads
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
                    EnsembleLogger.debug("PlexMusicSourceSyncProvider: Album format query failed for \(artistKey): \(error.localizedDescription)")
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
            EnsembleLogger.debug("PlexMusicSourceSyncProvider: Section artist album query failed for \(artistKey): \(error.localizedDescription)")
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
            EnsembleLogger.debug("PlexMusicSourceSyncProvider: Library album format query failed: \(error.localizedDescription)")
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
