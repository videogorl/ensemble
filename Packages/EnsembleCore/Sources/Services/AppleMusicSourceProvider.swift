#if os(iOS)
import EnsemblePersistence
import Foundation
import MediaPlayer
import MusicKit

@available(iOS 18, *)
public actor AppleMusicSourceProvider:
    MusicSourceSyncProvider,
    MusicSourcePlaybackResolving,
    MusicSourceRatingMutating,
    MusicSourcePlaylistReconciling,
    MusicSourcePlaybackReporting,
    MusicSourceDetailProviding
{
    public nonisolated let sourceIdentifier = MusicSourceIdentifier.appleMusic
    static let librarySongsPath = "/v1/me/library/songs?limit=100&extend=inFavorites&include=albums,artists,catalog"
    static let libraryPlaylistsPath = "/v1/me/library/playlists?limit=100&include=catalog"
    static let authoritativeLibraryInventoryInterval: TimeInterval = 24 * 60 * 60
    private static let deviceLibraryRevisionKey = "sources.appleMusic.libraryInventory.deviceRevision"
    private static let authoritativeLibraryInventoryDateKey = "sources.appleMusic.libraryInventory.authoritativeDate"
    private var catalogIDsByLibraryID: [String: String] = [:]
    private var pendingFavoriteCatalogIDs = Set<String>()

    public init() {}

    public func getHomeHubs(limit: Int) async throws -> [Hub] {
        (try await getHomeHubResult(limit: limit)).hubs
    }

    public func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult {
        async let recentlyAdded = Self.availableHub(kind: .recentlyAdded, named: "Recently Added") {
            try await Self.recentlyAddedHub(limit: limit)
        }
        async let recentlyPlayed = Self.availableHub(kind: .recentlyPlayed, named: "Recently Played") {
            try await Self.recentlyPlayedHub(limit: limit)
        }
        async let mostPlayed = Self.availableHub(kind: .mostPlayed, named: "Most Played") {
            try await Self.mostPlayedHub(limit: limit)
        }
        let results = await [recentlyAdded, recentlyPlayed, mostPlayed]
        return MusicSourceHubFetchResult(
            hubs: results.compactMap(\.hub),
            failedSemanticKinds: Set(results.compactMap(\.failedKind))
        )
    }

    public func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        try await syncLibraryAuthoritatively(
            observedDeviceRevision: Self.currentDeviceLibraryRevision(),
            to: repository,
            progressHandler: progressHandler
        )
    }

    private func syncLibraryAuthoritatively(
        observedDeviceRevision: Date?,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let sourceKey = sourceIdentifier.compositeKey
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: sourceIdentifier.type.rawValue,
            accountId: sourceIdentifier.accountId,
            serverId: sourceIdentifier.serverId,
            libraryId: sourceIdentifier.libraryId,
            displayName: "Apple Music",
            accountName: "This Device"
        )

        progressHandler(0.1)
        async let nativeMetadataFetch = Self.fetchNativeLibraryMetadata()
        let fetchedSongs: [LibrarySong] = try await fetchAll(path: Self.librarySongsPath)
        var seenSongIDs = Set<String>()
        let songs = fetchedSongs.filter { seenSongIDs.insert($0.id).inserted }
        let nativeMetadata = try await nativeMetadataFetch
        progressHandler(0.5)

        catalogIDsByLibraryID = Dictionary(uniqueKeysWithValues: songs.compactMap { song in
            song.catalogID.map { (song.id, $0) }
        })
        pendingFavoriteCatalogIDs.subtract(songs.compactMap { song in
            song.attributes.inFavorites == true ? song.catalogID : nil
        })

        let artists = Self.artistUpsertInputs(
            from: songs,
            dateAddedByLibraryID: nativeMetadata.artistDateAddedByID,
            songMetadataByLibraryID: nativeMetadata.songsByID
        )
        let albums = Self.albumUpsertInputs(
            from: songs,
            dateAddedByLibraryID: nativeMetadata.albumDateAddedByID,
            songMetadataByLibraryID: nativeMetadata.songsByID
        )
        let existingArtists = try await repository.fetchArtistSyncMetadata(forSource: sourceKey)
        let existingAlbums = try await repository.fetchAlbumSyncMetadata(forSource: sourceKey)
        let existingTracks = try await repository.fetchTrackSyncMetadata(forSource: sourceKey)
        let tracks = songs.map { song in
            Self.trackUpsertInput(
                song,
                metadata: nativeMetadata.songsByID[song.id],
                existing: existingTracks[song.id],
                isFavorite: song.attributes.inFavorites == true
                    || song.catalogID.map(pendingFavoriteCatalogIDs.contains) == true
            )
        }

        let changedArtists = artists.filter { existingArtists[$0.ratingKey]?.matches($0) != true }
        let changedAlbums = albums.filter { existingAlbums[$0.ratingKey]?.matches($0) != true }
        let changedTracks = tracks.filter { existingTracks[$0.ratingKey]?.matches($0) != true }
        let datedTracks = tracks.lazy.filter { $0.dateAdded != nil }.count
        let datedAlbums = albums.lazy.filter { $0.dateAdded != nil }.count
        let datedArtists = artists.lazy.filter { $0.dateAdded != nil }.count
        let lastPlayedTracks = tracks.lazy.filter { $0.lastPlayed != nil }.count
        let playedTracks = tracks.lazy.filter { ($0.playCount ?? 0) > 0 }.count
        let matchedSongs = songs.lazy.filter { nativeMetadata.songsByID[$0.id] != nil }.count
        EnsembleLogger.debug(
            "🎵 Apple Music inventory \(songs.count) songs; native \(nativeMetadata.elapsedMilliseconds)ms matched=\(matchedSongs)/\(songs.count) dated=\(datedTracks)/\(datedAlbums)/\(datedArtists) track/album/artist played=\(lastPlayedTracks) last/\(playedTracks) counted; writing \(changedArtists.count) artists, \(changedAlbums.count) albums, \(changedTracks.count) tracks"
        )

        try await repository.batchUpsertArtists(changedArtists, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums(changedAlbums, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks(changedTracks, sourceCompositeKey: sourceKey)
        progressHandler(0.85)

        let artistKeys = Set(artists.map(\.ratingKey))
        let albumKeys = Set(albums.map(\.ratingKey))
        let trackKeys = Set(tracks.map(\.ratingKey))
        let removedArtists = try await repository.removeOrphanedArtists(notIn: artistKeys, forSource: sourceKey)
        let removedAlbums = try await repository.removeOrphanedAlbums(notIn: albumKeys, forSource: sourceKey)
        let removedTracks = try await repository.removeOrphanedTracks(notIn: trackKeys, forSource: sourceKey)
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)
        Self.recordAuthoritativeLibraryInventory(
            observedDeviceRevision: observedDeviceRevision,
            completedAt: Date()
        )
        progressHandler(1)

        return LibrarySyncResult(
            changedArtists: changedArtists.count,
            changedAlbums: changedAlbums.count,
            changedTracks: changedTracks.count,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks
        )
    }

    static func artistUpsertInputs(
        from songs: [LibrarySong],
        dateAddedByLibraryID: [String: Date] = [:],
        songMetadataByLibraryID: [String: NativeLibrarySongMetadata] = [:]
    ) -> [ArtistUpsertInput] {
        Dictionary(grouping: songs, by: \.artistKey).compactMap { key, songs -> ArtistUpsertInput? in
            guard let song = songs.first else { return nil }
            return ArtistUpsertInput(
                ratingKey: key,
                key: key,
                name: song.attributes.artistName ?? "Unknown Artist",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: song.artistLibraryID.flatMap { dateAddedByLibraryID[$0] }
                    ?? Self.earliestSongAddedDate(
                        in: songs,
                        metadataByLibraryID: songMetadataByLibraryID
                    ),
                dateModified: nil,
                updatesDateAdded: true
            )
        }
    }

    static func albumUpsertInputs(
        from songs: [LibrarySong],
        dateAddedByLibraryID: [String: Date] = [:],
        songMetadataByLibraryID: [String: NativeLibrarySongMetadata] = [:]
    ) -> [AlbumUpsertInput] {
        Dictionary(grouping: songs, by: \.albumKey).compactMap { key, songs -> AlbumUpsertInput? in
            guard let song = songs.first else { return nil }
            return AlbumUpsertInput(
                ratingKey: key,
                key: key,
                title: song.attributes.albumName ?? "Unknown Album",
                artistName: song.attributes.artistName,
                albumArtist: song.attributes.artistName,
                artistRatingKey: song.artistKey,
                summary: nil,
                thumbPath: song.artworkURL,
                artPath: nil,
                year: song.year,
                trackCount: songs.count,
                dateAdded: song.albumLibraryID.flatMap { dateAddedByLibraryID[$0] }
                    ?? Self.earliestSongAddedDate(
                        in: songs,
                        metadataByLibraryID: songMetadataByLibraryID
                    ),
                dateModified: nil,
                rating: nil,
                genreNames: song.attributes.genreNames?.joined(separator: ", "),
                updatesDateAdded: true
            )
        }
    }

    private static func earliestSongAddedDate(
        in songs: [LibrarySong],
        metadataByLibraryID: [String: NativeLibrarySongMetadata]
    ) -> Date? {
        songs.compactMap {
            metadataByLibraryID[$0.id]?.dateAdded ?? $0.dateAdded
        }.min()
    }

    public func syncLibraryIncremental(
        since _: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        let observedDeviceRevision = Self.currentDeviceLibraryRevision()
        let state = Self.libraryInventoryState()
        let plan = Self.libraryInventoryPlan(
            observedDeviceRevision: observedDeviceRevision,
            state: state,
            now: Date()
        )

        switch plan {
        case .reuseAuthoritativeInventory:
            EnsembleLogger.debug(
                "🎵 Apple Music device library revision unchanged; reusing the recent authoritative inventory"
            )
            try await repository.updateMusicSourceSyncTimestamp(compositeKey: sourceIdentifier.compositeKey)
            progressHandler(1)
            return LibrarySyncResult()
        case .fetchAuthoritativeInventory(let reason):
            EnsembleLogger.debug(
                "🎵 Apple Music authoritative library inventory required reason=\(reason.rawValue)"
            )
            return try await syncLibraryAuthoritatively(
                observedDeviceRevision: observedDeviceRevision,
                to: repository,
                progressHandler: progressHandler
            )
        }
    }

    enum LibraryInventoryRefreshReason: String, Equatable {
        case noTrustedBaseline
        case deviceRevisionUnavailable
        case deviceRevisionChanged
        case deviceRevisionRegressed
        case localClockRegressed
        case periodicReconciliationDue
    }

    enum LibraryInventoryPlan: Equatable {
        case reuseAuthoritativeInventory
        case fetchAuthoritativeInventory(reason: LibraryInventoryRefreshReason)
    }

    struct LibraryInventoryState: Equatable {
        let deviceRevision: Date?
        let authoritativeInventoryDate: Date?
    }

    static func libraryInventoryPlan(
        observedDeviceRevision: Date?,
        state: LibraryInventoryState,
        now: Date,
        reconciliationInterval: TimeInterval = authoritativeLibraryInventoryInterval
    ) -> LibraryInventoryPlan {
        guard let observedDeviceRevision else {
            return .fetchAuthoritativeInventory(reason: .deviceRevisionUnavailable)
        }
        guard let savedRevision = state.deviceRevision,
              let inventoryDate = state.authoritativeInventoryDate else {
            return .fetchAuthoritativeInventory(reason: .noTrustedBaseline)
        }
        guard observedDeviceRevision >= savedRevision else {
            return .fetchAuthoritativeInventory(reason: .deviceRevisionRegressed)
        }
        guard observedDeviceRevision == savedRevision else {
            return .fetchAuthoritativeInventory(reason: .deviceRevisionChanged)
        }

        let inventoryAge = now.timeIntervalSince(inventoryDate)
        guard inventoryAge >= 0 else {
            return .fetchAuthoritativeInventory(reason: .localClockRegressed)
        }
        guard inventoryAge < reconciliationInterval else {
            return .fetchAuthoritativeInventory(reason: .periodicReconciliationDue)
        }
        return .reuseAuthoritativeInventory
    }

    static func libraryInventoryState(
        defaults: UserDefaults = .standard
    ) -> LibraryInventoryState {
        LibraryInventoryState(
            deviceRevision: defaults.object(forKey: deviceLibraryRevisionKey) as? Date,
            authoritativeInventoryDate: defaults.object(forKey: authoritativeLibraryInventoryDateKey) as? Date
        )
    }

    static func recordAuthoritativeLibraryInventory(
        observedDeviceRevision: Date?,
        completedAt: Date,
        defaults: UserDefaults = .standard
    ) {
        if let observedDeviceRevision {
            defaults.set(observedDeviceRevision, forKey: deviceLibraryRevisionKey)
        } else {
            defaults.removeObject(forKey: deviceLibraryRevisionKey)
        }
        defaults.set(completedAt, forKey: authoritativeLibraryInventoryDateKey)
    }

    static func clearLibraryInventoryState(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: deviceLibraryRevisionKey)
        defaults.removeObject(forKey: authoritativeLibraryInventoryDateKey)
    }

    private static func currentDeviceLibraryRevision() -> Date? {
        let revision = MPMediaLibrary.default().lastModifiedDate
        return revision.timeIntervalSince1970 > 0 ? revision : nil
    }

    public func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        try await syncPlaylists(
            to: repository,
            refreshAllBodies: false,
            progressHandler: progressHandler
        )
    }

    private func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        refreshAllBodies: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        let sourceKey = sourceIdentifier.compositeKey
        let libraryPlaylists: [LibraryPlaylist] = try await fetchAll(path: Self.libraryPlaylistsPath)
        let libraryPlaylistsByID = Dictionary(
            libraryPlaylists.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let existingStates = try await repository.fetchPlaylistSyncStates(forSource: sourceKey)
        var playlists: [MusicKit.Playlist] = []
        var seenPlaylistIDs = Set<String>()
        var offset = 0
        while true {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            request.offset = offset
            let page = Array(try await request.response().items)
            playlists.append(contentsOf: page.filter {
                seenPlaylistIDs.insert(String(describing: $0.id)).inserted
            })
            guard page.count == request.limit else { break }
            offset += page.count
        }
        let musicKitPlaylistIDs = Set(playlists.map { String(describing: $0.id) })
        let restOnlyPlaylists = Self.restOnlyPlaylists(
            libraryPlaylists,
            excluding: musicKitPlaylistIDs
        )
        let validIDs = Set(libraryPlaylistsByID.keys).union(musicKitPlaylistIDs)
        let inventoryCount = playlists.count + restOnlyPlaylists.count
        var changedPlaylists = 0
        var fetchedBodies = 0
        var rewrittenBodies = 0
        var headerWrites = 0
        var ignoredStaleBodies = 0

        for (index, playlist) in playlists.enumerated() {
            let id = String(describing: playlist.id)
            let libraryPlaylist = libraryPlaylistsByID[id]
            let canEdit = libraryPlaylist?.attributes.canEdit == true
            let artworkURL = libraryPlaylist?.attributes.artwork?.url
            let existing = existingStates[id]
            let effectiveModifiedAt = Self.effectivePlaylistModifiedDate(
                musicKit: playlist.lastModifiedDate,
                library: libraryPlaylist?.dateModified
            )
            if Self.shouldRefreshPlaylistBody(
                existing: existing,
                modifiedAt: effectiveModifiedAt,
                refreshAllBodies: refreshAllBodies
            ) {
                let result: PlaylistPersistenceResult
                do {
                    if let libraryPlaylist {
                        result = try await Self.withNativePlaylistBodyFallback {
                            try await persistLibraryPlaylist(
                                libraryPlaylist,
                                musicKitPlaylist: playlist,
                                existing: existing,
                                to: repository
                            )
                        } native: { restError in
                            EnsembleLogger.info(
                                "🎵 Apple Music REST playlist body unavailable; trying MusicKit id=\(id) title=\(playlist.name) \(Self.requestErrorDetails(restError))"
                            )
                            do {
                                guard let result = try await persistPlaylist(
                                    playlist,
                                    artworkURL: artworkURL,
                                    canEdit: canEdit,
                                    dateModified: effectiveModifiedAt,
                                    existing: existing,
                                    to: repository
                                ) else { throw PlaylistMutationError.incompletePlaylistContents }
                                return result
                            } catch {
                                EnsembleLogger.error(
                                    "🎵 Apple Music native playlist fallback failed id=\(id) title=\(playlist.name) \(Self.requestErrorDetails(error))"
                                )
                                throw error
                            }
                        }
                    } else {
                        guard let persisted = try await persistPlaylist(
                            playlist,
                            artworkURL: artworkURL,
                            canEdit: canEdit,
                            existing: existing,
                            to: repository
                        ) else { throw PlaylistMutationError.incompletePlaylistContents }
                        result = persisted
                    }
                } catch {
                    Self.logPlaylistBodyFailure(id: id, title: playlist.name, error: error)
                    throw error
                }
                fetchedBodies += 1
                changedPlaylists += result.plan.hasChanges ? 1 : 0
                headerWrites += result.plan.writesHeader ? 1 : 0
                rewrittenBodies += result.plan.writesBody ? 1 : 0
                ignoredStaleBodies += result.plan.ignoresStaleResponse ? 1 : 0
            } else {
                let input = Self.playlistInput(
                    playlist,
                    artworkURL: artworkURL,
                    canEdit: canEdit,
                    dateModified: effectiveModifiedAt,
                    duration: existing?.duration ?? 0,
                    trackCount: existing?.trackCount ?? 0
                )
                if existing?.headerMatches(input) != true {
                    _ = try await repository.upsertPlaylist(input, sourceCompositeKey: sourceKey)
                    changedPlaylists += 1
                    headerWrites += 1
                }
            }
            progressHandler(Double(index + 1) / Double(max(inventoryCount, 1)))
        }

        for (index, playlist) in restOnlyPlaylists.enumerated() {
            let existing = existingStates[playlist.id]
            if Self.shouldRefreshPlaylistBody(
                existing: existing,
                modifiedAt: playlist.dateModified,
                refreshAllBodies: refreshAllBodies
            ) {
                let result: PlaylistPersistenceResult
                do {
                    result = try await persistLibraryPlaylist(
                        playlist,
                        existing: existing,
                        to: repository
                    )
                } catch {
                    Self.logPlaylistBodyFailure(
                        id: playlist.id,
                        title: playlist.attributes.name ?? "Untitled Playlist",
                        error: error
                    )
                    throw error
                }
                fetchedBodies += 1
                changedPlaylists += result.plan.hasChanges ? 1 : 0
                headerWrites += result.plan.writesHeader ? 1 : 0
                rewrittenBodies += result.plan.writesBody ? 1 : 0
                ignoredStaleBodies += result.plan.ignoresStaleResponse ? 1 : 0
            } else {
                let input = Self.playlistInput(
                    playlist,
                    duration: existing?.duration ?? 0,
                    trackCount: existing?.trackCount ?? 0
                )
                if existing?.headerMatches(input) != true {
                    _ = try await repository.upsertPlaylist(input, sourceCompositeKey: sourceKey)
                    changedPlaylists += 1
                    headerWrites += 1
                }
            }
            progressHandler(Double(playlists.count + index + 1) / Double(max(inventoryCount, 1)))
        }

        EnsembleLogger.debug(
            "🎵 Apple Music playlist inventory \(validIDs.count); fetched \(fetchedBodies) bodies, rewrote \(rewrittenBodies) bodies, wrote \(headerWrites) headers, ignored \(ignoredStaleBodies) stale responses"
        )
        let removed = try await repository.removeOrphanedPlaylists(notIn: validIDs, forSource: sourceKey)
        progressHandler(1)
        return PlaylistSyncResult(changedPlaylists: changedPlaylists, removedPlaylists: removed)
    }

    public func reconcilePlaylist(
        id: String,
        minimumTrackCount: Int,
        requiredTracks: [Track],
        to repository: PlaylistRepositoryProtocol
    ) async throws -> Int? {
        try await persistPlaylist(
            try await libraryPlaylist(id: id),
            artworkURL: nil,
            canEdit: true,
            minimumTrackCount: minimumTrackCount,
            requiredTracks: requiredTracks,
            to: repository
        ).map(\.trackCount)
    }

    public func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        forceOrphanCheck _: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        try await syncPlaylists(
            to: repository,
            refreshAllBodies: false,
            progressHandler: progressHandler
        )
    }

    public func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        throw AppleMusicSourceError.musicKitPlaybackRequired
    }

    public func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        guard let path else { return nil }
        let resizedPath = path.replacingOccurrences(of: "{w}", with: "\(size)")
            .replacingOccurrences(of: "{h}", with: "\(size)")
        guard let sourceURL = URL(string: resizedPath), sourceURL.scheme == "musicKit" else {
            return URL(string: resizedPath)
        }
        guard let assetPath = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "aat" })?.value else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "is1-ssl.mzstatic.com"
        components.path = "/image/thumb/\(assetPath)/\(size)x\(size)bb.jpg"
        return components.url
    }

    public func rateTrack(
        _ track: Track,
        rating: Int?
    ) async throws -> MusicSourceRatingMutationEffects {
        guard let rating, rating > 0 else { throw AppleMusicSourceError.favoriteRemovalUnsupported }
        guard let catalogID = track.appleMusicCatalogID ?? catalogIDsByLibraryID[track.id] else {
            throw MusicSourceRoutingError.capabilityUnavailable(
                sourceKey: track.sourceCompositeKey ?? sourceIdentifier.compositeKey,
                capability: "favorites for this library-only song"
            )
        }
        try await favorite(catalogID: catalogID)
        return .none
    }

    public func favorite(catalogID: String) async throws {
        _ = try await request(path: try Self.favoritePath(catalogID: catalogID), method: "POST")
        pendingFavoriteCatalogIDs.insert(catalogID)
    }

    static func favoritePath(catalogID: String) throws -> String {
        var components = URLComponents()
        components.path = "/v1/me/favorites"
        components.queryItems = [URLQueryItem(name: "ids[songs]", value: catalogID)]
        guard let path = components.string else { throw URLError(.badURL) }
        return path
    }

    static func continuationPath(_ next: String, preservingQueryFrom initial: String) -> String {
        guard var components = URLComponents(string: next),
              let initialItems = URLComponents(string: initial)?.queryItems else { return next }
        let existingNames = Set((components.queryItems ?? []).map(\.name))
        components.queryItems = (components.queryItems ?? []) + initialItems.filter { !existingNames.contains($0.name) }
        return components.string ?? next
    }

    public func addToLibrary(catalogID: String) async throws {
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(catalogID)
        )
        guard let song = try await request.response().items.first else {
            throw AppleMusicSourceError.catalogSongNotFound
        }
        try await MusicLibrary.shared.add(song)
    }

    public func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
        let songs = try await catalogSongs(for: tracks)
        guard !songs.isEmpty || tracks.isEmpty else { throw PlaylistMutationError.emptySelection }
        let playlist = try await MusicLibrary.shared.createPlaylist(name: title, items: songs)
        let playlistID = String(describing: playlist.id)
        Playlist.markAppleMusicPlaylistCreated(id: playlistID)
        return Playlist(
            id: playlistID,
            key: playlistID,
            title: title,
            trackCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            sourceCompositeKey: sourceIdentifier.compositeKey,
            actionCapabilities: Self.playlistActionCapabilities(
                id: playlistID,
                isSmart: false,
                canEdit: true
            )
        )
    }

    public func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
        let ids = tracks.compactMap(\.appleMusicCatalogID)
        guard ids.count == tracks.count else { throw PlaylistMutationError.invalidSource }
        guard !ids.isEmpty else { return 0 }
        let encodedID = playlistID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistID
        _ = try await request(
            path: "/v1/me/library/playlists/\(encodedID)/tracks",
            method: "POST",
            body: ["data": ids.map { ["id": $0, "type": "songs"] }]
        )
        return ids.count
    }

    public func renamePlaylist(_ playlistID: String, title: String) async throws {
        _ = try await MusicLibrary.shared.edit(try await libraryPlaylist(id: playlistID), name: title)
    }

    public func deletePlaylist(_ playlistID: String) async throws {
        throw AppleMusicSourceError.playlistDeletionUnsupported
    }

    public func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
        let playlist = try await libraryPlaylist(id: playlistID)
        let songs = try await catalogSongs(for: tracks)
        guard songs.count == tracks.count else { throw PlaylistMutationError.invalidSource }
        _ = try await MusicLibrary.shared.edit(playlist, items: songs)
    }

    public func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
    public func scrobble(ratingKey: String) async throws {}
    public func getAlbumTracks(albumKey: String) async throws -> [Track] {
        var libraryRequest = MusicLibraryRequest<MusicKit.Album>()
        libraryRequest.filter(matching: \.id, equalTo: MusicItemID(albumKey))
        if let libraryAlbum = try await libraryRequest.response().items.first {
            let detailed = try await libraryAlbum.with([.tracks])
            return detailed.tracks?.compactMap { item in
                guard case .song(let song) = item else { return nil }
                return Self.domainTrack(song, key: Self.playlistTrackKey(song))
            } ?? []
        }

        var request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(albumKey))
        request.properties = [.tracks]
        guard let album = try await request.response().items.first else { return [] }
        return album.tracks?.compactMap { item in
            guard case .song(let song) = item else { return nil }
            return Self.domainTrack(song, key: Self.catalogTrackKey(song))
        } ?? []
    }

    public func getArtistAlbums(artistKey: String) async throws -> [Album] {
        if artistKey.hasPrefix("apple-artist:") {
            return []
        }

        var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(artistKey))
        request.properties = [.albums]
        guard let artist = try await request.response().items.first else { return [] }
        var albums = artist.albums ?? []
        while albums.hasNextBatch, let next = try await albums.nextBatch(limit: 100) {
            albums += next
        }
        return albums.map { Self.domainAlbum($0, artistID: artistKey) }
    }

    public func getArtistTracks(artistKey: String) async throws -> [Track] {
        let albums = try await getArtistAlbums(artistKey: artistKey)
        var tracks: [Track] = []
        for album in albums.prefix(20) {
            tracks.append(contentsOf: try await getAlbumTracks(albumKey: album.id))
        }
        return tracks
    }

    public func getCatalogPlaylistTracks(playlistID: String) async throws -> [Track] {
        var request = MusicCatalogResourceRequest<MusicKit.Playlist>(
            matching: \.id,
            equalTo: MusicItemID(playlistID)
        )
        request.properties = [.tracks]
        guard let playlist = try await request.response().items.first else { return [] }
        return playlist.tracks?.compactMap { item in
            guard case .song(let song) = item else { return nil }
            return Self.domainTrack(song, key: Self.catalogTrackKey(song))
        } ?? []
    }

    private func fetchAll<Resource: Decodable>(path: String) async throws -> [Resource] {
        let initialPath = path
        var path: String? = path
        var result: [Resource] = []
        while let current = path {
            let data: Data
            do {
                data = try await request(path: current)
            } catch {
                Self.logDataRequestFailure(path: current, error: error)
                throw error
            }
            let page = try JSONDecoder().decode(Page<Resource>.self, from: data)
            result.append(contentsOf: page.data)
            path = page.next.map { Self.continuationPath($0, preservingQueryFrom: initialPath) }
        }
        return result
    }

    private nonisolated static func fetchNativeLibraryMetadata() async throws
        -> NativeLibraryMetadataSnapshot
    {
        let startedAt = Date()
        async let songsFetch = fetchNativeLibraryItems(Song.self) {
            NativeLibrarySongMetadata(
                itemID: $0.id.rawValue,
                dateAdded: $0.libraryAddedDate,
                lastPlayed: $0.lastPlayedDate,
                playCount: $0.playCount
            )
        }
        async let albumsFetch = fetchNativeLibraryItems(MusicKit.Album.self) {
            NativeLibraryDateMetadata(itemID: $0.id.rawValue, dateAdded: $0.libraryAddedDate)
        }
        async let artistsFetch = fetchNativeLibraryItems(MusicKit.Artist.self) {
            NativeLibraryDateMetadata(itemID: $0.id.rawValue, dateAdded: $0.libraryAddedDate)
        }
        let (songs, albums, artists) = try await (songsFetch, albumsFetch, artistsFetch)
        return NativeLibraryMetadataSnapshot(
            songs: songs,
            albums: albums,
            artists: artists,
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        )
    }

    private nonisolated static func fetchNativeLibraryItems<Item, Output>(
        _: Item.Type,
        transform: @Sendable (Item) -> Output
    ) async throws -> [Output]
    where Item: MusicLibraryRequestable, Output: Sendable {
        var result: [Output] = []
        var seenIDs = Set<MusicItemID>()
        var offset = 0
        while true {
            var request = MusicLibraryRequest<Item>()
            request.limit = 100
            request.offset = offset
            let page = Array(try await request.response().items)
            result.append(contentsOf: page.compactMap {
                seenIDs.insert($0.id).inserted ? transform($0) : nil
            })
            guard page.count == request.limit else { break }
            offset += page.count
        }
        return result
    }

    private static func logPlaylistBodyFailure(id: String, title: String, error: Error) {
        EnsembleLogger.error(
            "🎵 Apple Music playlist body failed id=\(id) title=\(title) \(requestErrorDetails(error))"
        )
    }

    private static func logDataRequestFailure(path: String, error: Error) {
        EnsembleLogger.error(
            "🎵 Apple Music data request failed path=\(path) \(requestErrorDetails(error))"
        )
    }

    private static func requestErrorDetails(_ error: Error) -> String {
        guard let requestError = error as? MusicDataRequest.Error else {
            return "type=\(String(reflecting: type(of: error))) message=\(error.localizedDescription)"
        }
        return "status=\(requestError.status) code=\(requestError.code) responseStatus=\(requestError.originalResponse.urlResponse.statusCode) title=\(requestError.title) detail=\(requestError.detailText) source=\(String(describing: requestError.source))"
    }

    private static func domainTrack(_ song: Song, key: String) -> Track {
        Track(
            id: String(describing: song.id),
            key: key,
            title: song.title,
            artistName: song.artistName,
            albumArtistName: song.artistName,
            albumName: song.albumTitle,
            artistRatingKey: song.artistURL?.lastPathComponent,
            trackNumber: song.trackNumber ?? 0,
            discNumber: song.discNumber ?? 1,
            duration: song.duration ?? 0,
            thumbPath: song.artwork?.ensembleResolvableURL(),
            streamKey: song.url?.absoluteString,
            genres: song.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
    }

    private nonisolated static func recentlyAddedHub(limit: Int) async throws -> Hub? {
        var request = MusicLibraryRequest<MusicKit.Album>()
        request.limit = limit
        request.sort(by: \.libraryAddedDate, ascending: false)
        let items = try await request.response().items.map { album in
            let domain = domainAlbum(album)
            return HubItem(
                id: domain.id,
                type: "album",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: domain.year,
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                addedAt: album.libraryAddedDate,
                album: domain
            )
        }
        return hub(id: "music.recent.added", title: "Recently Added", type: "album", items: Array(items))
    }

    private nonisolated static func recentlyPlayedHub(limit: Int) async throws -> Hub? {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = min(limit, 30)
        let items = try await request.response().items.map { song in
            let domain = domainTrack(song, key: catalogTrackKey(song))
            return HubItem(
                id: domain.id,
                type: "track",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                lastViewedAt: song.lastPlayedDate,
                track: domain
            )
        }
        return hub(id: "music.recent.played", title: "Recently Played Music", type: "track", items: Array(items))
    }

    private nonisolated static func mostPlayedHub(limit: Int) async throws -> Hub? {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.sort(by: \.playCount, ascending: false)
        let items = try await request.response().items.compactMap { song -> HubItem? in
            guard let playCount = song.playCount, playCount > 0 else { return nil }
            let domain = domainTrack(song, key: libraryTrackKey(song))
            return HubItem(
                id: domain.id,
                type: "track",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                lastViewedAt: song.lastPlayedDate,
                viewCount: playCount,
                track: domain
            )
        }
        return hub(id: "music.popular", title: "Most Played", type: "track", items: Array(items))
    }

    nonisolated static func availableHub(
        kind: HubSemanticKind,
        named name: String,
        operation: @Sendable () async throws -> Hub?
    ) async -> (hub: Hub?, failedKind: HubSemanticKind?) {
        do {
            return (try await operation(), nil)
        } catch {
            EnsembleLogger.debug("🎵 Apple Music \(name) hub fetch failed: \(error.localizedDescription)")
            return (nil, kind)
        }
    }

    private nonisolated static func hub(
        id: String,
        title: String,
        type: String,
        items: [HubItem]
    ) -> Hub? {
        guard !items.isEmpty else { return nil }
        return Hub(
            id: "\(MusicSourceIdentifier.appleMusic.compositeKey):\(id)",
            title: title,
            type: type,
            items: items,
            semanticKind: HubSemanticKind.provider(identifier: id, title: title),
            sourceScope: HubSourceScope(source: .appleMusic)
        )
    }

    static func trackUpsertInput(
        _ song: LibrarySong,
        metadata: NativeLibrarySongMetadata?,
        existing: TrackSyncMetadata?,
        isFavorite: Bool
    ) -> TrackUpsertInput {
        let lastPlayed: Date?
        let playCount: Int?
        if let metadata {
            lastPlayed = metadata.lastPlayed
            playCount = metadata.playCount
        } else {
            lastPlayed = existing?.lastPlayed
            playCount = existing?.playCount
        }

        return TrackUpsertInput(
            ratingKey: song.id,
            key: song.trackKey,
            title: song.attributes.name,
            artistName: song.attributes.artistName,
            albumName: song.attributes.albumName,
            albumRatingKey: song.albumKey,
            trackNumber: song.attributes.trackNumber,
            discNumber: song.attributes.discNumber,
            duration: song.attributes.durationInMillis,
            thumbPath: song.artworkURL,
            streamKey: song.attributes.url,
            dateAdded: metadata?.dateAdded ?? song.dateAdded,
            dateModified: nil,
            lastPlayed: lastPlayed,
            rating: isFavorite ? 10 : nil,
            isFavorite: isFavorite,
            playCount: playCount,
            genreNames: song.attributes.genreNames?.joined(separator: ", "),
            updatesDateAdded: true
        )
    }

    private static func catalogTrackKey(_ song: Song) -> String {
        song.libraryAddedDate == nil ? "apple-catalog" : "apple-catalog-library"
    }

    private static func libraryTrackKey(_ song: Song) -> String {
        "apple-library:\(song.id)"
    }

    private static func playlistTrackKey(_ song: Song) -> String {
        song.libraryAddedDate == nil ? catalogTrackKey(song) : libraryTrackKey(song)
    }

    private static func domainAlbum(_ album: MusicKit.Album, artistID: String? = nil) -> Album {
        Album(
            id: String(describing: album.id),
            key: "apple-catalog",
            title: album.title,
            artistName: album.artistName,
            albumArtist: album.artistName,
            artistRatingKey: artistID ?? album.artistURL?.lastPathComponent,
            year: album.releaseDate.map { Calendar.current.component(.year, from: $0) },
            trackCount: album.trackCount,
            thumbPath: album.artwork?.ensembleResolvableURL(),
            genres: album.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            releaseFormat: album.isSingle == true ? .single : .album
        )
    }

    private static func isSmartPlaylist(_ kind: MusicKit.Playlist.Kind?, canEdit: Bool) -> Bool {
        guard !canEdit else { return false }
        return switch kind {
        case .editorial, .external, .personalMix, .replay:
            true
        case .userShared, nil:
            false
        @unknown default:
            true
        }
    }

    static func restOnlyPlaylists(
        _ libraryPlaylists: [LibraryPlaylist],
        excluding musicKitIDs: Set<String>
    ) -> [LibraryPlaylist] {
        var seen = musicKitIDs
        return libraryPlaylists.filter { seen.insert($0.id).inserted }
    }

    private static func isSmartPlaylist(_ playlist: LibraryPlaylist) -> Bool {
        guard playlist.attributes.canEdit != true else { return false }
        switch playlist.catalogPlaylistType {
        case "user-shared":
            return false
        case "editorial", "external", "personal-mix", "replay":
            return true
        default:
            return playlist.attributes.playParams?.globalId?.hasPrefix("pl.u-") != true
        }
    }

    static func shouldRefreshPlaylistBody(
        existing: PlaylistSyncState?,
        modifiedAt: Date?,
        refreshAllBodies: Bool
    ) -> Bool {
        refreshAllBodies
            || modifiedAt == nil
            || existing == nil
            || existing?.dateModified != modifiedAt
            || existing.map { $0.trackCount != $0.membershipSnapshots.count } == true
    }

    struct PlaylistPersistencePlan: Sendable, Equatable {
        let writesHeader: Bool
        let writesBody: Bool
        let ignoresStaleResponse: Bool

        var hasChanges: Bool { writesHeader || writesBody }
    }

    private struct PlaylistPersistenceResult {
        let trackCount: Int
        let plan: PlaylistPersistencePlan
    }

    static func playlistPersistencePlan(
        existing: PlaylistSyncState?,
        input: PlaylistUpsertInput,
        membershipSnapshots: [PlaylistTrackSnapshot]
    ) -> PlaylistPersistencePlan {
        if let existingModifiedAt = existing?.dateModified,
           let incomingModifiedAt = input.dateModified,
           incomingModifiedAt < existingModifiedAt {
            return PlaylistPersistencePlan(
                writesHeader: false,
                writesBody: false,
                ignoresStaleResponse: true
            )
        }

        let existingBodyIsComplete = existing.map {
            $0.trackCount == $0.membershipRatingKeys.count
        } ?? false
        return PlaylistPersistencePlan(
            writesHeader: existing?.headerMatches(input) != true,
            writesBody: !existingBodyIsComplete
                || existing?.membershipSnapshots != membershipSnapshots,
            ignoresStaleResponse: false
        )
    }

    static func effectivePlaylistModifiedDate(musicKit: Date?, library: Date?) -> Date? {
        [musicKit, library].compactMap { $0 }.max()
    }

    static func withNativePlaylistBodyFallback<Value>(
        rest: () async throws -> Value,
        native: (Error) async throws -> Value
    ) async throws -> Value {
        do {
            return try await rest()
        } catch {
            let restError = error
            do {
                return try await native(restError)
            } catch {
                throw restError
            }
        }
    }

    private static func playlistInput(
        _ playlist: MusicKit.Playlist,
        artworkURL: String?,
        canEdit: Bool,
        dateModified: Date?,
        duration: Int,
        trackCount: Int
    ) -> PlaylistUpsertInput {
        let isSmart = isSmartPlaylist(playlist.kind, canEdit: canEdit)
        let capabilities = playlistActionCapabilities(
            id: String(describing: playlist.id),
            isSmart: isSmart,
            canEdit: canEdit
        )
        return PlaylistUpsertInput(
            ratingKey: String(describing: playlist.id),
            key: String(describing: playlist.id),
            title: playlist.name,
            summary: playlist.standardDescription,
            compositePath: artworkURL ?? playlist.artwork?.ensembleResolvableURL(),
            isSmart: isSmart,
            duration: duration,
            trackCount: trackCount,
            dateAdded: playlist.libraryAddedDate,
            dateModified: dateModified,
            lastPlayed: playlist.lastPlayedDate,
            actionCapabilities: capabilities
        )
    }

    static func playlistInput(
        _ playlist: LibraryPlaylist,
        duration: Int,
        trackCount: Int
    ) -> PlaylistUpsertInput {
        let isSmart = isSmartPlaylist(playlist)
        let canEdit = playlist.attributes.canEdit == true
        let title = playlist.attributes.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Playlist"
        let summary = [
            playlist.attributes.description?.standard,
            playlist.attributes.description?.short
        ].compactMap { $0 }.first { !$0.isEmpty }
        return PlaylistUpsertInput(
            ratingKey: playlist.id,
            key: playlist.id,
            title: title,
            summary: summary,
            compositePath: playlist.attributes.artwork?.url,
            isSmart: isSmart,
            duration: duration,
            trackCount: trackCount,
            dateAdded: playlist.dateAdded,
            dateModified: playlist.dateModified,
            lastPlayed: nil,
            actionCapabilities: playlistActionCapabilities(
                id: playlist.id,
                isSmart: isSmart,
                canEdit: canEdit
            )
        )
    }

    static func playlistActionCapabilities(
        id: String,
        isSmart: Bool,
        canEdit: Bool
    ) -> PlaylistActionCapabilities {
        let createdByEnsemble = Playlist.appleMusicPlaylistWasCreatedByEnsemble(id)
        let unavailableReason: String? = if isSmart {
            "Smart playlists are read-only."
        } else if canEdit, !createdByEnsemble {
            "Songs can be added, but Apple only lets Ensemble reorder or rename playlists Ensemble created."
        } else if !canEdit {
            "This Apple Music playlist is read-only."
        } else {
            nil
        }
        return PlaylistActionCapabilities(
            canAddItems: canEdit && !isSmart,
            canRename: canEdit && createdByEnsemble && !isSmart,
            canReorder: canEdit && createdByEnsemble && !isSmart,
            canDelete: false,
            unavailableReason: unavailableReason
        )
    }

    private func catalogSongs(for tracks: [Track]) async throws -> [Song] {
        let ids = tracks.compactMap(\.appleMusicCatalogID)
        guard ids.count == tracks.count else { throw PlaylistMutationError.invalidSource }
        guard !ids.isEmpty else { return [] }
        let musicItemIDs = ids.map { MusicItemID($0) }
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            memberOf: musicItemIDs
        )
        let songsByID: [String: Song] = Dictionary(uniqueKeysWithValues: try await request.response().items.map {
            (String(describing: $0.id), $0)
        })
        return ids.compactMap { songsByID[$0] }
    }

    private func libraryPlaylist(id: String) async throws -> MusicKit.Playlist {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else {
            throw AppleMusicSourceError.playlistNotFound
        }
        return playlist
    }

    private func persistPlaylist(
        _ playlist: MusicKit.Playlist,
        artworkURL: String?,
        canEdit: Bool,
        dateModified: Date? = nil,
        existing: PlaylistSyncState? = nil,
        minimumTrackCount: Int = 0,
        requiredTracks: [Track] = [],
        to repository: PlaylistRepositoryProtocol
    ) async throws -> PlaylistPersistenceResult? {
        let id = String(describing: playlist.id)
        let sourceKey = sourceIdentifier.compositeKey
        let detailed = try await playlist.with([.tracks])
        var musicTracks = detailed.tracks ?? []
        while musicTracks.hasNextBatch, let next = try await musicTracks.nextBatch(limit: 100) {
            musicTracks += next
        }
        let songs = musicTracks.compactMap { track -> Song? in
            guard case .song(let song) = track else { return nil }
            return song
        }
        let fetchedTracks = songs.map { Self.domainTrack($0, key: Self.playlistTrackKey($0)) }
        guard songs.count >= minimumTrackCount,
              PlaylistActionService().tracks(requiredTracks, excluding: fetchedTracks).isEmpty
        else { return nil }
        let input = Self.playlistInput(
            playlist,
            artworkURL: artworkURL,
            canEdit: canEdit,
            dateModified: dateModified ?? playlist.lastModifiedDate,
            duration: Int(songs.reduce(0) { $0 + ($1.duration ?? 0) } * 1000),
            trackCount: songs.count
        )
        let snapshots = songs.map {
            PlaylistTrackSnapshot(
                ratingKey: String(describing: $0.id),
                key: Self.playlistTrackKey($0),
                title: $0.title,
                artistName: $0.artistName,
                albumName: $0.albumTitle,
                duration: $0.duration ?? 0,
                thumbPath: $0.artwork?.ensembleResolvableURL(),
                sourceCompositeKey: sourceKey
            )
        }
        let plan = Self.playlistPersistencePlan(
            existing: existing,
            input: input,
            membershipSnapshots: snapshots
        )
        if plan.writesHeader {
            _ = try await repository.upsertPlaylist(input, sourceCompositeKey: sourceKey)
        }
        if plan.writesBody {
            try await repository.setPlaylistTrackSnapshots(
                snapshots,
                forPlaylist: id,
                sourceCompositeKey: sourceKey
            )
        }
        return PlaylistPersistenceResult(trackCount: songs.count, plan: plan)
    }

    private func persistLibraryPlaylist(
        _ playlist: LibraryPlaylist,
        musicKitPlaylist: MusicKit.Playlist? = nil,
        existing: PlaylistSyncState? = nil,
        to repository: PlaylistRepositoryProtocol
    ) async throws -> PlaylistPersistenceResult {
        let sourceKey = sourceIdentifier.compositeKey
        let encodedID = playlist.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlist.id
        let fetchedTracks: [LibrarySong] = try await fetchAll(
            path: "/v1/me/library/playlists/\(encodedID)/tracks?limit=100&include=catalog"
        )
        let songs = fetchedTracks.filter(\.isSong)
        let duration = songs.reduce(0) { $0 + ($1.attributes.durationInMillis ?? 0) }
        let input = if let musicKitPlaylist {
            Self.playlistInput(
                musicKitPlaylist,
                artworkURL: playlist.attributes.artwork?.url,
                canEdit: playlist.attributes.canEdit == true,
                dateModified: Self.effectivePlaylistModifiedDate(
                    musicKit: musicKitPlaylist.lastModifiedDate,
                    library: playlist.dateModified
                ),
                duration: duration,
                trackCount: songs.count
            )
        } else {
            Self.playlistInput(playlist, duration: duration, trackCount: songs.count)
        }
        let snapshots = songs.map {
            PlaylistTrackSnapshot(
                ratingKey: $0.id,
                key: $0.trackKey,
                title: $0.attributes.name,
                artistName: $0.attributes.artistName,
                albumName: $0.attributes.albumName,
                duration: TimeInterval($0.attributes.durationInMillis ?? 0) / 1000,
                thumbPath: $0.artworkURL,
                sourceCompositeKey: sourceKey
            )
        }
        let plan = Self.playlistPersistencePlan(
            existing: existing,
            input: input,
            membershipSnapshots: snapshots
        )
        if plan.writesHeader {
            _ = try await repository.upsertPlaylist(
                input,
                sourceCompositeKey: sourceKey
            )
        }
        if plan.writesBody {
            try await repository.setPlaylistTrackSnapshots(
                snapshots,
                forPlaylist: playlist.id,
                sourceCompositeKey: sourceKey
            )
        }
        return PlaylistPersistenceResult(trackCount: songs.count, plan: plan)
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let url = path.hasPrefix("http") ? URL(string: path) : URL(string: "https://api.music.apple.com\(path)")
        guard let url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200..<300).contains(response.urlResponse.statusCode) else {
            throw AppleMusicSourceError.http(response.urlResponse.statusCode)
        }
        return response.data
    }
}

@available(iOS 18, *)
struct NativeLibrarySongMetadata: Sendable, Equatable {
    let itemID: String
    let dateAdded: Date?
    let lastPlayed: Date?
    let playCount: Int?
}

@available(iOS 18, *)
struct NativeLibraryDateMetadata: Sendable, Equatable {
    let itemID: String
    let dateAdded: Date?
}

@available(iOS 18, *)
struct NativeLibraryMetadataSnapshot: Sendable {
    let songsByID: [String: NativeLibrarySongMetadata]
    let albumDateAddedByID: [String: Date]
    let artistDateAddedByID: [String: Date]
    let elapsedMilliseconds: Int

    init(
        songs: [NativeLibrarySongMetadata],
        albums: [NativeLibraryDateMetadata],
        artists: [NativeLibraryDateMetadata],
        elapsedMilliseconds: Int
    ) {
        songsByID = Dictionary(
            songs.map { ($0.itemID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        albumDateAddedByID = Dictionary(
            albums.compactMap { item in item.dateAdded.map { (item.itemID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        artistDateAddedByID = Dictionary(
            artists.compactMap { item in item.dateAdded.map { (item.itemID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

@available(iOS 18, *)
struct Page<Resource: Decodable>: Decodable {
    let data: [Resource]
    let next: String?
}

@available(iOS 18, *)
struct LibrarySong: Decodable {
    struct Attributes: Decodable {
        struct PlayParameters: Decodable { let catalogId: String? }
        let name: String
        let artistName: String?
        let albumName: String?
        let artwork: Artwork?
        let durationInMillis: Int?
        let trackNumber: Int?
        let discNumber: Int?
        let genreNames: [String]?
        let dateAdded: String?
        let releaseDate: String?
        let inFavorites: Bool?
        let url: String?
        let playParams: PlayParameters?
    }
    struct Relationships: Decodable {
        let albums: Page<LibraryReference>?
        let artists: Page<LibraryReference>?
        let catalog: Page<CatalogReference>?
    }
    struct LibraryReference: Decodable { let id: String }
    struct CatalogReference: Decodable { let id: String }

    let id: String
    let type: String?
    let attributes: Attributes
    let relationships: Relationships?

    var catalogID: String? { attributes.playParams?.catalogId ?? relationships?.catalog?.data.first?.id }
    var isSong: Bool { type == nil || type == "library-songs" || type == "songs" }
    var trackKey: String {
        catalogID.map { "apple-library-catalog:\($0)" } ?? "apple-library:\(id)"
    }
    var dateAdded: Date? { attributes.dateAdded.flatMap(Self.date) }
    var year: Int? { attributes.releaseDate.flatMap { Int($0.prefix(4)) } }
    var artworkURL: String? { attributes.artwork?.url }
    var artistLibraryID: String? { relationships?.artists?.data.first?.id }
    var albumLibraryID: String? { relationships?.albums?.data.first?.id }
    var artistKey: String {
        "apple-artist:\(artistLibraryID ?? Self.normalized(attributes.artistName ?? "Unknown Artist"))"
    }
    var albumKey: String {
        if let id = albumLibraryID {
            return "apple-album:\(id)"
        }
        return "apple-album:\(Self.normalized(attributes.artistName ?? "Unknown Artist"))|\(Self.normalized(attributes.albumName ?? "Unknown Album"))"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value) ?? DateFormatter.appleMusicDay.date(from: value)
    }
}

@available(iOS 18, *)
struct LibraryPlaylist: Decodable {
    struct DescriptionAttribute: Decodable {
        let standard: String?
        let short: String?
    }

    struct PlayParameters: Decodable {
        let globalId: String?
    }

    struct Attributes: Decodable {
        let canEdit: Bool?
        let artwork: Artwork?
        let name: String?
        let description: DescriptionAttribute?
        let dateAdded: String?
        let lastModifiedDate: String?
        let hasCatalog: Bool?
        let playParams: PlayParameters?
    }

    struct Relationships: Decodable {
        let catalog: Page<CatalogPlaylist>?
    }

    struct CatalogPlaylist: Decodable {
        struct Attributes: Decodable {
            let playlistType: String?
        }

        let attributes: Attributes?
    }

    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    var dateAdded: Date? { attributes.dateAdded.flatMap(Self.date) }
    var dateModified: Date? { attributes.lastModifiedDate.flatMap(Self.date) }
    var catalogPlaylistType: String? { relationships?.catalog?.data.first?.attributes?.playlistType }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value) ?? DateFormatter.appleMusicDay.date(from: value)
    }
}

@available(iOS 18, *)
struct Artwork: Decodable { let url: String }

private extension DateFormatter {
    static let appleMusicDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public enum AppleMusicSourceError: LocalizedError {
    case musicKitPlaybackRequired
    case favoriteRemovalUnsupported
    case playlistDeletionUnsupported
    case playlistNotFound
    case catalogSongNotFound
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .musicKitPlaybackRequired: "Apple Music tracks must be played by MusicKit."
        case .favoriteRemovalUnsupported: "Removing Apple Music favorites is unavailable on this device."
        case .playlistDeletionUnsupported: "Delete this Apple Music playlist in the Music app."
        case .playlistNotFound: "The Apple Music playlist could not be found."
        case .catalogSongNotFound: "The Apple Music song could not be found."
        case .http(let status): "Apple Music returned HTTP \(status)."
        }
    }
}
#endif
