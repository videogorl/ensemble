#if os(iOS)
import Foundation
import MusicKit

@available(iOS 18, *)
enum AppleMusicCatalogSearch {
    struct Results {
        let tracks: [Track]
        let artists: [Artist]
        let albums: [Album]
        let playlists: [Playlist]
    }

    static func search(_ term: String) async throws -> Results {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, MusicKit.Artist.self, MusicKit.Album.self, MusicKit.Playlist.self]
        )
        request.limit = 25
        let response = try await request.response()
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey

        let tracks: [Track] = response.songs.map { song in
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
                    sourceCompositeKey: sourceKey
                )
            }
        let artists: [Artist] = response.artists.map { artist in
                Artist(
                    id: String(describing: artist.id),
                    key: "apple-catalog",
                    name: artist.name,
                    thumbPath: artist.artwork?.url(width: 1200, height: 1200)?.absoluteString,
                    sourceCompositeKey: sourceKey
                )
            }
        let albums: [Album] = response.albums.map { album in
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
                    sourceCompositeKey: sourceKey,
                    releaseFormat: album.isSingle == true ? .single : .album
                )
            }
        let playlists: [Playlist] = response.playlists.map { playlist in
                Playlist(
                    id: String(describing: playlist.id),
                    key: "apple-catalog",
                    title: playlist.name,
                    summary: playlist.standardDescription,
                    isSmart: true,
                    compositePath: playlist.artwork?.url(width: 1200, height: 1200)?.absoluteString,
                    sourceCompositeKey: sourceKey
                )
            }
        return Results(tracks: tracks, artists: artists, albums: albums, playlists: playlists)
    }
}
#endif
