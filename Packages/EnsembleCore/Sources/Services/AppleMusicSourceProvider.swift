#if os(iOS)
import EnsemblePersistence
import Foundation
import MusicKit

@available(iOS 18, *)
public actor AppleMusicSourceProvider:
    MusicSourceSyncProvider,
    MusicSourcePlaybackResolving,
    MusicSourceRatingMutating,
    MusicSourcePlaylistMutating,
    MusicSourcePlaybackReporting,
    MusicSourceDetailProviding
{
    public nonisolated let sourceIdentifier = MusicSourceIdentifier.appleMusic
    static let librarySongsPath = "/v1/me/library/songs?limit=100&extend=inFavorites&include=albums,artists,catalog"
    static let libraryPlaylistsPath = "/v1/me/library/playlists?limit=100&include=catalog"
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
        let fetchedSongs: [LibrarySong] = try await fetchAll(path: Self.librarySongsPath)
        var seenSongIDs = Set<String>()
        let songs = fetchedSongs.filter { seenSongIDs.insert($0.id).inserted }
        progressHandler(0.5)

        catalogIDsByLibraryID = Dictionary(uniqueKeysWithValues: songs.compactMap { song in
            song.catalogID.map { (song.id, $0) }
        })
        pendingFavoriteCatalogIDs.subtract(songs.compactMap { song in
            song.attributes.inFavorites == true ? song.catalogID : nil
        })

        let artists = Dictionary(grouping: songs, by: \.artistKey).compactMap { key, songs -> ArtistUpsertInput? in
            guard let song = songs.first else { return nil }
            return ArtistUpsertInput(
                ratingKey: key,
                key: key,
                name: song.attributes.artistName ?? "Unknown Artist",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: songs.compactMap(\.dateAdded).min(),
                dateModified: nil
            )
        }
        let albums = Self.albumUpsertInputs(from: songs)
        let tracks = songs.map { song in
            trackInput(
                song,
                isFavorite: song.attributes.inFavorites == true
                    || song.catalogID.map(pendingFavoriteCatalogIDs.contains) == true
            )
        }

        let existingArtists = try await repository.fetchArtistSyncMetadata(forSource: sourceKey)
        let existingAlbums = try await repository.fetchAlbumSyncMetadata(forSource: sourceKey)
        let existingTracks = try await repository.fetchTrackSyncMetadata(forSource: sourceKey)
        let changedArtists = artists.filter { existingArtists[$0.ratingKey]?.matches($0) != true }
        let changedAlbums = albums.filter { existingAlbums[$0.ratingKey]?.matches($0) != true }
        let changedTracks = tracks.filter { existingTracks[$0.ratingKey]?.matches($0) != true }
        EnsembleLogger.debug(
            "🎵 Apple Music inventory \(songs.count) songs; writing \(changedArtists.count) artists, \(changedAlbums.count) albums, \(changedTracks.count) tracks"
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

    static func albumUpsertInputs(from songs: [LibrarySong]) -> [AlbumUpsertInput] {
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
                dateAdded: songs.compactMap(\.dateAdded).min(),
                dateModified: nil,
                rating: nil,
                genreNames: song.attributes.genreNames?.joined(separator: ", ")
            )
        }
    }

    public func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        try await syncLibrary(to: repository, progressHandler: progressHandler)
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
        var refreshedBodies = 0

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
                do {
                    if let libraryPlaylist {
                        try await persistLibraryPlaylist(
                            libraryPlaylist,
                            musicKitPlaylist: playlist,
                            to: repository
                        )
                    } else {
                        _ = try await persistPlaylist(
                            playlist,
                            artworkURL: artworkURL,
                            canEdit: canEdit,
                            to: repository
                        )
                    }
                } catch {
                    Self.logPlaylistBodyFailure(id: id, title: playlist.name, error: error)
                    throw error
                }
                changedPlaylists += 1
                refreshedBodies += 1
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
                do {
                    try await persistLibraryPlaylist(playlist, to: repository)
                } catch {
                    Self.logPlaylistBodyFailure(
                        id: playlist.id,
                        title: playlist.attributes.name ?? "Untitled Playlist",
                        error: error
                    )
                    throw error
                }
                changedPlaylists += 1
                refreshedBodies += 1
            } else {
                let input = Self.playlistInput(
                    playlist,
                    duration: existing?.duration ?? 0,
                    trackCount: existing?.trackCount ?? 0
                )
                if existing?.headerMatches(input) != true {
                    _ = try await repository.upsertPlaylist(input, sourceCompositeKey: sourceKey)
                    changedPlaylists += 1
                }
            }
            progressHandler(Double(playlists.count + index + 1) / Double(max(inventoryCount, 1)))
        }

        EnsembleLogger.debug(
            "🎵 Apple Music playlist inventory \(validIDs.count); refreshed \(refreshedBodies) bodies, wrote \(changedPlaylists - refreshedBodies) headers"
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
        )
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

    public func rateTrack(ratingKey: String, rating: Int?) async throws {
        guard let rating, rating > 0 else { throw AppleMusicSourceError.favoriteRemovalUnsupported }
        try await favorite(catalogID: catalogIDsByLibraryID[ratingKey] ?? ratingKey)
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

    public func createPlaylist(title: String, tracks: [Track]) async throws {
        let songs = try await catalogSongs(for: tracks)
        guard !songs.isEmpty || tracks.isEmpty else { throw PlaylistMutationError.emptySelection }
        let playlist = try await MusicLibrary.shared.createPlaylist(name: title, items: songs)
        Playlist.markAppleMusicPlaylistCreated(id: String(describing: playlist.id))
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
        return albums.map(Self.domainAlbum)
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

    private func trackInput(_ song: LibrarySong, isFavorite: Bool) -> TrackUpsertInput {
        TrackUpsertInput(
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
            dateAdded: song.dateAdded,
            dateModified: nil,
            lastPlayed: nil,
            rating: isFavorite ? 10 : nil,
            isFavorite: isFavorite,
            playCount: nil,
            genreNames: song.attributes.genreNames?.joined(separator: ", ")
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

    private static func domainAlbum(_ album: MusicKit.Album) -> Album {
        Album(
            id: String(describing: album.id),
            key: "apple-catalog",
            title: album.title,
            artistName: album.artistName,
            albumArtist: album.artistName,
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
            || ((existing?.trackCount ?? 0) > 0 && existing?.membershipRatingKeys.isEmpty == true)
    }

    static func effectivePlaylistModifiedDate(musicKit: Date?, library: Date?) -> Date? {
        [musicKit, library].compactMap { $0 }.max()
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
        minimumTrackCount: Int = 0,
        requiredTracks: [Track] = [],
        to repository: PlaylistRepositoryProtocol
    ) async throws -> Int? {
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
            dateModified: playlist.lastModifiedDate,
            duration: Int(songs.reduce(0) { $0 + ($1.duration ?? 0) } * 1000),
            trackCount: songs.count
        )
        _ = try await repository.upsertPlaylist(input, sourceCompositeKey: sourceKey)
        try await repository.setPlaylistTrackSnapshots(
            songs.map {
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
            },
            forPlaylist: id,
            sourceCompositeKey: sourceKey
        )
        return songs.count
    }

    private func persistLibraryPlaylist(
        _ playlist: LibraryPlaylist,
        musicKitPlaylist: MusicKit.Playlist? = nil,
        to repository: PlaylistRepositoryProtocol
    ) async throws {
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
        _ = try await repository.upsertPlaylist(
            input,
            sourceCompositeKey: sourceKey
        )
        try await repository.setPlaylistTrackSnapshots(
            songs.map {
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
            },
            forPlaylist: playlist.id,
            sourceCompositeKey: sourceKey
        )
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
    var artistKey: String {
        "apple-artist:\(relationships?.artists?.data.first?.id ?? Self.normalized(attributes.artistName ?? "Unknown Artist"))"
    }
    var albumKey: String {
        if let id = relationships?.albums?.data.first?.id {
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
