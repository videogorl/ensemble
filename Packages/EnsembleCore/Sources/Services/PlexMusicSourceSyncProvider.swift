import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Syncs a single Plex server+library to CoreData
public final class PlexMusicSourceSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
    static let playlistOrphanCheckInterval: TimeInterval = 24 * 60 * 60

    public let sourceIdentifier: MusicSourceIdentifier
    private let apiClient: PlexAPIClient
    /// Library section key used for API calls. Internal for WebSocket-triggered sync matching.
    let sectionKey: String

    /// Read-only access for services that need direct API calls (e.g. LyricsService)
    public var exposedAPIClient: PlexAPIClient { apiClient }

    public init(
        sourceIdentifier: MusicSourceIdentifier,
        apiClient: PlexAPIClient,
        sectionKey: String
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.apiClient = apiClient
        self.sectionKey = sectionKey
    }

    public func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let sourceKey = sourceIdentifier.compositeKey
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

        if try await librarySectionIsUnchanged(since: timestamp) {
            try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)
            progressHandler(1.0)
            EnsembleLogger.debug("⏭️ Incremental sync: Plex section \(sectionKey) unchanged, skipped library item fetches")
            return LibrarySyncResult()
        }

        // Fetch existing timestamps to skip unchanged items (avoids expensive per-item CoreData upserts)
        progressHandler(0.05)
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let existingArtistTimestamps = try await repository.fetchArtistTimestamps(forSource: sourceKey)
        let existingAlbumTimestamps = try await repository.fetchAlbumTimestamps(forSource: sourceKey)
        let existingTrackTimestamps = try await repository.fetchTrackTimestamps(forSource: sourceKey)
        let existingTrackRatings = try await repository.fetchTrackRatings(forSource: sourceKey)
        EnsembleLogger.debug("⏱️ Incremental sync: timestamp prefetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(existingArtistTimestamps.count) artists, \(existingAlbumTimestamps.count) albums, \(existingTrackTimestamps.count) tracks)")

        // Sync artists added or updated since timestamp
        progressHandler(0.1)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newArtists = try await apiClient.getArtists(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedArtists = try await apiClient.getArtists(sectionKey: sectionKey, updatedAfter: timestamp)

        let artistChanges = Self.deduplicatedChangedItems(
            added: newArtists,
            updated: updatedArtists,
            existingTimestamps: existingArtistTimestamps,
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )
        let artistsToSync = artistChanges.changedItems

        EnsembleLogger.debug("⏱️ Incremental sync: artists fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(artistChanges.uniqueCount) from server, \(artistsToSync.count) actually changed")
        phaseStart = CFAbsoluteTimeGetCurrent()
        for artist in artistsToSync {
            _ = try await repository.upsertArtist(
                ratingKey: artist.ratingKey,
                key: artist.key,
                name: artist.title,
                summary: artist.summary,
                thumbPath: artist.thumb,
                artPath: artist.art,
                dateAdded: artist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: artist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceKey
            )
        }

        // Sync albums added or updated since timestamp
        progressHandler(0.25)
        if !artistsToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: artists upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
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

        EnsembleLogger.debug("⏱️ Incremental sync: albums fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(albumChanges.uniqueCount) from server, \(albumsToSync.count) actually changed")
        phaseStart = CFAbsoluteTimeGetCurrent()
        // Build album genre lookup for incremental track upserts
        var incrementalAlbumGenres: [String: String] = [:]
        for album in albumsToSync {
            let genreString = album.genreNames.isEmpty ? nil : album.genreNames.joined(separator: ", ")
            if let genreString = genreString {
                incrementalAlbumGenres[album.ratingKey] = genreString
            }
            _ = try await repository.upsertAlbum(
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
                trackCount: album.leafCount,
                dateAdded: album.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: album.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                rating: 0,
                genreNames: genreString,
                sourceCompositeKey: sourceKey
            )
        }

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
        // other clients are caught by the next full sync (app launch or 1h periodic).
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
        let tracksNew = tracksToSync.filter { existingTrackTimestamps[$0.ratingKey] == nil }.count
        let tracksRatingChanged = tracksToSync.filter { track in
            guard let localRating = existingTrackRatings[track.ratingKey] else { return false }
            return localRating != Int16(track.userRating.map { Int($0) } ?? 0)
        }.count
        let tracksTimestampChanged = tracksToSync.count - tracksNew - tracksRatingChanged
        EnsembleLogger.debug("⏱️ Incremental sync: tracks fetch \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(trackChanges.uniqueCount) from server, \(tracksToSync.count) to sync (new=\(tracksNew), ratingChanged=\(tracksRatingChanged), timestampChanged=\(tracksTimestampChanged))")
        phaseStart = CFAbsoluteTimeGetCurrent()
        let trackInputs = tracksToSync.map { track in
            let trackGenreNames = track.parentRatingKey.flatMap { incrementalAlbumGenres[$0] }
            return TrackUpsertInput(
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
                genreNames: trackGenreNames,
            )
        }
        try await repository.batchUpsertTracks(trackInputs, sourceCompositeKey: sourceKey)

        // Orphan removal: Fetch server inventory (lightweight) and remove local items not on server
        progressHandler(0.55)
        if !tracksToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: tracks upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        EnsembleLogger.debug("⏱️ Incremental sync: library phase total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        phaseStart = CFAbsoluteTimeGetCurrent()

        // Fetch only ratingKeys from server using includeFields parameter (much smaller response)
        let artistInventory = try await apiClient.getArtistInventory(sectionKey: sectionKey)
        let artistRatingKeys = Set(artistInventory.map { $0.ratingKey })
        progressHandler(0.65)

        let albumInventory = try await apiClient.getAlbumInventory(sectionKey: sectionKey)
        let albumRatingKeys = Set(albumInventory.map { $0.ratingKey })
        progressHandler(0.75)

        let trackInventory = try await apiClient.getTrackInventory(sectionKey: sectionKey)
        let trackRatingKeys = Set(trackInventory.map { $0.ratingKey })
        progressHandler(0.85)

        // Remove orphans
        let removedArtists = try await repository.removeOrphanedArtists(notIn: artistRatingKeys, forSource: sourceKey)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumRatingKeys, forSource: sourceKey)
        let removedTracks = try await repository.removeOrphanedTracks(notIn: trackRatingKeys, forSource: sourceKey)

        if removedArtists + removedAlbums + removedTracks > 0 {
            EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks")
        } else {
            EnsembleLogger.debug("✅ No orphaned items found")
        }

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)

        progressHandler(1.0)
        EnsembleLogger.debug("⏱️ Incremental sync: orphan check took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        EnsembleLogger.debug("✅ Incremental sync complete for \(sourceKey) — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        return LibrarySyncResult(
            changedArtists: artistsToSync.count,
            changedAlbums: albumsToSync.count,
            changedTracks: tracksToSync.count,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks
        )
    }

    private func librarySectionIsUnchanged(since timestamp: TimeInterval) async throws -> Bool {
        let phaseStart = CFAbsoluteTimeGetCurrent()
        do {
            let sections = try await apiClient.getLibrarySections()
            guard let section = sections.first(where: { $0.key == sectionKey }) else {
                EnsembleLogger.debug("⏱️ Incremental sync: section preflight found no section \(sectionKey)")
                return false
            }

            let shouldSkip = Self.shouldSkipIncrementalLibrarySync(
                sectionUpdatedAt: section.updatedAt,
                queryTimestamp: timestamp
            )
            EnsembleLogger.debug(
                "⏱️ Incremental sync: section preflight took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (updatedAt=\(section.updatedAt ?? 0), skip=\(shouldSkip))"
            )
            return shouldSkip
        } catch {
            if error is CancellationError { throw error }
            EnsembleLogger.debug("⏱️ Incremental sync: section preflight failed, continuing with item sync: \(error.localizedDescription)")
            return false
        }
    }

    static func shouldSkipIncrementalLibrarySync(sectionUpdatedAt: Int?, queryTimestamp: TimeInterval) -> Bool {
        guard let sectionUpdatedAt else { return false }
        // Existing item queries use addedAt>= and updatedAt>=, so only skip when the
        // whole section is older than that exact query window.
        return sectionUpdatedAt < Int(queryTimestamp)
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
    
    public func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let syncStart = CFAbsoluteTimeGetCurrent()
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

        // Sync artists (batch upsert — single context, single save)
        progressHandler(0.1)
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let artists = try await apiClient.getArtists(sectionKey: sectionKey)
        let artistRatingKeys = Set(artists.map { $0.ratingKey })
        let artistInputs = artists.map { artist in
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
        try await repository.batchUpsertArtists(artistInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: artists \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(artists.count) items)")

        // Sync albums (batch upsert)
        progressHandler(0.3)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let albums = try await apiClient.getAlbums(sectionKey: sectionKey)
        let albumRatingKeys = Set(albums.map { $0.ratingKey })
        // Build album genre lookup for copying genres to tracks (Plex only returns genres on albums)
        var albumGenresByKey: [String: String] = [:]
        let albumInputs = albums.map { album in
            let genreString = album.genreNames.isEmpty ? nil : album.genreNames.joined(separator: ", ")
            if let genreString = genreString {
                albumGenresByKey[album.ratingKey] = genreString
            }
            return AlbumUpsertInput(
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
                trackCount: album.leafCount,
                dateAdded: album.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: album.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                rating: 0,
                genreNames: genreString
            )
        }
        try await repository.batchUpsertAlbums(albumInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: albums \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(albums.count) items)")

        // Sync tracks (batch upsert — biggest win, ~24s → ~2-3s)
        progressHandler(0.5)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let tracks = try await apiClient.getTracks(sectionKey: sectionKey)
        let trackRatingKeys = Set(tracks.map { $0.ratingKey })
        let trackInputs = tracks.map { track in
            // Copy genre from parent album (Plex doesn't return genres on tracks)
            let trackGenreNames = track.parentRatingKey.flatMap { albumGenresByKey[$0] }
            return TrackUpsertInput(
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
                genreNames: trackGenreNames
            )
        }
        try await repository.batchUpsertTracks(trackInputs, sourceCompositeKey: sourceKey)

        EnsembleLogger.debug("⏱️ Full sync: tracks \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(tracks.count) items)")

        // Sync genres
        progressHandler(0.7)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let genres = try await apiClient.getGenres(sectionKey: sectionKey)
        let genreRatingKeys = Set(genres.compactMap { $0.ratingKey })
        for genre in genres {
            _ = try await repository.upsertGenre(
                ratingKey: genre.ratingKey,
                key: genre.key,
                title: genre.title,
                sourceCompositeKey: sourceKey
            )
        }

        EnsembleLogger.debug("⏱️ Full sync: genres \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(genres.count) items)")

        // Remove orphaned items (deleted/merged on server but still in local DB)
        progressHandler(0.85)
        phaseStart = CFAbsoluteTimeGetCurrent()
        EnsembleLogger.debug("🧹 Checking for orphaned items...")
        let removedArtists = try await repository.removeOrphanedArtists(notIn: artistRatingKeys, forSource: sourceKey)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumRatingKeys, forSource: sourceKey)
        let removedTracks = try await repository.removeOrphanedTracks(notIn: trackRatingKeys, forSource: sourceKey)
        let removedGenres = try await repository.removeOrphanedGenres(notIn: genreRatingKeys, forSource: sourceKey)

        if removedArtists + removedAlbums + removedTracks + removedGenres > 0 {
            EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks, \(removedGenres) genres")
        } else {
            EnsembleLogger.debug("✅ No orphaned items found")
        }

        EnsembleLogger.debug("⏱️ Full sync: orphan check \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        EnsembleLogger.debug("⏱️ Full sync complete — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s (\(artists.count) artists, \(albums.count) albums, \(tracks.count) tracks, \(genres.count) genres)")

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)

        progressHandler(1.0)
        return LibrarySyncResult(
            changedArtists: artists.count,
            changedAlbums: albums.count,
            changedTracks: tracks.count,
            changedGenres: genres.count,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks,
            removedGenres: removedGenres
        )
    }

    public func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        // Use server-level identifier for playlists (not library-specific)
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"

        let playlistSyncStart = CFAbsoluteTimeGetCurrent()
        progressHandler(0.1)
        let existingTimestamps = try await repository.fetchPlaylistTimestamps(forSource: serverSourceKey)
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
            )

            _ = try await repository.upsertPlaylist(
                ratingKey: playlist.ratingKey,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.composite,
                isSmart: playlist.smart ?? false,
                duration: playlist.duration,
                trackCount: playlist.leafCount,
                dateAdded: playlist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: playlist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: playlist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: serverSourceKey
            )

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
            try await repository.setPlaylistTracks(trackKeys, forPlaylist: playlist.ratingKey, sourceCompositeKey: serverSourceKey)
            fetchedTrackLists += 1
        }

        // Update last playlist sync timestamp
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.playlistOrphanCheckKey(for: serverSourceKey))

        EnsembleLogger.debug("⏱️ Playlist sync: full sync total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistSyncStart))s (\(playlists.count) playlists, fetchedTracks=\(fetchedTrackLists), skippedTracks=\(skippedTrackLists))")
        progressHandler(1.0)
        return PlaylistSyncResult(changedPlaylists: fetchedTrackLists)
    }

    /// Sync only playlists that changed since last sync (incremental)
    public func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        let syncStart = CFAbsoluteTimeGetCurrent()
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
        let orphanTimestampKey = Self.playlistOrphanCheckKey(for: serverSourceKey)

        // Get last sync timestamp
        let lastSyncTimestamp = UserDefaults.standard.double(forKey: timestampKey)

        // If never synced, fall back to full sync
        guard lastSyncTimestamp > 0 else {
            EnsembleLogger.debug("⚠️ No previous playlist sync found, performing full sync")
            return try await syncPlaylists(to: repository, progressHandler: progressHandler)
        }

        progressHandler(0.1)

        // Fetch existing playlist timestamps for change detection
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let existingTimestamps = try await repository.fetchPlaylistTimestamps(forSource: serverSourceKey)

        // Fetch playlists added or updated since last sync
        let newPlaylists = try await apiClient.getPlaylists(addedAfter: lastSyncTimestamp)
        let updatedPlaylists = try await apiClient.getPlaylists(updatedAfter: lastSyncTimestamp)

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

            _ = try await repository.upsertPlaylist(
                ratingKey: playlist.ratingKey,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.composite,
                isSmart: playlist.smart ?? false,
                duration: playlist.duration,
                trackCount: playlist.leafCount,
                dateAdded: playlist.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: playlist.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: playlist.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: serverSourceKey
            )

            let playlistTracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.ratingKey)
            let trackKeys = playlistTracks.map { $0.ratingKey }
            EnsembleLogger.debug("📋 Incremental sync playlist '\(playlist.title)': \(trackKeys.count) tracks")
            try await repository.setPlaylistTracks(trackKeys, forPlaylist: playlist.ratingKey, sourceCompositeKey: serverSourceKey)
        }

        EnsembleLogger.debug("⏱️ Incremental playlist upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")

        // Orphan removal: fetch inventory only after playlist changes or on a periodic cleanup.
        progressHandler(0.7)
        let shouldCheckOrphans = Self.shouldCheckPlaylistOrphans(
            changedPlaylistCount: changedPlaylists.count,
            lastCheckedAt: UserDefaults.standard.double(forKey: orphanTimestampKey),
            now: Date()
        )
        let removedPlaylists: Int
        if shouldCheckOrphans {
            phaseStart = CFAbsoluteTimeGetCurrent()
            EnsembleLogger.debug("🧹 Checking for orphaned playlists...")
            let playlistInventory = try await apiClient.getPlaylistInventory()
            let validPlaylistKeys = Set(playlistInventory.map { $0.ratingKey })
            progressHandler(0.85)

            removedPlaylists = try await repository.removeOrphanedPlaylists(notIn: validPlaylistKeys, forSource: serverSourceKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: orphanTimestampKey)
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

        // Update last playlist sync timestamp
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)

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

    static func shouldCheckPlaylistOrphans(
        changedPlaylistCount: Int,
        lastCheckedAt: TimeInterval,
        now: Date,
        interval: TimeInterval = playlistOrphanCheckInterval
    ) -> Bool {
        guard changedPlaylistCount == 0 else { return true }
        guard lastCheckedAt > 0 else { return true }
        return now.timeIntervalSince1970 - lastCheckedAt >= interval
    }

    private static func playlistOrphanCheckKey(for serverSourceKey: String) -> String {
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

    public func rateTrack(ratingKey: String, rating: Int?) async throws {
        try await apiClient.rateTrack(ratingKey: ratingKey, rating: rating)
    }

    public func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {
        try await apiClient.reportTimeline(ratingKey: ratingKey, key: key, state: state, time: time, duration: duration)
    }

    public func scrobble(ratingKey: String) async throws {
        try await apiClient.scrobble(ratingKey: ratingKey)
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
        let formatFilters = try await apiClient.getAlbumFormatFilters(sectionKey: sectionKey)
        var formatsByRatingKey: [String: AlbumReleaseFormat] = [:]

        for filter in formatFilters {
            guard let releaseFormat = AlbumReleaseFormat(plexTag: filter.title) else { continue }
            let formattedAlbums = try await apiClient.getArtistAlbums(
                sectionKey: sectionKey,
                artistTitle: artistTitle,
                formatKey: filter.key
            )
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
