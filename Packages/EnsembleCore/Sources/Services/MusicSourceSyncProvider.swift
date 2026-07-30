import EnsemblePersistence
import EnsembleAPI
import Foundation

public struct LibrarySyncResult: Sendable, Equatable {
    public let changedArtists: Int
    public let changedAlbums: Int
    public let changedTracks: Int
    public let changedGenres: Int
    public let removedArtists: Int
    public let removedAlbums: Int
    public let removedTracks: Int
    public let removedGenres: Int

    public init(
        changedArtists: Int = 0,
        changedAlbums: Int = 0,
        changedTracks: Int = 0,
        changedGenres: Int = 0,
        removedArtists: Int = 0,
        removedAlbums: Int = 0,
        removedTracks: Int = 0,
        removedGenres: Int = 0
    ) {
        self.changedArtists = changedArtists
        self.changedAlbums = changedAlbums
        self.changedTracks = changedTracks
        self.changedGenres = changedGenres
        self.removedArtists = removedArtists
        self.removedAlbums = removedAlbums
        self.removedTracks = removedTracks
        self.removedGenres = removedGenres
    }

    public var hasMaterialChanges: Bool {
        changedArtists > 0 || changedAlbums > 0 || changedTracks > 0 || changedGenres > 0 ||
        removedArtists > 0 || removedAlbums > 0 || removedTracks > 0 || removedGenres > 0
    }
}

public struct PlaylistSyncResult: Sendable, Equatable {
    public let changedPlaylists: Int
    public let removedPlaylists: Int

    public init(changedPlaylists: Int = 0, removedPlaylists: Int = 0) {
        self.changedPlaylists = changedPlaylists
        self.removedPlaylists = removedPlaylists
    }

    public var hasMaterialChanges: Bool {
        changedPlaylists > 0 || removedPlaylists > 0
    }
}

/// Normalized Feed result that preserves successful sections while identifying failed ones.
public struct MusicSourceHubFetchResult: Sendable, Equatable {
    public let hubs: [Hub]
    public let failedSemanticKinds: Set<HubSemanticKind>

    public init(hubs: [Hub], failedSemanticKinds: Set<HubSemanticKind> = []) {
        self.hubs = hubs
        self.failedSemanticKinds = failedSemanticKinds
    }
}

/// Resolves source-owned playback without coupling sync callers to transport details.
public protocol MusicSourcePlaybackResolving: Sendable {
    func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution
}

/// Resolves endpoint-independent playback decisions and download URLs when supported.
public protocol MusicSourceTwoPhasePlaybackResolving: MusicSourcePlaybackResolving {
    func makeStreamDecision(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?,
        startTime: TimeInterval
    ) async throws -> StreamDecision

    func assembleStreamResolution(from decision: StreamDecision) async throws -> StreamResolution

    func getDownloadURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality
    ) async throws -> URL
}

/// Describes shared cache reconciliation requested by a successful provider rating mutation.
public struct MusicSourceRatingMutationEffects: Sendable, Equatable {
    public let shouldRefreshPlaylists: Bool
    public let shouldReconcileFavoriteDownloads: Bool

    public init(
        shouldRefreshPlaylists: Bool,
        shouldReconcileFavoriteDownloads: Bool
    ) {
        self.shouldRefreshPlaylists = shouldRefreshPlaylists
        self.shouldReconcileFavoriteDownloads = shouldReconcileFavoriteDownloads
    }

    public static let none = MusicSourceRatingMutationEffects(
        shouldRefreshPlaylists: false,
        shouldReconcileFavoriteDownloads: false
    )

    public static let refreshPlaylistsAndFavoriteDownloads = MusicSourceRatingMutationEffects(
        shouldRefreshPlaylists: true,
        shouldReconcileFavoriteDownloads: true
    )
}

/// Applies the provider's normalized favorite/rating mutation.
public protocol MusicSourceRatingMutating: Sendable {
    func rateTrack(_ track: Track, rating: Int?) async throws -> MusicSourceRatingMutationEffects
}

/// Applies provider-owned playlist mutations after shared source and permission validation.
public protocol MusicSourcePlaylistMutating: Sendable {
    func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist?
    func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int
    func renamePlaylist(_ playlistID: String, title: String) async throws
    func deletePlaylist(_ playlistID: String) async throws
    func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws
    func editPlaylistItems(
        _ playlistID: String,
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) async throws
}

/// Reconciles a provider whose playlist reads may lag behind accepted mutations.
public protocol MusicSourcePlaylistReconciling: MusicSourcePlaylistMutating {
    func reconcilePlaylist(
        id: String,
        minimumTrackCount: Int,
        requiredTracks: [Track],
        to repository: PlaylistRepositoryProtocol
    ) async throws -> Int?
}

extension MusicSourcePlaylistMutating {
    public func editPlaylistItems(
        _ playlistID: String,
        originalItems _: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) async throws {
        try await replacePlaylistContents(playlistID, tracks: editedItems.map(\.track))
    }
}

/// Reports playback state through the exact provider that supplied a track.
public protocol MusicSourcePlaybackReporting: Sendable {
    func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws
    func scrobble(ratingKey: String) async throws
}

/// Loads provider-owned collection relationships and Get Info metadata.
public protocol MusicSourceDetailProviding: Sendable {
    func getAlbumTracks(albumKey: String) async throws -> [Track]
    func getArtistAlbums(artistKey: String) async throws -> [Album]
    func getArtistTracks(artistKey: String) async throws -> [Track]
    func getArtistDetail(artistKey: String) async throws -> ArtistDetail?
    func getAlbumDetail(albumKey: String) async throws -> AlbumDetail?
    func getSimilarAlbums(albumKey: String) async throws -> [Album]
}

/// Loads transient source-owned file metadata for Get Info and file export surfaces.
public protocol MusicSourceFileInfoProviding: Sendable {
    func getAudioFileInfo(trackID: String) async throws -> AudioFileInfo?
    func getAlbumFolderPath(albumID: String) async throws -> String?
}

/// Provider-neutral lyrics stream metadata used by the shared lyrics cache/parser.
public struct MusicSourceLyricsAsset: Sendable, Equatable {
    public let id: String
    public let key: String
    public let codec: String?
    public let format: String?
    public let provider: String?
    public let file: String?
    public let isTimed: Bool
    public let isLocalMedia: Bool

    public init(
        id: String,
        key: String,
        codec: String?,
        format: String?,
        provider: String?,
        file: String?,
        isTimed: Bool,
        isLocalMedia: Bool
    ) {
        self.id = id
        self.key = key
        self.codec = codec
        self.format = format
        self.provider = provider
        self.file = file
        self.isTimed = isTimed
        self.isLocalMedia = isLocalMedia
    }
}

/// Track metadata and prioritized lyrics assets returned by a source.
public struct MusicSourceLyricsMetadata: Sendable, Equatable {
    public let title: String
    public let dateModified: Date?
    public let normalAssets: [MusicSourceLyricsAsset]
    public let chordCandidateAssets: [MusicSourceLyricsAsset]

    public init(
        title: String,
        dateModified: Date?,
        normalAssets: [MusicSourceLyricsAsset],
        chordCandidateAssets: [MusicSourceLyricsAsset]
    ) {
        self.title = title
        self.dateModified = dateModified
        self.normalAssets = normalAssets
        self.chordCandidateAssets = chordCandidateAssets
    }
}

/// Discovers and fetches lyrics without exposing provider API models to shared UI services.
public protocol MusicSourceLyricsProviding: Sendable {
    func getLyricsMetadata(trackID: String) async throws -> MusicSourceLyricsMetadata?
    func getLyricsContent(asset: MusicSourceLyricsAsset, raw: Bool) async throws -> String?
}

/// Supplies source-native recommendations for Ensemble autoplay.
public protocol MusicSourceRadioProviding: Sendable {
    func getRecommendedTracks(basedOn track: Track, limit: Int) async -> [Track]?
}

/// Protocol for syncing music from a source (Plex, future Apple Music, etc.)
public protocol MusicSourceSyncProvider: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }

    /// Sync the library content (artists, albums, tracks, genres) to CoreData
    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult
    
    /// Sync only items added or updated since the given timestamp (incremental sync)
    /// - Parameter since: Unix timestamp of last sync (fetch items added/updated after this)
    func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult
    
    /// Sync playlists to CoreData (should be called once per server, not per library)
    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult

    /// Sync only playlists added or updated since last sync (incremental)
    func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
        forceOrphanCheck: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult

    /// Fetch source-owned Feed sections already normalized to Ensemble's hub model.
    func getHomeHubs(limit: Int) async throws -> [Hub]

    /// Fetch normalized Feed sections plus any individual section failures.
    func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult

    /// Get an artwork URL
    func getArtworkURL(path: String?, size: Int) async throws -> URL?
}

extension MusicSourceSyncProvider {
    public func getHomeHubs(limit: Int) async throws -> [Hub] { [] }
    public func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult {
        MusicSourceHubFetchResult(hubs: try await getHomeHubs(limit: limit))
    }
}

extension MusicSourceDetailProviding {
    public func getArtistDetail(artistKey: String) async throws -> ArtistDetail? { nil }
    public func getAlbumDetail(albumKey: String) async throws -> AlbumDetail? { nil }
    public func getSimilarAlbums(albumKey: String) async throws -> [Album] { [] }
}
