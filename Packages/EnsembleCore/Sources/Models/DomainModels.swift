import EnsemblePersistence
import Foundation

// Domain models for UI layer
//
// These models represent the app's business domain and are used throughout the UI.
// They are distinct from CoreData models (CD*) and API models (Plex*).
//
// Model Categories:
// - Core Media: `Track`, `Album`, `Artist` - Music content
// - Collections: `Genre`, `Playlist` - Content organization
// - Infrastructure: `Server`, `ServerConnection`, `Library` - Server configuration
// - Downloads: `Download`, `DownloadStatus` - Offline support
// - Discovery: `Hub`, `HubItem` - Home screen content sections
// - Sort Options: Various enums for sorting lists (TrackSortOption, AlbumSortOption, etc.)
//
// Model Conversion:
// - API models → Domain models: via PlexAPIClient in sync providers
// - CoreData models → Domain models: via ModelMappers
// - Domain models → CoreData models: via ModelMappers
//
// All models conform to Sendable for safe async/concurrent usage

func sourceScopedIdentity(ratingKey: String, sourceCompositeKey: String?) -> String {
    guard let sourceCompositeKey, !sourceCompositeKey.isEmpty else {
        return ratingKey
    }
    return "\(sourceCompositeKey)||\(ratingKey)"
}

// MARK: - Audio File Info

/// Audio format metadata fetched on demand from the Plex API.
/// Not persisted in CoreData — displayed on transient info surfaces.
public struct AudioFileInfo: Sendable, Equatable {
    public let filePath: String?
    public let codec: String? // e.g. "flac", "mp3", "aac"
    public let bitrate: Int? // kbps
    public let sampleRate: Int? // Hz, e.g. 44100, 96000
    public let bitDepth: Int? // e.g. 16, 24 (nil for lossy codecs)
    public let fileSize: Int? // bytes
    public let channels: Int? // e.g. 2 for stereo
    public let container: String? // e.g. "flac", "mp3"

    public init(filePath: String? = nil, codec: String?, bitrate: Int?, sampleRate: Int?, bitDepth: Int?, fileSize: Int?, channels: Int?, container: String?) {
        self.filePath = filePath
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileSize = fileSize
        self.channels = channels
        self.container = container
    }
}

/// Facts about the payload currently loaded by Ensemble's audio engine.
public struct PlaybackFileInfo: Sendable, Equatable {
    public let codec: String?
    public let fileSize: Int64?
    public let isDownloaded: Bool
    public let quality: String?
    public let sampleRate: Int?
}

// MARK: - Track

public struct Track: Identifiable, Hashable, Sendable, Codable {
    public let id: String // ratingKey
    public let key: String
    public let title: String
    public let artistName: String? // Track artist (originalTitle, falls back to album artist)
    public let albumArtistName: String? // Album artist (grandparentTitle)
    public let albumName: String?
    public let albumRatingKey: String?
    public let artistRatingKey: String?
    public let trackNumber: Int
    public let discNumber: Int
    public let duration: TimeInterval // Seconds
    public let thumbPath: String?
    public let fallbackThumbPath: String? // Album artwork as fallback
    public let fallbackRatingKey: String? // Album ratingKey
    public let streamKey: String?
    public let streamId: Int? // Audio stream ID for fetching loudness timeline data
    public let localFilePath: String?
    public let downloadedQuality: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let lastRatedAt: Date?
    public let rating: Int
    public let favoriteState: Bool?
    public let playCount: Int
    public let genres: [String]
    public let sourceCompositeKey: String?
    public let unavailableReason: String?
    public let actionCapabilities: MusicItemActionCapabilities?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        albumArtistName: String? = nil,
        albumName: String? = nil,
        albumRatingKey: String? = nil,
        artistRatingKey: String? = nil,
        trackNumber: Int = 0,
        discNumber: Int = 1,
        duration: TimeInterval = 0,
        thumbPath: String? = nil,
        fallbackThumbPath: String? = nil,
        fallbackRatingKey: String? = nil,
        streamKey: String? = nil,
        streamId: Int? = nil,
        localFilePath: String? = nil,
        downloadedQuality: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        lastPlayed: Date? = nil,
        lastRatedAt: Date? = nil,
        rating: Int = 0,
        favoriteState: Bool? = nil,
        playCount: Int = 0,
        genres: [String] = [],
        sourceCompositeKey: String? = nil,
        unavailableReason: String? = nil,
        actionCapabilities: MusicItemActionCapabilities? = nil
    ) {
        self.id = id
        self.key = key
        self.title = Self.normalizedTrackTitle(
            rawTitle: title,
            localFilePath: localFilePath,
            streamKey: streamKey
        )
        self.artistName = artistName
        self.albumArtistName = albumArtistName
        self.albumName = albumName
        self.albumRatingKey = albumRatingKey
        self.artistRatingKey = artistRatingKey
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.thumbPath = thumbPath
        self.fallbackThumbPath = fallbackThumbPath
        self.fallbackRatingKey = fallbackRatingKey
        self.streamKey = streamKey
        self.streamId = streamId
        self.localFilePath = localFilePath
        self.downloadedQuality = downloadedQuality
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.lastRatedAt = lastRatedAt
        self.rating = rating
        self.favoriteState = favoriteState
        self.playCount = playCount
        self.genres = genres
        self.sourceCompositeKey = sourceCompositeKey
        self.unavailableReason = unavailableReason
        self.actionCapabilities = actionCapabilities
    }

    public var isDownloaded: Bool {
        localFilePath != nil
    }

    public var isLibraryAvailable: Bool {
        unavailableReason == nil
    }

    public var formattedDuration: String {
        MediaFormatters.trackClock(duration)
    }

    /// Provider-normalized favorite state with legacy Plex rating fallback.
    public var isFavorite: Bool {
        favoriteState ?? (rating >= 8)
    }

    public func withRating(_ rating: Int) -> Track {
        copy(
            rating: rating,
            favoriteState: favoriteState == nil ? nil : rating >= 8,
            useFavoriteStateOverride: favoriteState != nil
        )
    }

    public func withLocalFilePath(_ localFilePath: String?) -> Track {
        copy(
            localFilePath: localFilePath,
            useLocalFilePathOverride: true,
            downloadedQuality: localFilePath.flatMap {
                AudioQualityPreference.fileQuality(at: URL(fileURLWithPath: $0))
            },
            useDownloadedQualityOverride: true
        )
    }

    public func withThumbPath(_ thumbPath: String?) -> Track {
        copy(thumbPath: thumbPath, useThumbPathOverride: true)
    }

    /// Stable UI identity that distinguishes the same Plex rating key across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }

    /// UI playback identity for row highlighting and other local current-track checks.
    /// Plex IDs include source scope; Apple library and catalog copies share catalog identity when known.
    public var playbackIdentity: String {
        if let catalogID = appleMusicCatalogID {
            return sourceScopedIdentity(ratingKey: catalogID, sourceCompositeKey: sourceCompositeKey)
        }
        return sourceScopedID
    }

    private static func normalizedTrackTitle(
        rawTitle: String,
        localFilePath: String?,
        streamKey: String?
    ) -> String {
        if let normalized = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return normalized
        }
        if let localFileName = filenameStem(fromPath: localFilePath) {
            return localFileName
        }
        if let streamFileName = filenameStem(fromPath: streamKey) {
            return streamFileName
        }
        // Diagnostic: log when we fall through to "Unknown Track" so we can
        // trace the source of empty titles (e.g. faulted CoreData objects)
        EnsembleLogger.debug(
            "[Track] normalizedTrackTitle fell through to 'Unknown Track' — rawTitle='\(rawTitle)', localFilePath=\(localFilePath ?? "nil"), streamKey=\(streamKey ?? "nil")"
        )
        return "Unknown Track"
    }

    private static func filenameStem(fromPath rawPath: String?) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return nil
        }

        if
            let components = URLComponents(string: rawPath),
            let path = components.percentEncodedPath.removingPercentEncoding,
            !path.isEmpty
        {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.nonEmpty
        }

        return URL(fileURLWithPath: rawPath).deletingPathExtension().lastPathComponent.nonEmpty
    }

    private func copy(
        rating: Int? = nil,
        favoriteState: Bool? = nil,
        useFavoriteStateOverride: Bool = false,
        thumbPath: String? = nil,
        useThumbPathOverride: Bool = false,
        localFilePath: String? = nil,
        useLocalFilePathOverride: Bool = false,
        downloadedQuality: String? = nil,
        useDownloadedQualityOverride: Bool = false
    ) -> Track {
        Track(
            id: id,
            key: key,
            title: title,
            artistName: artistName,
            albumArtistName: albumArtistName,
            albumName: albumName,
            albumRatingKey: albumRatingKey,
            artistRatingKey: artistRatingKey,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            thumbPath: useThumbPathOverride ? thumbPath : self.thumbPath,
            fallbackThumbPath: fallbackThumbPath,
            fallbackRatingKey: fallbackRatingKey,
            streamKey: streamKey,
            streamId: streamId,
            localFilePath: useLocalFilePathOverride ? localFilePath : self.localFilePath,
            downloadedQuality: useDownloadedQualityOverride ? downloadedQuality : self.downloadedQuality,
            dateAdded: dateAdded,
            dateModified: dateModified,
            lastPlayed: lastPlayed,
            lastRatedAt: lastRatedAt,
            rating: rating ?? self.rating,
            favoriteState: useFavoriteStateOverride ? favoriteState : self.favoriteState,
            playCount: playCount,
            genres: genres,
            sourceCompositeKey: sourceCompositeKey,
            unavailableReason: unavailableReason,
            actionCapabilities: actionCapabilities
        )
    }
}

/// A stable server playlist membership with an optional locally synced track.
public struct PlaylistItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let playlistItemID: String?
    public let track: Track

    public init(
        id: String,
        playlistItemID: String?,
        track: Track
    ) {
        self.id = id
        self.playlistItemID = playlistItemID
        self.track = track
    }

    public var isAvailable: Bool {
        track.isLibraryAvailable
    }
}

// MARK: - Album

public enum AlbumReleaseFormat: String, Sendable, Codable {
    case album
    case ep
    case single

    public init?(plexTag: String?) {
        guard let normalized = plexTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        else {
            return nil
        }

        switch normalized {
        case "album":
            self = .album
        case "ep":
            self = .ep
        case "single":
            self = .single
        default:
            return nil
        }
    }
}

public struct Album: Identifiable, Hashable, Sendable, Codable {
    public let id: String // ratingKey
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumArtist: String?
    public let artistRatingKey: String?
    public let year: Int?
    public let trackCount: Int
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let rating: Int
    public let genres: [String]
    public let sourceCompositeKey: String?
    public let releaseFormat: AlbumReleaseFormat?
    public let actionCapabilities: MusicItemActionCapabilities?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        albumArtist: String? = nil,
        artistRatingKey: String? = nil,
        year: Int? = nil,
        trackCount: Int = 0,
        thumbPath: String? = nil,
        artPath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        rating: Int = 0,
        genres: [String] = [],
        sourceCompositeKey: String? = nil,
        releaseFormat: AlbumReleaseFormat? = nil,
        actionCapabilities: MusicItemActionCapabilities? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumArtist = albumArtist
        self.artistRatingKey = artistRatingKey
        self.year = year
        self.trackCount = trackCount
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.rating = rating
        self.genres = genres
        self.sourceCompositeKey = sourceCompositeKey
        self.releaseFormat = releaseFormat
        self.actionCapabilities = actionCapabilities
    }

    /// Convenience initializer for radio/minimal album creation
    public init?(id: String?, title: String?, artistName: String?) {
        guard let id = id, let title = title else { return nil }
        self.init(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            artistName: artistName
        )
    }

    /// Stable UI identity that distinguishes the same Plex rating key across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }

    /// Includes browse metadata because equal IDs can move between source-scoped/date-sorted views.
    public static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.sourceScopedID == rhs.sourceScopedID &&
            lhs.key == rhs.key &&
            lhs.title == rhs.title &&
            lhs.artistName == rhs.artistName &&
            lhs.albumArtist == rhs.albumArtist &&
            lhs.artistRatingKey == rhs.artistRatingKey &&
            lhs.year == rhs.year &&
            lhs.trackCount == rhs.trackCount &&
            lhs.thumbPath == rhs.thumbPath &&
            lhs.artPath == rhs.artPath &&
            lhs.dateAdded == rhs.dateAdded &&
            lhs.dateModified == rhs.dateModified &&
            lhs.rating == rhs.rating &&
            lhs.genres == rhs.genres &&
            lhs.releaseFormat == rhs.releaseFormat &&
            lhs.actionCapabilities == rhs.actionCapabilities
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceScopedID)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Artist

public struct Artist: Identifiable, Hashable, Sendable, Codable {
    public let id: String // ratingKey
    public let key: String
    public let name: String
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let sourceCompositeKey: String?
    public let actionCapabilities: MusicItemActionCapabilities?

    // Fallback artwork from first album
    public let fallbackThumbPath: String?
    public let fallbackRatingKey: String?

    public init(
        id: String,
        key: String,
        name: String,
        summary: String? = nil,
        thumbPath: String? = nil,
        artPath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        sourceCompositeKey: String? = nil,
        fallbackThumbPath: String? = nil,
        fallbackRatingKey: String? = nil,
        actionCapabilities: MusicItemActionCapabilities? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.sourceCompositeKey = sourceCompositeKey
        self.fallbackThumbPath = fallbackThumbPath
        self.fallbackRatingKey = fallbackRatingKey
        self.actionCapabilities = actionCapabilities
    }

    /// Convenience initializer for radio/minimal artist creation
    public init?(id: String?, name: String?) {
        guard let id = id, let name = name else { return nil }
        self.init(
            id: id,
            key: "/library/metadata/\(id)",
            name: name
        )
    }

    /// Stable UI identity that distinguishes the same Plex rating key across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }
}

public extension Album {
    /// Artist detail grouping from Plex's release format metadata.
    func isLikelySingleOrEP() -> Bool {
        releaseFormat == .single || releaseFormat == .ep
    }
}

// MARK: - Artist Detail (enriched metadata)

/// Rich artist metadata fetched on-demand from the single-item metadata endpoint.
/// Contains tag-based fields (genres, country, similar artists, styles) and external
/// identifiers (MusicBrainz, Last.fm) not available in the lightweight section listing.
public struct ArtistDetail: Sendable {
    public let genres: [String]
    public let country: String?
    public let similarArtists: [String]
    public let styles: [String]

    /// Wikipedia URL derived from the artist name
    public var wikipediaURL: URL? {
        // URL-encode the artist name for Wikipedia lookup
        let encoded = artistName
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        guard let encoded else { return nil }
        return URL(string: "https://en.wikipedia.org/wiki/\(encoded)")
    }

    /// Artist name (needed for Wikipedia URL generation)
    public let artistName: String

    public init(
        genres: [String] = [],
        country: String? = nil,
        similarArtists: [String] = [],
        styles: [String] = [],
        artistName: String = ""
    ) {
        self.genres = genres
        self.country = country
        self.similarArtists = similarArtists
        self.styles = styles
        self.artistName = artistName
    }
}

// MARK: - Album Detail (enriched metadata)

/// Rich album metadata fetched on-demand from the single-item metadata endpoint.
/// Contains tag-based fields (genres, styles, studio/label) not available in
/// the lightweight section listing.
public struct AlbumDetail: Sendable {
    public let genres: [String]
    public let styles: [String]
    public let studio: String? // Record label
    public let summary: String?
    public let albumTitle: String
    public let artistName: String?

    /// Wikipedia URL derived from the album title and artist name.
    /// Uses "{Album}_({Artist}_album)" format per Wikipedia convention to avoid disambiguation pages.
    /// Falls back to "{Album}_(album)" for compilations or when artist is unknown.
    public var wikipediaURL: URL? {
        let titlePart = albumTitle
            .replacingOccurrences(of: " ", with: "_")

        // Include artist name in the suffix unless it's a compilation or unknown
        let suffix: String
        if let artist = artistName, artist != "Various Artists" {
            let artistPart = artist.replacingOccurrences(of: " ", with: "_")
            suffix = "_(\(artistPart)_album)"
        } else {
            suffix = "_(album)"
        }

        let combined = "\(titlePart)\(suffix)"
        guard let encoded = combined.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/wiki/\(encoded)")
    }

    public init(
        genres: [String] = [],
        styles: [String] = [],
        studio: String? = nil,
        summary: String? = nil,
        albumTitle: String = "",
        artistName: String? = nil
    ) {
        self.genres = genres
        self.styles = styles
        self.studio = studio
        self.summary = summary
        self.albumTitle = albumTitle
        self.artistName = artistName
    }
}

// MARK: - Genre

public struct Genre: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let key: String
    public let title: String
    public let sourceCompositeKey: String?

    public init(id: String, key: String, title: String, sourceCompositeKey: String? = nil) {
        self.id = id
        self.key = key
        self.title = title
        self.sourceCompositeKey = sourceCompositeKey
    }

    /// Stable UI identity that distinguishes the same Plex genre key across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }
}

/// UI genre entry that can represent one physical genre or a merged same-name group.
public struct DisplayGenre: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let genres: [Genre]

    public var isMerged: Bool { genres.count > 1 }
    public var primaryGenre: Genre { genres[0] }
    public var sourceKeys: [String] { genres.compactMap(\.sourceCompositeKey) }

    public init(id: String, title: String, genres: [Genre]) {
        precondition(!genres.isEmpty, "DisplayGenre requires at least one backing genre")
        self.id = id
        self.title = title
        self.genres = genres
    }

    public static func single(_ genre: Genre) -> DisplayGenre {
        DisplayGenre(
            id: "single:\(genre.sourceScopedID)",
            title: genre.title,
            genres: [genre]
        )
    }

    public static func merged(title: String, normalizedTitle: String, genres: [Genre]) -> DisplayGenre {
        DisplayGenre(
            id: "merged:\(normalizedTitle)",
            title: title,
            genres: genres
        )
    }

    /// Groups visible genres by normalized display title while preserving backing source items.
    public static func group(_ genres: [Genre]) -> [DisplayGenre] {
        var groups: [(normalizedTitle: String, title: String, genres: [Genre])] = []
        var indexByTitle: [String: Int] = [:]

        for genre in genres {
            let normalizedTitle = Self.normalizedTitle(genre.title)
            if let index = indexByTitle[normalizedTitle] {
                groups[index].genres.append(genre)
            } else {
                indexByTitle[normalizedTitle] = groups.count
                groups.append((normalizedTitle: normalizedTitle, title: genre.title, genres: [genre]))
            }
        }

        return groups.map { group in
            if group.genres.count == 1 {
                return .single(group.genres[0])
            }
            return .merged(
                title: group.title,
                normalizedTitle: group.normalizedTitle,
                genres: group.genres
            )
        }
    }

    public static func normalizedTitle(_ title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    public func matches(album: Album) -> Bool {
        let normalizedDisplayTitle = Self.normalizedTitle(title)
        return album.genres.contains { albumGenre in
            Self.normalizedTitle(albumGenre) == normalizedDisplayTitle
        }
    }
}

// MARK: - Mood

public struct Mood: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let key: String
    public let title: String
    public let sourceCompositeKey: String?

    public struct SourceReference: Hashable, Sendable {
        public let sourceCompositeKey: String
        public let moodKey: String?
    }

    private static let sourceReferenceSeparator = "#moodKey="

    public init(id: String, key: String, title: String, sourceCompositeKey: String? = nil) {
        self.id = id
        self.key = key
        self.title = title
        self.sourceCompositeKey = sourceCompositeKey
    }

    public static func normalizedTitleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    public static func sourceCompositeKeys(from sourceCompositeKey: String?) -> Set<String> {
        Set(sourceReferences(from: sourceCompositeKey).map(\.sourceCompositeKey))
    }

    public static func sourceReference(sourceCompositeKey: String, moodKey: String?) -> String {
        guard let moodKey, !moodKey.isEmpty else { return sourceCompositeKey }
        return "\(sourceCompositeKey)\(sourceReferenceSeparator)\(moodKey)"
    }

    public static func sourceReferences(from sourceCompositeKey: String?) -> [SourceReference] {
        guard let sourceCompositeKey, !sourceCompositeKey.isEmpty else { return [] }
        return sourceCompositeKey.split(separator: "|").compactMap { rawPart in
            let part = String(rawPart)
            guard !part.isEmpty else { return nil }
            if let separatorRange = part.range(of: sourceReferenceSeparator) {
                let sourceKey = String(part[..<separatorRange.lowerBound])
                let moodKey = String(part[separatorRange.upperBound...])
                guard !sourceKey.isEmpty else { return nil }
                return SourceReference(
                    sourceCompositeKey: sourceKey,
                    moodKey: moodKey.isEmpty ? nil : moodKey
                )
            }
            return SourceReference(sourceCompositeKey: part, moodKey: nil)
        }
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Hashable, Sendable, Codable {
    public let id: String // ratingKey
    public let key: String
    public let title: String
    public let summary: String?
    public let isSmart: Bool
    public let trackCount: Int
    public let duration: TimeInterval
    public let compositePath: String?
    public let fallbackArtworkPath: String?
    public let fallbackArtworkRatingKey: String?
    public let fallbackArtworkSourceCompositeKey: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let sourceCompositeKey: String?
    public let actionCapabilities: PlaylistActionCapabilities?

    public init(
        id: String,
        key: String,
        title: String,
        summary: String? = nil,
        isSmart: Bool = false,
        trackCount: Int = 0,
        duration: TimeInterval = 0,
        compositePath: String? = nil,
        fallbackArtworkPath: String? = nil,
        fallbackArtworkRatingKey: String? = nil,
        fallbackArtworkSourceCompositeKey: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        lastPlayed: Date? = nil,
        sourceCompositeKey: String? = nil,
        actionCapabilities: PlaylistActionCapabilities? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.summary = summary
        self.isSmart = isSmart
        self.trackCount = trackCount
        self.duration = duration
        self.compositePath = compositePath
        self.fallbackArtworkPath = fallbackArtworkPath
        self.fallbackArtworkRatingKey = fallbackArtworkRatingKey
        self.fallbackArtworkSourceCompositeKey = fallbackArtworkSourceCompositeKey
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.sourceCompositeKey = sourceCompositeKey
        self.actionCapabilities = actionCapabilities
    }

    /// Returns a renamed copy while preserving source-resolved metadata and capabilities.
    public func withTitle(_ title: String, dateModified: Date? = nil) -> Playlist {
        Playlist(
            id: id,
            key: key,
            title: title,
            summary: summary,
            isSmart: isSmart,
            trackCount: trackCount,
            duration: duration,
            compositePath: compositePath,
            fallbackArtworkPath: fallbackArtworkPath,
            fallbackArtworkRatingKey: fallbackArtworkRatingKey,
            fallbackArtworkSourceCompositeKey: fallbackArtworkSourceCompositeKey,
            dateAdded: dateAdded,
            dateModified: dateModified ?? self.dateModified,
            lastPlayed: lastPlayed,
            sourceCompositeKey: sourceCompositeKey,
            actionCapabilities: actionCapabilities
        )
    }

    /// Returns a copy with updated track-derived metadata while preserving source metadata.
    public func withTracks(_ tracks: [Track], dateModified: Date = Date()) -> Playlist {
        Playlist(
            id: id,
            key: key,
            title: title,
            summary: summary,
            isSmart: isSmart,
            trackCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            compositePath: compositePath,
            fallbackArtworkPath: fallbackArtworkPath,
            fallbackArtworkRatingKey: fallbackArtworkRatingKey,
            fallbackArtworkSourceCompositeKey: fallbackArtworkSourceCompositeKey,
            dateAdded: dateAdded,
            dateModified: dateModified,
            lastPlayed: lastPlayed,
            sourceCompositeKey: sourceCompositeKey,
            actionCapabilities: actionCapabilities
        )
    }

    public var formattedDuration: String {
        MediaFormatters.collectionDuration(duration)
    }

    /// Stable UI identity that distinguishes the same Plex playlist rating key across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }

    public var sourceType: MusicSourceType? {
        MediaSourceIdentity.parse(sourceCompositeKey)?.sourceType
    }

    public var isSmartForPlaylistGrouping: Bool {
        isSmart
    }

    public var supportsPlaylistTrackAdds: Bool {
        resolvedActionCapabilities.canAddItems
    }

    public var supportsPlaylistEditing: Bool {
        supportsPlaylistRenaming || supportsPlaylistReordering
    }

    public var supportsPlaylistRenaming: Bool {
        resolvedActionCapabilities.canRename
    }

    public var supportsPlaylistReordering: Bool {
        resolvedActionCapabilities.canReorder
    }

    public var supportsPlaylistDeletion: Bool {
        resolvedActionCapabilities.canDelete
    }

    public var playlistEditingUnavailableReason: String? {
        guard !supportsPlaylistEditing else { return nil }
        return resolvedActionCapabilities.unavailableReason
            ?? (isSmart ? "Smart playlists are read-only." : "This playlist is read-only.")
    }

    public static func markAppleMusicPlaylistCreated(id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: appleMusicCreatedPlaylistIDsKey) ?? [])
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: appleMusicCreatedPlaylistIDsKey)
    }

    public static func appleMusicPlaylistWasCreatedByEnsemble(_ id: String) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: appleMusicCreatedPlaylistIDsKey) ?? []).contains(id)
    }

    static func clearAppleMusicPlaylistCapabilityCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: appleMusicCreatedPlaylistIDsKey)
        defaults.removeObject(forKey: legacyAppleMusicEditablePlaylistIDsKey)
    }

    private static let appleMusicCreatedPlaylistIDsKey = "appleMusicCreatedPlaylistIDs"
    private static let legacyAppleMusicEditablePlaylistIDsKey = "appleMusicEditablePlaylistIDs"

    var resolvedActionCapabilities: PlaylistActionCapabilities {
        guard sourceType != nil else {
            return PlaylistActionCapabilities(
                canAddItems: false,
                canRename: false,
                canReorder: false,
                canDelete: false,
                unavailableReason: "This playlist’s music source is unknown."
            )
        }
        if let actionCapabilities {
            return actionCapabilities
        }
        if isSmart {
            return PlaylistActionCapabilities(
                canAddItems: false,
                canRename: false,
                canReorder: false,
                canDelete: false,
                unavailableReason: "Smart playlists are read-only."
            )
        }
        let supportsMutations = sourceType?.capabilities.supportsRegularPlaylistMutationsByDefault == true
        return PlaylistActionCapabilities(
            canAddItems: supportsMutations,
            canRename: supportsMutations,
            canReorder: supportsMutations,
            canDelete: supportsMutations,
            unavailableReason: supportsMutations ? nil : "This playlist’s permissions are unavailable."
        )
    }

    /// Includes header metadata because equal IDs can update in place during source sync.
    public static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.sourceScopedID == rhs.sourceScopedID &&
            lhs.key == rhs.key &&
            lhs.title == rhs.title &&
            lhs.summary == rhs.summary &&
            lhs.trackCount == rhs.trackCount &&
            lhs.duration == rhs.duration &&
            lhs.compositePath == rhs.compositePath &&
            lhs.fallbackArtworkPath == rhs.fallbackArtworkPath &&
            lhs.fallbackArtworkRatingKey == rhs.fallbackArtworkRatingKey &&
            lhs.fallbackArtworkSourceCompositeKey == rhs.fallbackArtworkSourceCompositeKey &&
            lhs.isSmart == rhs.isSmart &&
            lhs.dateAdded == rhs.dateAdded &&
            lhs.dateModified == rhs.dateModified &&
            lhs.lastPlayed == rhs.lastPlayed &&
            lhs.sourceCompositeKey == rhs.sourceCompositeKey &&
            lhs.actionCapabilities == rhs.actionCapabilities
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceScopedID)
    }
}

// MARK: - Server

public struct Server: Identifiable, Hashable, Sendable, Codable {
    public let id: String // clientIdentifier
    public let name: String
    public let url: String
    public let connections: [ServerConnection]
    public let accessToken: String?
    public let platform: String?
    public let isLocal: Bool

    public init(
        id: String,
        name: String,
        url: String,
        connections: [ServerConnection] = [],
        accessToken: String? = nil,
        platform: String? = nil,
        isLocal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.connections = connections
        self.accessToken = accessToken
        self.platform = platform
        self.isLocal = isLocal
    }
}

public struct ServerConnection: Identifiable, Hashable, Sendable, Codable {
    public let id: String // uri
    public let uri: String
    public let local: Bool
    public let relay: Bool
    public let address: String?
    public let port: Int?
    public let `protocol`: String?

    public init(
        uri: String,
        local: Bool,
        relay: Bool = false,
        address: String? = nil,
        port: Int? = nil,
        protocol: String? = nil
    ) {
        id = uri
        self.uri = uri
        self.local = local
        self.relay = relay
        self.address = address
        self.port = port
        self.protocol = `protocol`
    }
}

// MARK: - Library

public struct Library: Identifiable, Hashable, Sendable, Codable {
    public let id: String // key
    public let key: String
    public let title: String
    public let type: String

    public init(
        id: String,
        key: String,
        title: String,
        type: String
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.type = type
    }
}

// MARK: - Download

public struct Download: Identifiable, Sendable {
    public let id: String // Track ratingKey
    public let track: Track
    public let status: DownloadStatus
    public let progress: Float
    public let filePath: String?
    public let fileSize: Int64
    public let error: String?

    public init(
        id: String,
        track: Track,
        status: DownloadStatus,
        progress: Float = 0,
        filePath: String? = nil,
        fileSize: Int64 = 0,
        error: String? = nil
    ) {
        self.id = id
        self.track = track
        self.status = status
        self.progress = progress
        self.filePath = filePath
        self.fileSize = fileSize
        self.error = error
    }
}

public enum DownloadStatus: String, Sendable {
    case pending
    case downloading
    case completed
    case failed
    case paused
}

// MARK: - Sorting Utilities

public extension String {
    /// Returns the string with leading "The", "A", or "An" removed for sorting purposes
    var sortingKey: String {
        let prefixes = ["the ", "a ", "an "]
        let lowercased = self.lowercased()

        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                return String(dropFirst(prefix.count))
            }
        }
        return self
    }

    /// Returns the first character for indexing, handling "The" prefix and ignoring common punctuation
    var indexingLetter: String {
        let key = sortingKey

        // Characters to ignore when determining the indexing letter
        let ignoredCharacters = CharacterSet(charactersIn: "\"'()[]")

        // Find the first character that isn't in the ignored set
        var cleanedKey = key
        while let firstChar = cleanedKey.first {
            guard let firstScalar = firstChar.unicodeScalars.first else { break }
            guard ignoredCharacters.contains(firstScalar) else { break }
            cleanedKey = String(cleanedKey.dropFirst())
        }

        // If we've removed everything, fall back to original key
        if cleanedKey.isEmpty {
            cleanedKey = key
        }

        let firstChar = cleanedKey.prefix(1).uppercased()

        // Return # for non-alphabetic characters (includes numbers)
        if firstChar.rangeOfCharacter(from: .letters) == nil {
            return "#"
        }
        return firstChar
    }

    /// Returns a display-friendly possessive form for names and labels.
    var possessiveForm: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasSuffix("'") || trimmed.hasSuffix("’") {
            return trimmed
        }

        if let lastScalar = trimmed.unicodeScalars.last,
           CharacterSet.letters.contains(lastScalar),
           String(lastScalar).caseInsensitiveCompare("s") == .orderedSame
        {
            return trimmed + "'"
        }

        return trimmed + "'s"
    }

    /// Removes decorative emoji/symbol scalars while preserving readable text.
    var textualDisplayName: String {
        let filteredScalars = unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
                return false
            }

            switch scalar.properties.generalCategory {
            case .otherSymbol, .modifierSymbol, .mathSymbol, .currencySymbol:
                return false
            default:
                return true
            }
        }

        return String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sort Options

public enum TrackSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case duration = "Duration"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case lastPlayed = "Last Played"
    case rating = "Rating"
    case playCount = "Play Count"

    public var defaultDirection: SortDirection {
        switch self {
        case .title, .artist, .album:
            return .ascending
        case .duration, .dateAdded, .dateModified, .lastPlayed, .rating, .playCount:
            return .descending
        }
    }
}

public enum ArtistSortOption: String, CaseIterable, Sendable {
    case name = "Name"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"

    public var defaultDirection: SortDirection {
        switch self {
        case .name:
            return .ascending
        case .dateAdded, .dateModified:
            return .descending
        }
    }
}

public enum AlbumSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case albumArtist = "Album Artist"
    case year = "Year"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case rating = "Rating"

    public var defaultDirection: SortDirection {
        switch self {
        case .title, .artist, .albumArtist:
            return .ascending
        case .year, .dateAdded, .dateModified, .rating:
            return .descending
        }
    }
}

public enum GenreSortOption: String, CaseIterable, Sendable {
    case title = "Title"
}

public enum PlaylistSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case trackCount = "Track Count"
    case duration = "Duration"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case lastPlayed = "Last Played"

    public var defaultDirection: SortDirection {
        switch self {
        case .title:
            return .ascending
        case .trackCount, .duration, .dateAdded, .dateModified, .lastPlayed:
            return .descending
        }
    }
}

public enum FavoritesSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case dateFavorited = "Date Favorited"
    case duration = "Duration"
    case lastPlayed = "Last Played"
    case rating = "Rating"
    case playCount = "Play Count"

    /// Natural default direction for each sort option
    public var defaultDirection: SortDirection {
        switch self {
        case .title, .artist, .album:
            return .ascending
        case .dateFavorited, .lastPlayed, .duration, .rating, .playCount:
            return .descending
        }
    }
}

// MARK: - Hub (Home Screen Content)

/// Provider-normalized meaning used to merge and order Feed sections.
public struct HubSemanticKind: RawRepresentable, Codable, Hashable, Sendable {
    public static let recentlyAdded = HubSemanticKind(rawValue: "music.recent.added")
    public static let recentlyPlayed = HubSemanticKind(rawValue: "music.recent.played")
    public static let mostPlayed = HubSemanticKind(rawValue: "music.popular")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a stable semantic identity at the provider mapping boundary.
    public static func provider(
        identifier: String,
        title: String,
        context: String? = nil
    ) -> HubSemanticKind {
        if identifier.contains("#") {
            return HubSemanticKind(rawValue: identifier)
        }
        let normalizedIdentifier = normalizedProviderIdentifier(identifier)
        switch normalizedIdentifier {
        case recentlyAdded.rawValue:
            return .recentlyAdded
        case recentlyPlayed.rawValue:
            return .recentlyPlayed
        case mostPlayed.rawValue:
            return .mostPlayed
        default:
            let disambiguator = [context, title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "|")
            return HubSemanticKind(
                rawValue: disambiguator.isEmpty
                    ? normalizedIdentifier
                    : "\(normalizedIdentifier)#\(disambiguator)"
            )
        }
    }

    public var mergesAcrossSources: Bool {
        self == .recentlyAdded || self == .recentlyPlayed || self == .mostPlayed
    }

    public func displayTitle(fallback: String) -> String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        default: return fallback
        }
    }

    static func legacy(hubID: String, title: String, context: String? = nil) -> HubSemanticKind {
        provider(identifier: providerIdentifier(from: hubID), title: title, context: context)
    }

    static func providerIdentifier(from hubID: String) -> String {
        let components = hubID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if components.count >= 5 {
            if components[3] == "merged" {
                return components[4]
            }
            return components[4...].joined(separator: ":")
        }
        return hubID
    }

    private static func normalizedProviderIdentifier(_ identifier: String) -> String {
        guard let lastDot = identifier.lastIndex(of: ".") else { return identifier }
        let suffix = identifier[identifier.index(after: lastDot)...]
        return suffix.allSatisfy(\.isNumber) ? String(identifier[..<lastDot]) : identifier
    }
}

/// Explicit provider/source ownership used by Feed grouping.
public struct HubSourceScope: Codable, Hashable, Sendable {
    public static let global = HubSourceScope(sourceCompositeKey: nil, serverCompositeKey: nil)

    public let sourceCompositeKey: String?
    public let serverCompositeKey: String?

    public init(source: MusicSourceIdentifier) {
        self.init(
            sourceCompositeKey: source.compositeKey,
            serverCompositeKey: MediaSourceIdentity.serverSourceKey(for: source)
        )
    }

    public init(sourceCompositeKey: String?, serverCompositeKey: String? = nil) {
        self.sourceCompositeKey = sourceCompositeKey
        self.serverCompositeKey = serverCompositeKey
            ?? MediaSourceIdentity.serverSourceKey(from: sourceCompositeKey)
    }

    public static func server(_ serverCompositeKey: String) -> HubSourceScope {
        HubSourceScope(sourceCompositeKey: nil, serverCompositeKey: serverCompositeKey)
    }
}

/// Represents a section on the home screen
public struct Hub: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let type: String
    public let items: [HubItem]
    public let context: String? // Plex hub context (e.g. "hub.music.artist" for artist-scoped hubs)
    public let semanticKind: HubSemanticKind
    public let sourceScope: HubSourceScope

    public init(
        id: String,
        title: String,
        type: String,
        items: [HubItem],
        context: String? = nil,
        semanticKind: HubSemanticKind? = nil,
        sourceScope: HubSourceScope? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.items = items
        self.context = context
        self.semanticKind = semanticKind ?? .legacy(hubID: id, title: title, context: context)
        self.sourceScope = sourceScope ?? HubSourceScope(sourceCompositeKey: items.first?.sourceCompositeKey)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, type, items, context, semanticKind, sourceScope
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let title = try values.decode(String.self, forKey: .title)
        let items = try values.decode([HubItem].self, forKey: .items)
        self.init(
            id: id,
            title: title,
            type: try values.decode(String.self, forKey: .type),
            items: items,
            context: try values.decodeIfPresent(String.self, forKey: .context),
            semanticKind: try values.decodeIfPresent(HubSemanticKind.self, forKey: .semanticKind),
            sourceScope: try values.decodeIfPresent(HubSourceScope.self, forKey: .sourceScope)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(type, forKey: .type)
        try values.encode(items, forKey: .items)
        try values.encodeIfPresent(context, forKey: .context)
        try values.encode(semanticKind, forKey: .semanticKind)
        try values.encode(sourceScope, forKey: .sourceScope)
    }

    /// Artist ratingKey for artist-scoped hubs (e.g. "More by Dune Moss").
    /// Uses the Plex `context` field to identify artist hubs, then extracts the
    /// artist ratingKey from the first album/track item's parentRatingKey.
    /// Also handles "More from" / "More by" titled hubs where the context field
    /// may not contain ".artist" but the content is clearly artist-scoped.
    /// Returns nil for non-artist hubs (genre, label, general, etc.).
    public var contextArtistId: String? {
        // Check 1: Plex context field explicitly identifies artist-scoped hubs
        let isArtistContext = context?.contains(".artist") == true

        // Check 2: Title-based detection for "More from X" / "More by X" hubs
        // where Plex doesn't set an artist context
        let lowercasedTitle = title.lowercased()
        let isMoreFromHub = lowercasedTitle.hasPrefix("more from") || lowercasedTitle.hasPrefix("more by")

        guard isArtistContext || isMoreFromHub else { return nil }

        // Get artist ratingKey from the first item
        guard let first = items.first else { return nil }
        return first.album?.artistRatingKey ?? first.track?.artistRatingKey
    }

    /// Source key for the artist represented by `contextArtistId`.
    public var contextArtistSourceCompositeKey: String? {
        guard contextArtistId != nil, let first = items.first else { return nil }
        return first.album?.sourceCompositeKey
            ?? first.track?.sourceCompositeKey
            ?? first.artist?.sourceCompositeKey
            ?? first.sourceCompositeKey
    }
}

/// Item within a hub (can be album, track, or playlist)
public struct HubItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let type: String // "album", "track", "playlist"
    public let title: String
    public let subtitle: String? // Artist name
    public let thumbPath: String?
    public let year: Int?
    public let sourceCompositeKey: String
    public let addedAt: Date?
    public let lastViewedAt: Date?
    public let viewCount: Int?

    // Reference to actual domain object
    public let album: Album?
    public let track: Track?
    public let artist: Artist?
    public let playlist: Playlist?

    /// Stable UI identity that distinguishes the same Plex item across sources.
    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
    }

    /// Helper to get the date added from the underlying media object
    public var dateAdded: Date? {
        addedAt ?? album?.dateAdded ?? track?.dateAdded ?? artist?.dateAdded ?? playlist?.dateAdded
    }

    public init(
        id: String,
        type: String,
        title: String,
        subtitle: String?,
        thumbPath: String?,
        year: Int?,
        sourceCompositeKey: String,
        addedAt: Date? = nil,
        lastViewedAt: Date? = nil,
        viewCount: Int? = nil,
        album: Album? = nil,
        track: Track? = nil,
        artist: Artist? = nil,
        playlist: Playlist? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.thumbPath = thumbPath
        self.year = year
        self.sourceCompositeKey = sourceCompositeKey
        self.addedAt = addedAt
        self.lastViewedAt = lastViewedAt
        self.viewCount = viewCount
        self.album = album
        self.track = track
        self.artist = artist
        self.playlist = playlist
    }
}
