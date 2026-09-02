import XCTest
@testable import EnsembleCore

final class MediaFilterEngineTests: XCTestCase {
    func testLibraryTrackFilterUsesSearchGenresExclusionsAndDownloads() {
        var options = FilterOptions()
        options.searchText = "sea"
        options.selectedGenres = ["Ambient"]
        options.excludedGenres = ["Live"]
        options.showDownloadedOnly = true

        let tracks = [
            makeTrack(id: "title", title: "Sea Change", artist: "A", album: "B", genres: ["Ambient"], downloaded: true),
            makeTrack(id: "artist", title: "Other", artist: "Sea Person", album: "B", genres: ["Ambient"], downloaded: true),
            makeTrack(id: "album", title: "Other", artist: "A", album: "Sea Album", genres: ["Ambient"], downloaded: true),
            makeTrack(id: "excluded", title: "Sea Live", artist: "A", album: "B", genres: ["Ambient", "Live"], downloaded: true),
            makeTrack(id: "not-downloaded", title: "Sea", artist: "A", album: "B", genres: ["Ambient"], downloaded: false),
            makeTrack(id: "wrong-genre", title: "Sea", artist: "A", album: "B", genres: ["Rock"], downloaded: true)
        ]

        let filtered = MediaFilterEngine.filterTracks(tracks, with: options, configuration: .library)

        XCTAssertEqual(filtered.map(\.id), ["title", "artist", "album"])
    }

    func testTrackDetailConfigurationsPreserveSearchFieldDrift() {
        var options = FilterOptions()
        options.searchText = "match"

        let tracks = [
            makeTrack(id: "title", title: "Match", artist: "Artist", album: "Album"),
            makeTrack(id: "artist", title: "Song", artist: "Match Artist", album: "Album"),
            makeTrack(id: "album", title: "Song", artist: "Artist", album: "Match Album")
        ]

        XCTAssertEqual(
            MediaFilterEngine.filterTracks(tracks, with: options, configuration: .albumDetail).map(\.id),
            ["title", "artist"]
        )
        XCTAssertEqual(
            MediaFilterEngine.filterTracks(tracks, with: options, configuration: .artistDetail).map(\.id),
            ["title", "album"]
        )
        XCTAssertEqual(
            MediaFilterEngine.filterTracks(tracks, with: options, configuration: .favorites).map(\.id),
            ["title", "artist", "album"]
        )
    }

    func testFavoritesConfigurationIgnoresGenreFiltersButKeepsDownloads() {
        var options = FilterOptions()
        options.selectedGenres = ["Ambient"]
        options.excludedGenres = ["Live"]
        options.showDownloadedOnly = true

        let tracks = [
            makeTrack(id: "one", genres: ["Live"], downloaded: true),
            makeTrack(id: "two", genres: [], downloaded: true),
            makeTrack(id: "three", genres: ["Ambient"], downloaded: false)
        ]

        let filtered = MediaFilterEngine.filterTracks(tracks, with: options, configuration: .favorites)

        XCTAssertEqual(filtered.map(\.id), ["one", "two"])
    }

    func testAlbumConfigurationsPreserveLibraryAndArtistDetailBehavior() {
        var options = FilterOptions()
        options.searchText = "match"
        options.selectedGenres = ["Jazz"]
        options.excludedGenres = ["Live"]
        options.yearRange = 1990...2000
        options.selectedArtists = ["Selected Artist"]
        options.hideSingles = true

        let albums = [
            makeAlbum(id: "library", title: "Match Title", artist: "Selected Artist", albumArtist: nil, year: 1995, trackCount: 2, genres: ["Jazz"]),
            makeAlbum(id: "artist-search", title: "Other", artist: "Match Artist", albumArtist: "Selected Artist", year: 1995, trackCount: 2, genres: ["Jazz"]),
            makeAlbum(id: "artist-detail", title: "Match Detail", artist: "Other", albumArtist: nil, year: 1995, trackCount: 1, genres: ["Live"])
        ]

        XCTAssertEqual(
            MediaFilterEngine.filterAlbums(albums, with: options, configuration: .library).map(\.id),
            ["library", "artist-search"]
        )
        XCTAssertEqual(
            MediaFilterEngine.filterAlbums(albums, with: options, configuration: .artistDetail).map(\.id),
            ["library", "artist-detail"]
        )
    }

    func testAlbumFilterUsesSourceScopedDownloadedAlbumIDs() {
        var options = FilterOptions()
        options.showDownloadedOnly = true

        let sourceA = "plex:account:server:1"
        let sourceB = "plex:account:server:2"
        let albums = [
            makeAlbum(id: "album", sourceCompositeKey: sourceA),
            makeAlbum(id: "album", sourceCompositeKey: sourceB),
            makeAlbum(id: "other", sourceCompositeKey: sourceA)
        ]

        let filtered = MediaFilterEngine.filterAlbums(
            albums,
            with: options,
            downloadedAlbumIDs: ["\(sourceA)||album"]
        )

        XCTAssertEqual(filtered.map(\.sourceScopedID), ["\(sourceA)||album"])
    }

    func testArtistGenreFiltersUseAlbumGenreMap() {
        var options = FilterOptions()
        options.searchText = "artist"
        options.selectedGenres = ["Jazz"]
        options.excludedGenres = ["Live"]

        let artists = [
            makeArtist(id: "a1", name: "Artist One"),
            makeArtist(id: "a2", name: "Artist Two"),
            makeArtist(id: "a3", name: "Artist Three")
        ]
        let albums = [
            makeAlbum(id: "album-1", artistKey: "a1", genres: ["Jazz"]),
            makeAlbum(id: "album-2", artistKey: "a2", genres: ["Jazz", "Live"]),
            makeAlbum(id: "album-3", artistKey: "a3", genres: ["Rock"])
        ]

        let filtered = MediaFilterEngine.filterArtists(artists, with: options, albums: albums)

        XCTAssertEqual(filtered.map(\.id), ["a1"])
    }

    func testFavoriteFilterUsesTrackAlbumAndArtistFavoriteState() {
        var options = FilterOptions()
        options.favoriteFilter = .favorites

        let tracks = [
            makeTrack(id: "favorite", rating: 10),
            makeTrack(id: "disliked", rating: 2),
            makeTrack(id: "unrated")
        ]
        let albums = [
            makeAlbum(id: "favorite", artistKey: "favorite-artist", rating: 10),
            makeAlbum(id: "disliked", artistKey: "disliked-artist", rating: 2),
            makeAlbum(id: "unrated", artistKey: "unrated-artist")
        ]
        let artists = [
            makeArtist(id: "favorite-artist", name: "Favorite"),
            makeArtist(id: "disliked-artist", name: "Disliked"),
            makeArtist(id: "unrated-artist", name: "Unrated")
        ]

        XCTAssertEqual(MediaFilterEngine.filterTracks(tracks, with: options).map(\.id), ["favorite"])
        XCTAssertEqual(MediaFilterEngine.filterAlbums(albums, with: options).map(\.id), ["favorite"])
        XCTAssertEqual(MediaFilterEngine.filterArtists(artists, with: options, albums: albums).map(\.id), ["favorite-artist"])

        options.favoriteFilter = .disliked
        XCTAssertEqual(MediaFilterEngine.filterTracks(tracks, with: options).map(\.id), ["disliked"])
        XCTAssertEqual(MediaFilterEngine.filterAlbums(albums, with: options).map(\.id), ["disliked"])
        XCTAssertEqual(MediaFilterEngine.filterArtists(artists, with: options, albums: albums).map(\.id), ["disliked-artist"])
    }

    func testGenresFilterSearchesTitleOnly() {
        var options = FilterOptions()
        options.searchText = "rock"

        let genres = [
            Genre(id: "1", key: "1", title: "Rock"),
            Genre(id: "2", key: "2", title: "Jazz")
        ]

        XCTAssertEqual(MediaFilterEngine.filterGenres(genres, with: options).map(\.id), ["1"])
    }

    private func makeTrack(
        id: String,
        title: String = "Track",
        artist: String? = nil,
        album: String? = nil,
        genres: [String] = [],
        downloaded: Bool = false,
        rating: Int = 0
    ) -> Track {
        Track(
            id: id,
            key: "/tracks/\(id)",
            title: title,
            artistName: artist,
            albumName: album,
            localFilePath: downloaded ? "/tmp/\(id).mp3" : nil,
            rating: rating,
            genres: genres
        )
    }

    private func makeAlbum(
        id: String,
        title: String = "Album",
        artist: String? = nil,
        albumArtist: String? = nil,
        artistKey: String? = nil,
        year: Int? = nil,
        trackCount: Int = 0,
        genres: [String] = [],
        rating: Int = 0,
        sourceCompositeKey: String? = nil
    ) -> Album {
        Album(
            id: id,
            key: "/albums/\(id)",
            title: title,
            artistName: artist,
            albumArtist: albumArtist,
            artistRatingKey: artistKey,
            year: year,
            trackCount: trackCount,
            rating: rating,
            genres: genres,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeArtist(id: String, name: String) -> Artist {
        Artist(id: id, key: "/artists/\(id)", name: name)
    }
}
