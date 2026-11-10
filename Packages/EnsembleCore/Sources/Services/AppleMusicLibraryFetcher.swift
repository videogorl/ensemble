import EnsemblePersistence
import Foundation

/// Where the Apple Music library fetch reads from: the Apple Music REST API for the song list and
/// MusicKit for dates and play history. A seam so the completeness rule can be tested without a device.
protocol AppleMusicLibrarySource: Sendable {
    /// Whether the user still allows this app to read the Apple Music library.
    func isAuthorized() async -> Bool
    /// Every library song, following the API's `next` chain to its end. Throws on any failed page.
    func songs(progress: @Sendable (Double) -> Void) async throws -> AppleMusicSongList
    /// MusicKit's own enumeration of the library songs.
    func nativeMetadata() async throws -> NativeLibraryMetadataSnapshot
}

struct AppleMusicSongList: Sendable {
    var songs: [LibrarySong]
    /// The API's own total, when the first page carries one.
    var reportedTotal: Int?
}

enum AppleMusicLibraryError: Error, Equatable {
    case notAuthorized
}

/// A fetched Apple Music library: the batch for `LibraryWriter`, plus connector state learned on the way.
struct AppleMusicLibraryFetch: Sendable {
    var batch: LibraryBatch
    /// Nil when the pass did not read the library.
    var catalogIDsByLibraryID: [String: String]?
    /// Favourites the service now reports, so the connector can stop remembering them as pending.
    var confirmedFavoriteCatalogIDs: Set<String> = []
}

/// Reads the Apple Music library into a `LibraryBatch`. It never touches the store.
///
/// A batch carries an inventory, which lets `LibraryWriter` delete, only when the read is provably
/// complete. The REST list and MusicKit are two independent reads of the same library, so the list
/// is complete when all of these hold; otherwise the rows are written as a delta and nothing is deleted:
///
/// 1. The user was authorized before the first page and after the last, so a permission change
///    during the fetch cannot yield an inventory.
/// 2. Every page of both reads arrived. A thrown error, a cancelled request or a failed page ends the
///    pass with no batch at all.
/// 3. The REST total, when the API reports one, equals the number of songs received.
/// 4. Every song MusicKit lists is also in the REST list. MusicKit being larger than REST is the only
///    sign that a `next` chain ended early, since neither read reports a total of its own.
///
/// The writer separately refuses an inventory with no songs, so an empty library deletes nothing.
struct AppleMusicLibraryFetcher: Sendable {
    let source: AppleMusicLibrarySource

    func fetch(
        plan: LibrarySyncPlan,
        pendingFavoriteCatalogIDs: Set<String>,
        now: Date = Date(),
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AppleMusicLibraryFetch {
        // No change feed exists, so a pass that is not due for an inventory has nothing to read.
        var batch = LibraryBatch(queryStartedAt: now)
        // The source row's names are written with every batch, so every batch carries them.
        batch.sourceDisplayName = "Apple Music"
        batch.sourceAccountName = "This Device"
        if plan.since != nil, !plan.inventoryDue { return AppleMusicLibraryFetch(batch: batch) }

        guard await source.isAuthorized() else { throw AppleMusicLibraryError.notAuthorized }
        let list = try await source.songs { progress(0.1 + $0 * 0.4) }
        let native = try await source.nativeMetadata()
        try RefreshExecution.checkCancellation()
        guard await source.isAuthorized() else { throw AppleMusicLibraryError.notAuthorized }

        var seen = Set<String>()
        let songs = list.songs.filter { seen.insert($0.id).inserted }
        let artists = Self.artistUpsertInputs(
            from: songs, dateAddedByLibraryID: native.artistDateAddedByID, songMetadataByLibraryID: native.songsByID
        )
        let albums = Self.albumUpsertInputs(
            from: songs, dateAddedByLibraryID: native.albumDateAddedByID, songMetadataByLibraryID: native.songsByID
        )
        let tracks = songs.map { song in
            Self.trackUpsertInput(
                song,
                metadata: native.songsByID[song.id],
                isFavorite: song.attributes.inFavorites == true
                    || song.catalogID.map(pendingFavoriteCatalogIDs.contains) == true
            )
        }

        batch.artists = artists
        batch.albums = albums
        batch.tracks = tracks
        batch.inventory = Self.inventory(songs: songs, artists: artists, albums: albums, list: list, native: native)
        batch.isFullMetadataPass = true
        batch.tracksWithoutPlayHistory = Set(songs.lazy.map(\.id).filter { native.songsByID[$0] == nil })
        return AppleMusicLibraryFetch(
            batch: batch,
            catalogIDsByLibraryID: Dictionary(uniqueKeysWithValues: songs.compactMap { song in
                song.catalogID.map { (song.id, $0) }
            }),
            confirmedFavoriteCatalogIDs: Set(songs.compactMap { $0.attributes.inFavorites == true ? $0.catalogID : nil })
        )
    }

    /// The complete-inventory rule from the type documentation; nil when any condition fails.
    private static func inventory(
        songs: [LibrarySong],
        artists: [ArtistUpsertInput],
        albums: [AlbumUpsertInput],
        list: AppleMusicSongList,
        native: NativeLibraryMetadataSnapshot
    ) -> LibraryInventory? {
        if let total = list.reportedTotal, total != list.songs.count {
            EnsembleLogger.info("Apple Music inventory withheld: API total \(total), received \(list.songs.count)")
            return nil
        }
        let listed = Set(songs.map(\.id))
        let unlisted = native.songsByID.keys.filter { !listed.contains($0) }
        guard unlisted.isEmpty else {
            EnsembleLogger.info("Apple Music inventory withheld: MusicKit lists \(unlisted.count) songs the API list lacks")
            return nil
        }
        do {
            return try LibraryInventory(
                artistIDs: artists.map(\.ratingKey),
                albumIDs: albums.map(\.ratingKey),
                tracks: songs.map { ($0.id, $0.albumKey) }
            )
        } catch {
            EnsembleLogger.error("Apple Music inventory withheld: \(error)")
            return nil
        }
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

    static func trackUpsertInput(
        _ song: LibrarySong,
        metadata: NativeLibrarySongMetadata?,
        isFavorite: Bool
    ) -> TrackUpsertInput {
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
            dateAdded: metadata?.dateAdded ?? song.dateAdded,
            dateModified: nil,
            lastPlayed: metadata?.lastPlayed,
            rating: isFavorite ? 10 : nil,
            isFavorite: isFavorite,
            playCount: metadata?.playCount,
            genreNames: song.attributes.genreNames?.joined(separator: ", "),
            updatesDateAdded: true
        )
    }
}

struct NativeLibrarySongMetadata: Sendable, Equatable {
    let itemID: String
    let dateAdded: Date?
    let lastPlayed: Date?
    let playCount: Int?
}

struct NativeLibraryDateMetadata: Sendable, Equatable {
    let itemID: String
    let dateAdded: Date?
}

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

struct Page<Resource: Decodable>: Decodable {
    let data: [Resource]
    let next: String?
    let meta: Meta?

    struct Meta: Decodable { let total: Int? }
}

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

struct Artwork: Decodable { let url: String }

extension DateFormatter {
    static let appleMusicDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
