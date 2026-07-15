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
        var filtered = tracks

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter { track in
                trackMatchesSearch(track, searchLower: searchLower, fields: configuration.searchFields)
            }
        }

        if configuration.filtersIncludedGenres, !options.selectedGenres.isEmpty {
            filtered = filtered.filter { !options.selectedGenres.isDisjoint(with: $0.genres) }
        }

        if configuration.filtersExcludedGenres, !options.excludedGenres.isEmpty {
            filtered = filtered.filter { !$0.genres.isEmpty && options.excludedGenres.isDisjoint(with: $0.genres) }
        }

        if configuration.filtersDownloadedOnly, options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
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
                    guard let genres = artistGenres[artist.id] else { return false }
                    return !options.selectedGenres.isDisjoint(with: genres)
                }
            }

            if !options.excludedGenres.isEmpty {
                filtered = filtered.filter { artist in
                    guard let genres = artistGenres[artist.id], !genres.isEmpty else { return false }
                    return options.excludedGenres.isDisjoint(with: genres)
                }
            }
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
            artistGenres[artistKey, default: []].formUnion(album.genres)
        }
        return artistGenres
    }
}
