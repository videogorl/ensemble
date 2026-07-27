#if os(iOS)
import EnsemblePersistence
import Foundation
import MusicKit

@available(iOS 18, *)
public actor AppleMusicSourceProvider: MusicSourceSyncProvider {
    public nonisolated let sourceIdentifier = MusicSourceIdentifier.appleMusic
    private var catalogIDsByLibraryID: [String: String] = [:]

    public init() {}

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
        let songs: [LibrarySong] = try await fetchAll(path: "/v1/me/library/songs?limit=100&extend=inFavorites&include=catalog")
        progressHandler(0.5)

        catalogIDsByLibraryID = Dictionary(uniqueKeysWithValues: songs.compactMap { song in
            song.catalogID.map { (song.id, $0) }
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
        let albums = Dictionary(grouping: songs, by: \.albumKey).compactMap { key, songs -> AlbumUpsertInput? in
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
        let tracks = songs.map { song in
            TrackUpsertInput(
                ratingKey: song.id,
                key: "apple-library:\(song.catalogID ?? "")",
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
                rating: song.attributes.inFavorites == true ? 10 : nil,
                playCount: nil,
                genreNames: song.attributes.genreNames?.joined(separator: ", ")
            )
        }

        try await repository.batchUpsertArtists(artists, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertAlbums(albums, sourceCompositeKey: sourceKey)
        try await repository.batchUpsertTracks(tracks, sourceCompositeKey: sourceKey)
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
            changedArtists: artists.count,
            changedAlbums: albums.count,
            changedTracks: tracks.count,
            removedArtists: removedArtists,
            removedAlbums: removedAlbums,
            removedTracks: removedTracks
        )
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
        let sourceKey = sourceIdentifier.compositeKey
        var playlists: [MusicKit.Playlist] = []
        var offset = 0
        while true {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            request.offset = offset
            let page = Array(try await request.response().items)
            playlists.append(contentsOf: page)
            guard page.count == request.limit else { break }
            offset += page.count
        }
        var validIDs = Set<String>()

        for (index, playlist) in playlists.enumerated() {
            let id = String(describing: playlist.id)
            validIDs.insert(id)
            let detailed = try await playlist.with([.tracks])
            var musicTracks = detailed.tracks ?? []
            while musicTracks.hasNextBatch, let next = try await musicTracks.nextBatch(limit: 100) {
                musicTracks += next
            }
            let songs = musicTracks.compactMap { track -> Song? in
                guard case .song(let song) = track else { return nil }
                return song
            }
            _ = try await repository.upsertPlaylist(
                ratingKey: id,
                key: id,
                title: playlist.name,
                summary: playlist.standardDescription,
                compositePath: playlist.artwork?.url(width: 1200, height: 1200)?.absoluteString,
                isSmart: playlist.kind != nil,
                duration: Int(songs.reduce(0) { $0 + ($1.duration ?? 0) } * 1000),
                trackCount: songs.count,
                dateAdded: playlist.libraryAddedDate,
                dateModified: playlist.lastModifiedDate,
                lastPlayed: playlist.lastPlayedDate,
                sourceCompositeKey: sourceKey
            )
            try await repository.setPlaylistTrackSnapshots(
                songs.map {
                    PlaylistTrackSnapshot(
                        ratingKey: String(describing: $0.id),
                        key: "apple-catalog",
                        title: $0.title,
                        artistName: $0.artistName,
                        albumName: $0.albumTitle,
                        duration: $0.duration ?? 0,
                        thumbPath: $0.artwork?.url(width: 1200, height: 1200)?.absoluteString,
                        sourceCompositeKey: sourceKey
                    )
                },
                forPlaylist: id,
                sourceCompositeKey: sourceKey
            )
            progressHandler(Double(index + 1) / Double(max(playlists.count, 1)))
        }

        let removed = try await repository.removeOrphanedPlaylists(notIn: validIDs, forSource: sourceKey)
        progressHandler(1)
        return PlaylistSyncResult(changedPlaylists: playlists.count, removedPlaylists: removed)
    }

    public func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        forceOrphanCheck: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        try await syncPlaylists(to: repository, progressHandler: progressHandler)
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
        return URL(string: path.replacingOccurrences(of: "{w}", with: "\(size)")
            .replacingOccurrences(of: "{h}", with: "\(size)"))
    }

    public func rateTrack(ratingKey: String, rating: Int?) async throws {
        guard let rating, rating > 0 else { throw AppleMusicSourceError.favoriteRemovalUnsupported }
        try await favorite(catalogID: catalogIDsByLibraryID[ratingKey] ?? ratingKey)
    }

    public func favorite(catalogID: String) async throws {
        _ = try await request(path: "/v1/me/favorites?ids=\(catalogID)", method: "POST")
    }

    public func createPlaylist(title: String, tracks: [Track]) async throws {
        let songs = try await catalogSongs(for: tracks)
        guard !songs.isEmpty || tracks.isEmpty else { throw PlaylistMutationError.emptySelection }
        _ = try await MusicLibrary.shared.createPlaylist(name: title, items: songs)
    }

    public func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
        let playlist = try await libraryPlaylist(id: playlistID)
        let songs = try await catalogSongs(for: tracks)
        for song in songs {
            _ = try await MusicLibrary.shared.add(song, to: playlist)
        }
        return songs.count
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
            return Self.domainTrack(song)
        } ?? []
    }

    public func getArtistAlbums(artistKey: String) async throws -> [Album] {
        var catalogArtistKey = artistKey
        if artistKey.hasPrefix("apple-artist:") {
            let name = String(artistKey.dropFirst("apple-artist:".count))
            var search = MusicCatalogSearchRequest(term: name, types: [MusicKit.Artist.self])
            search.limit = 10
            let artists = try await search.response().artists
            let match = artists.first {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? artists.first
            guard let match else { return [] }
            catalogArtistKey = String(describing: match.id)
        }

        var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(catalogArtistKey))
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
            return Self.domainTrack(song)
        } ?? []
    }

    private func fetchAll<Resource: Decodable>(path: String) async throws -> [Resource] {
        var path: String? = path
        var result: [Resource] = []
        while let current = path {
            let data = try await request(path: current)
            let page = try JSONDecoder().decode(Page<Resource>.self, from: data)
            result.append(contentsOf: page.data)
            path = page.next
        }
        return result
    }

    private static func domainTrack(_ song: Song) -> Track {
        Track(
            id: String(describing: song.id),
            key: "apple-catalog",
            title: song.title,
            artistName: song.artistName,
            albumArtistName: song.artistName,
            albumName: song.albumTitle,
            trackNumber: song.trackNumber ?? 0,
            discNumber: song.discNumber ?? 1,
            duration: song.duration ?? 0,
            thumbPath: song.artwork?.url(width: 1200, height: 1200)?.absoluteString,
            streamKey: song.url?.absoluteString,
            genres: song.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
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
            thumbPath: album.artwork?.url(width: 1200, height: 1200)?.absoluteString,
            genres: album.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            releaseFormat: album.isSingle == true ? .single : .album
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
private struct Page<Resource: Decodable>: Decodable {
    let data: [Resource]
    let next: String?
}

@available(iOS 18, *)
private struct LibrarySong: Decodable {
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
        let catalog: Page<CatalogReference>?
    }
    struct CatalogReference: Decodable { let id: String }

    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    var catalogID: String? { attributes.playParams?.catalogId ?? relationships?.catalog?.data.first?.id }
    var dateAdded: Date? { attributes.dateAdded.flatMap(Self.date) }
    var year: Int? { attributes.releaseDate.flatMap { Int($0.prefix(4)) } }
    var artworkURL: String? { attributes.artwork?.url }
    var artistKey: String { "apple-artist:\(Self.normalized(attributes.artistName ?? "Unknown Artist"))" }
    var albumKey: String {
        "apple-album:\(Self.normalized(attributes.artistName ?? "Unknown Artist"))|\(Self.normalized(attributes.albumName ?? "Unknown Album"))"
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
private struct Artwork: Decodable { let url: String }

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
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .musicKitPlaybackRequired: "Apple Music tracks must be played by MusicKit."
        case .favoriteRemovalUnsupported: "Removing Apple Music favorites is unavailable on this device."
        case .playlistDeletionUnsupported: "Delete this Apple Music playlist in the Music app."
        case .playlistNotFound: "The Apple Music playlist could not be found."
        case .http(let status): "Apple Music returned HTTP \(status)."
        }
    }
}
#endif
