import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Syncs a single Plex server+library to CoreData
public final class PlexMusicSourceSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
    public let sourceIdentifier: MusicSourceIdentifier
    private let apiClient: PlexAPIClient
    private let sectionKey: String

    public init(
        sourceIdentifier: MusicSourceIdentifier,
        apiClient: PlexAPIClient,
        sectionKey: String
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.apiClient = apiClient
        self.sectionKey = sectionKey
    }

    public func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
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
        for artist in artists {
            _ = try await repository.upsertArtist(
                ratingKey: artist.ratingKey,
                key: artist.key,
                name: artist.title,
                summary: artist.summary,
                thumbPath: artist.thumb,
                artPath: artist.art,
                sourceCompositeKey: sourceKey
            )
        }

        // Sync albums
        progressHandler(0.3)
        let albums = try await apiClient.getAlbums(sectionKey: sectionKey)
        for album in albums {
            _ = try await repository.upsertAlbum(
                ratingKey: album.ratingKey,
                key: album.key,
                title: album.title,
                artistName: album.parentTitle,
                artistRatingKey: album.parentRatingKey,
                summary: album.summary,
                thumbPath: album.thumb,
                artPath: album.art,
                year: album.year,
                trackCount: album.leafCount,
                sourceCompositeKey: sourceKey
            )
        }

        // Sync tracks
        progressHandler(0.5)
        let tracks = try await apiClient.getTracks(sectionKey: sectionKey)
        print("📀 Syncing \(tracks.count) tracks")
        for (index, track) in tracks.enumerated() {
            if index == 0 {
                print("📀 First track streamURL: \(track.streamURL ?? "nil")")
                print("📀 First track media count: \(track.media?.count ?? 0)")
                if let media = track.media?.first {
                    print("📀 First track parts count: \(media.part?.count ?? 0)")
                    if let part = media.part?.first {
                        print("📀 First track part key: \(part.key ?? "nil")")
                    }
                }
            }
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
                sourceCompositeKey: sourceKey
            )
        }

        // Sync genres
        progressHandler(0.7)
        let genres = try await apiClient.getGenres(sectionKey: sectionKey)
        for genre in genres {
            _ = try await repository.upsertGenre(
                ratingKey: genre.ratingKey,
                key: genre.key,
                title: genre.title,
                sourceCompositeKey: sourceKey
            )
        }

        // Sync playlists
        progressHandler(0.9)
        let playlists = try await apiClient.getPlaylists()
        for playlist in playlists {
            _ = try await playlistRepository.upsertPlaylist(
                ratingKey: playlist.ratingKey,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.composite,
                isSmart: playlist.smart ?? false,
                duration: playlist.duration,
                trackCount: playlist.leafCount,
                sourceCompositeKey: sourceKey
            )

            let playlistTracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.ratingKey)
            let trackKeys = playlistTracks.map { $0.ratingKey }
            try await playlistRepository.setPlaylistTracks(trackKeys, forPlaylist: playlist.ratingKey, sourceCompositeKey: sourceKey)
        }

        progressHandler(1.0)
    }

    public func getStreamURL(for trackRatingKey: String, trackStreamKey: String?) async throws -> URL {
        // If we have a direct stream key (the media part path), use it
        if let streamKey = trackStreamKey, !streamKey.isEmpty {
            print("🔍 PlexProvider: Using cached stream key: \(streamKey)")
            return try await apiClient.getStreamURL(trackKey: streamKey)
        }
        
        // Fallback: Fetch the full track metadata which should include Media array
        print("⚠️ PlexProvider: No cached stream key, fetching full track metadata for: \(trackRatingKey)")
        if let track = try await apiClient.getTrack(trackKey: trackRatingKey),
           let streamKey = track.streamURL {
            print("✅ PlexProvider: Got stream key from track metadata: \(streamKey)")
            return try await apiClient.getStreamURL(trackKey: streamKey)
        }
        
        print("❌ PlexProvider: Could not get stream URL for track")
        throw PlexAPIError.invalidURL
    }

    public func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        try await apiClient.getArtworkURL(path: path, size: size)
    }
}
