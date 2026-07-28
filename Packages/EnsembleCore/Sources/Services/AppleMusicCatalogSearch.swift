#if os(iOS)
import Foundation
import MusicKit

@available(iOS 18, *)
extension MusicKit.Artwork {
    func ensembleResolvableURL(size: Int = 1200) -> String? {
        guard let url = url(width: size, height: size) else { return nil }
        guard url.scheme?.lowercased() != "musickit"
            || URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "aat" }) == true
        else { return nil }
        return url.absoluteString
    }
}

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
                let albumArtwork = response.albums.first {
                    DisplayPlaylist.normalizedTitle($0.title) == DisplayPlaylist.normalizedTitle(song.albumTitle ?? "")
                        && DisplayPlaylist.normalizedTitle($0.artistName) == DisplayPlaylist.normalizedTitle(song.artistName)
                }?.artwork?.ensembleResolvableURL()
                return Track(
                    id: String(describing: song.id),
                    key: song.libraryAddedDate == nil ? "apple-catalog" : "apple-catalog-library",
                    title: song.title,
                    artistName: song.artistName,
                    albumArtistName: song.artistName,
                    albumName: song.albumTitle,
                    trackNumber: song.trackNumber ?? 0,
                    discNumber: song.discNumber ?? 1,
                    duration: song.duration ?? 0,
                    thumbPath: song.artwork?.ensembleResolvableURL() ?? albumArtwork,
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
                    thumbPath: artist.artwork?.ensembleResolvableURL(),
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
                    thumbPath: album.artwork?.ensembleResolvableURL(),
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
                    compositePath: playlist.artwork?.ensembleResolvableURL(),
                    sourceCompositeKey: sourceKey
                )
            }
        return Results(tracks: tracks, artists: artists, albums: albums, playlists: playlists)
    }
}
#endif
