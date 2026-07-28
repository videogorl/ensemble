import Foundation

/// View model for the library Get Info panel.
@MainActor
public final class LibraryItemInfoViewModel: ObservableObject {
    public struct SourceContext: Equatable, Sendable {
        public let serverName: String?
        public let libraryName: String?
    }

    @Published public private(set) var sourceContext = SourceContext(serverName: nil, libraryName: nil)
    @Published public private(set) var originalFileInfo: AudioFileInfo?
    @Published public private(set) var originalFolderPath: String?
    @Published public private(set) var aggregateDuration: TimeInterval?
    @Published public private(set) var aggregateTrackCount: Int?
    @Published public private(set) var aggregateArtworkPath: String?
    @Published public private(set) var aggregateArtworkRatingKey: String?
    @Published public private(set) var isLoading = false

    public let request: LibraryItemInfoRequest

    public var resolvedArtworkPath: String? {
        aggregateArtworkPath ?? request.artworkPath
    }

    public var resolvedArtworkRatingKey: String? {
        aggregateArtworkRatingKey ?? request.artworkRatingKey
    }

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator

    public init(
        request: LibraryItemInfoRequest,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager
    ) {
        self.request = request
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.sourceContext = Self.sourceContext(
            sourceCompositeKey: request.sourceCompositeKey,
            accountManager: accountManager
        )
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let fileInfo = loadOriginalFileInfo()
        async let aggregate = loadAggregateMetadata()

        let resolvedFileInfo = await fileInfo
        let resolvedFolderPath: String?
        switch request {
        case .track:
            resolvedFolderPath = nil
        case .album:
            resolvedFolderPath = await loadAlbumOriginalFolderPath()
        case .playlist:
            resolvedFolderPath = nil
        }
        let resolvedAggregate = await aggregate

        if originalFileInfo != resolvedFileInfo {
            originalFileInfo = resolvedFileInfo
        }
        if originalFolderPath != resolvedFolderPath {
            originalFolderPath = resolvedFolderPath
        }
        if aggregateDuration != resolvedAggregate.duration {
            aggregateDuration = resolvedAggregate.duration
        }
        if aggregateTrackCount != resolvedAggregate.trackCount {
            aggregateTrackCount = resolvedAggregate.trackCount
        }
        if aggregateArtworkPath != resolvedAggregate.artworkPath {
            aggregateArtworkPath = resolvedAggregate.artworkPath
        }
        if aggregateArtworkRatingKey != resolvedAggregate.artworkRatingKey {
            aggregateArtworkRatingKey = resolvedAggregate.artworkRatingKey
        }
    }

    private func loadOriginalFileInfo() async -> AudioFileInfo? {
        guard case .track(let track) = request else { return nil }

        do {
            return try await syncCoordinator.getAudioFileInfo(
                trackId: track.id,
                sourceKey: track.sourceCompositeKey
            )
        } catch {
            EnsembleLogger.debug("Failed to fetch Get Info file metadata: \(error)")
            return nil
        }
    }

    private func loadAlbumOriginalFolderPath() async -> String? {
        guard case .album(let album) = request else { return nil }

        do {
            return try await syncCoordinator.getAlbumFolderPath(
                albumId: album.id,
                sourceKey: album.sourceCompositeKey
            )
        } catch {
            EnsembleLogger.debug("Failed to fetch Get Info album folder path: \(error)")
            return nil
        }
    }

    private func loadAggregateMetadata() async -> AggregateMetadata {
        switch request {
        case .track(let track):
            return AggregateMetadata(
                duration: track.duration > 0 ? track.duration : nil,
                trackCount: nil,
                artworkPath: nil,
                artworkRatingKey: nil
            )
        case .album(let album):
            guard let sourceKey = album.sourceCompositeKey else {
                return AggregateMetadata(duration: nil, trackCount: nil, artworkPath: nil, artworkRatingKey: nil)
            }
            let tracks = try? await libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceKey
            )
            let duration = tracks?.reduce(TimeInterval(0)) {
                $0 + Self.persistedTrackDurationSeconds($1.duration)
            } ?? 0
            let artworkFallback = tracks?.first {
                $0.thumbPath?.isEmpty == false || $0.album?.thumbPath?.isEmpty == false
            }
            return AggregateMetadata(
                duration: duration > 0 ? duration : nil,
                trackCount: tracks?.count,
                artworkPath: Self.resolvedAlbumArtworkPath(
                    albumThumbPath: album.thumbPath,
                    fetchedTrackArtworkPath: artworkFallback?.thumbPath,
                    fetchedTrackFallbackPath: artworkFallback?.album?.thumbPath
                ),
                artworkRatingKey: Self.resolvedAlbumArtworkRatingKey(
                    albumThumbPath: album.thumbPath,
                    albumRatingKey: album.id,
                    fetchedTrackArtworkPath: artworkFallback?.thumbPath,
                    fetchedTrackRatingKey: artworkFallback?.ratingKey,
                    fetchedTrackFallbackRatingKey: artworkFallback?.album?.ratingKey
                )
            )
        case .playlist(let playlist):
            guard let cdPlaylist = try? await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) else {
                return AggregateMetadata(
                    duration: playlist.duration > 0 ? playlist.duration : nil,
                    trackCount: nil,
                    artworkPath: nil,
                    artworkRatingKey: nil
                )
            }
            let tracks = cdPlaylist.tracksArray
            let duration = tracks.reduce(TimeInterval(0)) {
                $0 + Self.persistedTrackDurationSeconds($1.duration)
            }
            return AggregateMetadata(
                duration: duration > 0 ? duration : (playlist.duration > 0 ? playlist.duration : nil),
                trackCount: tracks.count,
                artworkPath: nil,
                artworkRatingKey: nil
            )
        }
    }

    public static func resolvedTrackCount(metadataTrackCount: Int, fetchedTrackCount: Int?) -> Int {
        fetchedTrackCount ?? metadataTrackCount
    }

    public static func resolvedAlbumArtworkPath(
        albumThumbPath: String?,
        fetchedTrackArtworkPath: String?,
        fetchedTrackFallbackPath: String?
    ) -> String? {
        if albumThumbPath?.isEmpty == false {
            return albumThumbPath
        }
        if fetchedTrackArtworkPath?.isEmpty == false {
            return fetchedTrackArtworkPath
        }
        return fetchedTrackFallbackPath?.isEmpty == false ? fetchedTrackFallbackPath : nil
    }

    public static func resolvedAlbumArtworkRatingKey(
        albumThumbPath: String?,
        albumRatingKey: String,
        fetchedTrackArtworkPath: String?,
        fetchedTrackRatingKey: String?,
        fetchedTrackFallbackRatingKey: String?
    ) -> String? {
        if albumThumbPath?.isEmpty == false {
            return albumRatingKey
        }
        if fetchedTrackArtworkPath?.isEmpty == false {
            return fetchedTrackRatingKey
        }
        return fetchedTrackFallbackRatingKey ?? albumRatingKey
    }

    static func persistedTrackDurationSeconds(_ durationMilliseconds: Int64) -> TimeInterval {
        TimeInterval(durationMilliseconds) / 1000.0
    }

    static func sourceContext(
        sourceCompositeKey: String?,
        accountManager: AccountManager
    ) -> SourceContext {
        guard let presentation = accountManager.sourcePresentation(for: sourceCompositeKey) else {
            return SourceContext(serverName: nil, libraryName: nil)
        }
        return SourceContext(
            serverName: presentation.serverName,
            libraryName: presentation.libraryName
        )
    }
}

private struct AggregateMetadata: Equatable {
    let duration: TimeInterval?
    let trackCount: Int?
    let artworkPath: String?
    let artworkRatingKey: String?
}
