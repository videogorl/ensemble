import Foundation

/// Shared media filtering rules for library and detail surfaces.
/// Configurations make intentional per-surface differences explicit.
public struct MediaFilterEngine {
    public enum TrackSearchField: Hashable, Sendable {
        case title
        case artist
        case album
    }

    public struct TrackConfiguration: Sendable {
        public let searchFields: Set<TrackSearchField>
        public let filtersIncludedGenres: Bool
        public let filtersExcludedGenres: Bool
        public let filtersDownloadedOnly: Bool

        public init(
            searchFields: Set<TrackSearchField>,
            filtersIncludedGenres: Bool = false,
            filtersExcludedGenres: Bool = false,
            filtersDownloadedOnly: Bool = true
        ) {
            self.searchFields = searchFields
            self.filtersIncludedGenres = filtersIncludedGenres
            self.filtersExcludedGenres = filtersExcludedGenres
            self.filtersDownloadedOnly = filtersDownloadedOnly
        }

        public static let library = TrackConfiguration(
            searchFields: [.title, .artist, .album],
            filtersIncludedGenres: true,
            filtersExcludedGenres: true
        )
        public static let playlistDetail = library
        public static let favorites = TrackConfiguration(searchFields: [.title, .artist, .album])
        public static let albumDetail = TrackConfiguration(searchFields: [.title, .artist])
        public static let artistDetail = TrackConfiguration(searchFields: [.title, .album])
    }

    public enum AlbumSearchField: Hashable, Sendable {
        case title
        case artist
        case albumArtist
    }

    public struct AlbumConfiguration: Sendable {
        public let searchFields: Set<AlbumSearchField>
        public let filtersIncludedGenres: Bool
        public let filtersExcludedGenres: Bool
        public let filtersYearRange: Bool
        public let filtersSelectedArtists: Bool
        public let filtersSingles: Bool

        public init(
            searchFields: Set<AlbumSearchField>,
            filtersIncludedGenres: Bool = false,
            filtersExcludedGenres: Bool = false,
            filtersYearRange: Bool = true,
            filtersSelectedArtists: Bool = false,
            filtersSingles: Bool = false
        ) {
            self.searchFields = searchFields
            self.filtersIncludedGenres = filtersIncludedGenres
            self.filtersExcludedGenres = filtersExcludedGenres
            self.filtersYearRange = filtersYearRange
            self.filtersSelectedArtists = filtersSelectedArtists
            self.filtersSingles = filtersSingles
        }

        public static let library = AlbumConfiguration(
            searchFields: [.title, .artist, .albumArtist],
            filtersIncludedGenres: true,
            filtersExcludedGenres: true,
            filtersSelectedArtists: true,
            filtersSingles: true
        )
        public static let artistDetail = AlbumConfiguration(searchFields: [.title])
    }

    public init() {}

    public static func filterTracks(
        _ tracks: [Track],
        with options: FilterOptions,
        configuration: TrackConfiguration = .library
    ) -> [Track] {
        filterTrackGenres(
            filterTracksWithoutGenres(tracks, with: options, configuration: configuration),
            with: options, configuration: configuration
        )
    }

    static func filterTracksWithoutGenres(
        _ tracks: [Track], with options: FilterOptions, configuration: TrackConfiguration = .library
    ) -> [Track] {
        let searchLower = options.searchText.lowercased()
        guard !searchLower.isEmpty || options.favoriteFilter != nil ||
                (configuration.filtersDownloadedOnly && options.showDownloadedOnly) else { return tracks }
        return tracks.filter { track in
            if configuration.filtersDownloadedOnly && options.showDownloadedOnly && !track.isDownloaded { return false }
            if let favoriteFilter = options.favoriteFilter,
               !favoriteFilter.includes(rating: track.rating, isFavorite: track.isFavorite) { return false }
            return searchLower.isEmpty || trackMatchesSearch(track, searchLower: searchLower, fields: configuration.searchFields)
        }
    }

    static func filterTrackGenres(
        _ tracks: [Track], with options: FilterOptions, configuration: TrackConfiguration = .library
    ) -> [Track] {
        let includesGenres = configuration.filtersIncludedGenres && !options.selectedGenres.isEmpty
        let excludesGenres = configuration.filtersExcludedGenres && !options.excludedGenres.isEmpty
        guard includesGenres || excludesGenres else { return tracks }
        return tracks.filter { track in
            if includesGenres && options.selectedGenres.isDisjoint(with: track.genres) { return false }
            return !excludesGenres || (!track.genres.isEmpty && options.excludedGenres.isDisjoint(with: track.genres))
        }
    }

    public static func filterAlbums(
        _ albums: [Album],
        with options: FilterOptions,
        configuration: AlbumConfiguration = .library,
        downloadedAlbumIDs: Set<String>? = nil
    ) -> [Album] {
        var filtered = albums

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter { album in
                albumMatchesSearch(album, searchLower: searchLower, fields: configuration.searchFields)
            }
        }

        if configuration.filtersIncludedGenres, !options.selectedGenres.isEmpty {
            filtered = filtered.filter { !options.selectedGenres.isDisjoint(with: $0.genres) }
        }

        if configuration.filtersExcludedGenres, !options.excludedGenres.isEmpty {
            filtered = filtered.filter { !$0.genres.isEmpty && options.excludedGenres.isDisjoint(with: $0.genres) }
        }

        if configuration.filtersYearRange, let yearRange = options.yearRange {
            filtered = filtered.filter {
                guard let year = $0.year else { return false }
                return yearRange.contains(year)
            }
        }

        if configuration.filtersSelectedArtists, !options.selectedArtists.isEmpty {
            filtered = filtered.filter { album in
                options.selectedArtists.contains(album.artistName ?? "") ||
                    options.selectedArtists.contains(album.albumArtist ?? "")
            }
        }

        if configuration.filtersSingles, options.hideSingles {
            filtered = filtered.filter { $0.trackCount > 1 }
        }

        if options.showDownloadedOnly, let downloadedAlbumIDs {
            filtered = filtered.filter { downloadedAlbumIDs.contains($0.sourceScopedID) }
        }

        if let favoriteFilter = options.favoriteFilter {
            filtered = filtered.filter { favoriteFilter.includes(rating: $0.rating) }
        }

        return filtered
    }

    public static func filterArtists(
        _ artists: [Artist],
        with options: FilterOptions,
        albums: [Album] = []
    ) -> [Artist] {
        var filtered = artists

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter { $0.name.lowercased().contains(searchLower) }
        }

        if !options.selectedGenres.isEmpty || !options.excludedGenres.isEmpty {
            let artistGenres = genresByArtistID(from: albums)

            if !options.selectedGenres.isEmpty {
                filtered = filtered.filter { artist in
                    guard let genres = artistGenres[artist.sourceScopedID] else { return false }
                    return !options.selectedGenres.isDisjoint(with: genres)
                }
            }

            if !options.excludedGenres.isEmpty {
                filtered = filtered.filter { artist in
                    guard let genres = artistGenres[artist.sourceScopedID], !genres.isEmpty else { return false }
                    return options.excludedGenres.isDisjoint(with: genres)
                }
            }
        }

        if let favoriteFilter = options.favoriteFilter {
            let matchingArtistIDs = Set(albums.compactMap { album -> String? in
                guard favoriteFilter.includes(rating: album.rating),
                      let artistID = album.artistRatingKey else { return nil }
                return sourceScopedIdentity(ratingKey: artistID, sourceCompositeKey: album.sourceCompositeKey)
            })
            filtered = filtered.filter { matchingArtistIDs.contains($0.sourceScopedID) }
        }

        return filtered
    }

    public static func filterGenres(_ genres: [Genre], with options: FilterOptions) -> [Genre] {
        guard !options.searchText.isEmpty else { return genres }
        let normalizedSearch = DisplayGenre.normalizedTitle(options.searchText)
        return genres.filter { DisplayGenre.normalizedTitle($0.title).contains(normalizedSearch) }
    }

    private static func trackMatchesSearch(
        _ track: Track,
        searchLower: String,
        fields: Set<TrackSearchField>
    ) -> Bool {
        (fields.contains(.title) && track.title.lowercased().contains(searchLower)) ||
            (fields.contains(.artist) && (track.artistName?.lowercased().contains(searchLower) ?? false)) ||
            (fields.contains(.album) && (track.albumName?.lowercased().contains(searchLower) ?? false))
    }

    private static func albumMatchesSearch(
        _ album: Album,
        searchLower: String,
        fields: Set<AlbumSearchField>
    ) -> Bool {
        (fields.contains(.title) && album.title.lowercased().contains(searchLower)) ||
            (fields.contains(.artist) && (album.artistName?.lowercased().contains(searchLower) ?? false)) ||
            (fields.contains(.albumArtist) && (album.albumArtist?.lowercased().contains(searchLower) ?? false))
    }

    private static func genresByArtistID(from albums: [Album]) -> [String: Set<String>] {
        var artistGenres: [String: Set<String>] = [:]
        for album in albums {
            guard let artistKey = album.artistRatingKey, !album.genres.isEmpty else { continue }
            artistGenres[sourceScopedIdentity(ratingKey: artistKey, sourceCompositeKey: album.sourceCompositeKey), default: []].formUnion(album.genres)
        }
        return artistGenres
    }
}
