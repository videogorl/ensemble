import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Syncs a single Plex server+library to CoreData
public final class PlexMusicSourceSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
    public let sourceIdentifier: MusicSourceIdentifier
    private let apiClient: PlexAPIClient
    /// Library section key used for API calls. Internal for WebSocket-triggered sync matching.
    let sectionKey: String

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
    ) async throws {
        let sourceKey = sourceIdentifier.compositeKey
        #if DEBUG
        EnsembleLogger.debug("🔄 Incremental sync for \(sourceKey) since \(Date(timeIntervalSince1970: timestamp))")
        #endif

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

        // Fetch existing timestamps to skip unchanged items (avoids expensive per-item CoreData upserts)
        progressHandler(0.05)
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let existingArtistTimestamps = try await repository.fetchArtistTimestamps(forSource: sourceKey)
        let existingAlbumTimestamps = try await repository.fetchAlbumTimestamps(forSource: sourceKey)
        let existingTrackTimestamps = try await repository.fetchTrackTimestamps(forSource: sourceKey)
        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental sync: timestamp prefetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s (\(existingArtistTimestamps.count) artists, \(existingAlbumTimestamps.count) albums, \(existingTrackTimestamps.count) tracks)")
        #endif

        // Sync artists added or updated since timestamp
        progressHandler(0.1)
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newArtists = try await apiClient.getArtists(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedArtists = try await apiClient.getArtists(sectionKey: sectionKey, updatedAfter: timestamp)

        // Deduplicate by ratingKey, then filter to items actually changed vs local copy
        var artistMap: [String: PlexArtist] = [:]
        for a in newArtists { artistMap[a.ratingKey] = a }
        for a in updatedArtists { artistMap[a.ratingKey] = a }
        let artistsToSync = artistMap.values.filter { artist in
            guard let serverUpdated = artist.updatedAt else { return true }
            guard let localDate = existingArtistTimestamps[artist.ratingKey] else { return true }
            // Compare as integer seconds to avoid sub-second precision mismatches
            return serverUpdated != Int(localDate.timeIntervalSince1970)
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental sync: artists fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(artistMap.count) from server, \(artistsToSync.count) actually changed")
        #endif
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
        #if DEBUG
        if !artistsToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: artists upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        #endif
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newAlbums = try await apiClient.getAlbums(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedAlbums = try await apiClient.getAlbums(sectionKey: sectionKey, updatedAfter: timestamp)

        // Deduplicate by ratingKey, then filter to items actually changed vs local copy
        var albumMap: [String: PlexAlbum] = [:]
        for a in newAlbums { albumMap[a.ratingKey] = a }
        for a in updatedAlbums { albumMap[a.ratingKey] = a }
        let albumsToSync = albumMap.values.filter { album in
            guard let serverUpdated = album.updatedAt else { return true }
            guard let localDate = existingAlbumTimestamps[album.ratingKey] else { return true }
            // Compare as integer seconds to avoid sub-second precision mismatches
            return serverUpdated != Int(localDate.timeIntervalSince1970)
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental sync: albums fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(albumMap.count) from server, \(albumsToSync.count) actually changed")
        #endif
        phaseStart = CFAbsoluteTimeGetCurrent()
        for album in albumsToSync {
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
                sourceCompositeKey: sourceKey
            )
        }

        // Sync tracks added or updated since timestamp
        progressHandler(0.4)
        #if DEBUG
        if !albumsToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: albums upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        #endif
        phaseStart = CFAbsoluteTimeGetCurrent()
        let newTracks = try await apiClient.getTracks(sectionKey: sectionKey, addedAfter: timestamp)
        let updatedTracks = try await apiClient.getTracks(sectionKey: sectionKey, updatedAfter: timestamp)

        // Deduplicate by ratingKey, then filter to items actually changed vs local copy
        var trackMap: [String: PlexTrack] = [:]
        for t in newTracks { trackMap[t.ratingKey] = t }
        for t in updatedTracks { trackMap[t.ratingKey] = t }
        let tracksToSync = trackMap.values.filter { track in
            guard let serverUpdated = track.updatedAt else { return true }
            guard let localDate = existingTrackTimestamps[track.ratingKey] else { return true }
            // Compare as integer seconds to avoid sub-second precision mismatches
            return serverUpdated != Int(localDate.timeIntervalSince1970)
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental sync: tracks fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(trackMap.count) from server, \(tracksToSync.count) actually changed")
        #endif
        phaseStart = CFAbsoluteTimeGetCurrent()
        for track in tracksToSync {
            _ = try await repository.upsertTrack(
                ratingKey: track.ratingKey,
                key: track.key,
                title: track.title,
                artistName: track.grandparentTitle,
                albumName: track.parentTitle,
                albumRatingKey: track.parentRatingKey,
                trackNumber: track.index,
                discNumber: track.parentIndex,
                duration: track.duration,
                thumbPath: track.thumb ?? track.parentThumb,
                streamKey: track.streamURL,
                dateAdded: track.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: track.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: track.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                rating: track.userRating.map { Int($0) } ?? 0,
                playCount: track.viewCount ?? 0,
                sourceCompositeKey: sourceKey
            )
        }

        // Orphan removal: Fetch server inventory (lightweight) and remove local items not on server
        progressHandler(0.55)
        #if DEBUG
        if !tracksToSync.isEmpty {
            EnsembleLogger.debug("⏱️ Incremental sync: tracks upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        }
        EnsembleLogger.debug("⏱️ Incremental sync: library phase total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        #endif
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
            #if DEBUG
            EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks")
            #endif
        } else {
            #if DEBUG
            EnsembleLogger.debug("✅ No orphaned items found")
            #endif
        }

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)

        progressHandler(1.0)
        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental sync: orphan check took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        EnsembleLogger.debug("✅ Incremental sync complete for \(sourceKey) — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        #endif
    }
    
    public func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws {
        let sourceKey = sourceIdentifier.compositeKey

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

        // Sync artists
        progressHandler(0.1)
        let artists = try await apiClient.getArtists(sectionKey: sectionKey)
        let artistRatingKeys = Set(artists.map { $0.ratingKey })
        for artist in artists {
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

        // Sync albums
        progressHandler(0.3)
        let albums = try await apiClient.getAlbums(sectionKey: sectionKey)
        let albumRatingKeys = Set(albums.map { $0.ratingKey })
        for album in albums {
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
                sourceCompositeKey: sourceKey
            )
        }

        // Sync tracks
        progressHandler(0.5)
        let tracks = try await apiClient.getTracks(sectionKey: sectionKey)
        let trackRatingKeys = Set(tracks.map { $0.ratingKey })
        #if DEBUG
        EnsembleLogger.debug("📀 Syncing \(tracks.count) tracks")
        #endif
        for track in tracks {
            _ = try await repository.upsertTrack(
                ratingKey: track.ratingKey,
                key: track.key,
                title: track.title,
                artistName: track.grandparentTitle,
                albumName: track.parentTitle,
                albumRatingKey: track.parentRatingKey,
                trackNumber: track.index,
                discNumber: track.parentIndex,
                duration: track.duration,
                thumbPath: track.thumb ?? track.parentThumb,
                streamKey: track.streamURL,
                dateAdded: track.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: track.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: track.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                rating: track.userRating.map { Int($0) } ?? 0,
                playCount: track.viewCount ?? 0,
                sourceCompositeKey: sourceKey
            )
        }

        // Sync genres
        progressHandler(0.7)
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

        // Remove orphaned items (deleted/merged on server but still in local DB)
        progressHandler(0.85)
        #if DEBUG
        EnsembleLogger.debug("🧹 Checking for orphaned items...")
        #endif
        let removedArtists = try await repository.removeOrphanedArtists(notIn: artistRatingKeys, forSource: sourceKey)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumRatingKeys, forSource: sourceKey)
        let removedTracks = try await repository.removeOrphanedTracks(notIn: trackRatingKeys, forSource: sourceKey)
        let removedGenres = try await repository.removeOrphanedGenres(notIn: genreRatingKeys, forSource: sourceKey)

        if removedArtists + removedAlbums + removedTracks + removedGenres > 0 {
            #if DEBUG
            EnsembleLogger.debug("🧹 Removed orphans: \(removedArtists) artists, \(removedAlbums) albums, \(removedTracks) tracks, \(removedGenres) genres")
            #endif
        } else {
            #if DEBUG
            EnsembleLogger.debug("✅ No orphaned items found")
            #endif
        }

        // Update last sync timestamp
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)

        progressHandler(1.0)
    }
    
    public func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws {
        // Use server-level identifier for playlists (not library-specific)
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"

        let playlistSyncStart = CFAbsoluteTimeGetCurrent()
        progressHandler(0.1)
        let playlists = try await apiClient.getPlaylists()
        #if DEBUG
        EnsembleLogger.debug("⏱️ Playlist sync: fetched \(playlists.count) playlists in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistSyncStart))s")
        #endif

        for (index, playlist) in playlists.enumerated() {
            let playlistProgress = 0.1 + (0.8 * Double(index) / Double(playlists.count))
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
            #if DEBUG
            EnsembleLogger.debug("📋 Syncing playlist '\(playlist.title)': \(trackKeys.count) tracks")
            #endif
            if trackKeys.count > 0 {
                #if DEBUG
                EnsembleLogger.debug("📋 First track key: \(trackKeys[0])")
                #endif
            }
            try await repository.setPlaylistTracks(trackKeys, forPlaylist: playlist.ratingKey, sourceCompositeKey: serverSourceKey)
        }

        // Update last playlist sync timestamp
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)

        #if DEBUG
        EnsembleLogger.debug("⏱️ Playlist sync: full sync total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistSyncStart))s (\(playlists.count) playlists)")
        #endif
        progressHandler(1.0)
    }

    /// Sync only playlists that changed since last sync (incremental)
    public func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws {
        let syncStart = CFAbsoluteTimeGetCurrent()
        let serverSourceKey = "\(sourceIdentifier.type.rawValue):\(sourceIdentifier.accountId):\(sourceIdentifier.serverId)"
        let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"

        // Get last sync timestamp
        let lastSyncTimestamp = UserDefaults.standard.double(forKey: timestampKey)

        // If never synced, fall back to full sync
        guard lastSyncTimestamp > 0 else {
            #if DEBUG
            EnsembleLogger.debug("⚠️ No previous playlist sync found, performing full sync")
            #endif
            try await syncPlaylists(to: repository, progressHandler: progressHandler)
            return
        }

        progressHandler(0.1)

        // Fetch existing playlist timestamps for change detection
        var phaseStart = CFAbsoluteTimeGetCurrent()
        let existingTimestamps = try await repository.fetchPlaylistTimestamps(forSource: serverSourceKey)

        // Fetch playlists added or updated since last sync
        let newPlaylists = try await apiClient.getPlaylists(addedAfter: lastSyncTimestamp)
        let updatedPlaylists = try await apiClient.getPlaylists(updatedAfter: lastSyncTimestamp)

        // Deduplicate by ratingKey, then filter to items actually changed vs local copy
        var playlistMap: [String: PlexPlaylist] = [:]
        for playlist in newPlaylists { playlistMap[playlist.ratingKey] = playlist }
        for playlist in updatedPlaylists { playlistMap[playlist.ratingKey] = playlist }
        let changedPlaylists = playlistMap.values.filter { playlist in
            guard let serverUpdated = playlist.updatedAt else { return true }
            guard let localDate = existingTimestamps[playlist.ratingKey] else { return true }
            // Compare as integer seconds to avoid sub-second precision mismatches
            return serverUpdated != Int(localDate.timeIntervalSince1970)
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental playlist fetch took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s — \(playlistMap.count) from server, \(changedPlaylists.count) actually changed")
        #endif

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
            #if DEBUG
            EnsembleLogger.debug("📋 Incremental sync playlist '\(playlist.title)': \(trackKeys.count) tracks")
            #endif
            try await repository.setPlaylistTracks(trackKeys, forPlaylist: playlist.ratingKey, sourceCompositeKey: serverSourceKey)
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental playlist upsert took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        #endif

        // Orphan removal: Fetch playlist inventory and remove deleted playlists
        progressHandler(0.7)
        phaseStart = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        EnsembleLogger.debug("🧹 Checking for orphaned playlists...")
        #endif
        let playlistInventory = try await apiClient.getPlaylistInventory()
        let validPlaylistKeys = Set(playlistInventory.map { $0.ratingKey })
        progressHandler(0.85)

        let removedPlaylists = try await repository.removeOrphanedPlaylists(notIn: validPlaylistKeys, forSource: serverSourceKey)
        if removedPlaylists > 0 {
            #if DEBUG
            EnsembleLogger.debug("🧹 Removed \(removedPlaylists) orphaned playlists")
            #endif
        } else {
            #if DEBUG
            EnsembleLogger.debug("✅ No orphaned playlists found")
            #endif
        }

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental playlist orphan check took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - phaseStart))s")
        #endif

        // Update last playlist sync timestamp
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)

        #if DEBUG
        EnsembleLogger.debug("⏱️ Incremental playlist sync complete — total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - syncStart))s")
        #endif

        progressHandler(1.0)
    }

public func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality
    ) async throws -> URL {
        #if DEBUG
        EnsembleLogger.debug("🎵 PlexProvider.getStreamURL: ratingKey=\(trackRatingKey), quality=\(quality.rawValue)")
        #endif

        // Playback path uses direct stream URLs for maximum AVPlayer compatibility.
        if let trackStreamKey, !trackStreamKey.isEmpty {
            #if DEBUG
            EnsembleLogger.debug("🔍 PlexProvider: Using cached stream key: \(trackStreamKey)")
            #endif
            return try await apiClient.getStreamURL(trackKey: trackStreamKey)
        }

        #if DEBUG
        EnsembleLogger.debug("⚠️ PlexProvider: No cached stream key, fetching track metadata")
        #endif
        guard let track = try await apiClient.getTrack(trackKey: trackRatingKey),
              let streamKey = track.streamURL else {
            #if DEBUG
            EnsembleLogger.debug("❌ PlexProvider: Could not get stream URL from track metadata")
            #endif
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
        let plexAlbums = try await apiClient.getArtistAlbums(artistKey: artistKey)
        return plexAlbums.map { Album(from: $0) }
    }

    public func getArtistTracks(artistKey: String) async throws -> [Track] {
        let plexTracks = try await apiClient.getArtistTracks(artistKey: artistKey)
        return plexTracks.map { Track(from: $0, sourceKey: sourceIdentifier.compositeKey) }
    }
}
