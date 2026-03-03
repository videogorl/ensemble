import Combine
import EnsemblePersistence
import Foundation

/// Per-track row model for the download target detail view
public struct TrackDownloadRow: Identifiable {
    public let id: String  // membershipID
    public let trackRatingKey: String
    public let sourceCompositeKey: String
    public let title: String
    public let artistName: String?
    /// Track-level thumb path (may be nil for most tracks — use fallbackThumbPath)
    public let thumbPath: String?
    /// Album artwork path used as fallback when track has no own thumb
    public let fallbackThumbPath: String?
    /// Album ratingKey for local artwork cache lookup
    public let albumRatingKey: String?
    public let status: CDDownload.Status
    public let progress: Float
    public let fileSize: Int64
    public let errorMessage: String?
}

/// ViewModel for the per-track download detail view of a single offline target
@MainActor
public final class DownloadTargetDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = []
    @Published public private(set) var playableTracks: [Track] = []
    @Published public private(set) var isLoading = false
    /// Resolved thumb path for the target entity (album/artist/playlist artwork)
    @Published public private(set) var thumbPath: String?

    public let summary: DownloadedItemSummary

    private let offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let offlineDownloadService: OfflineDownloadService

    public init(
        summary: DownloadedItemSummary,
        offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol,
        downloadManager: DownloadManagerProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        offlineDownloadService: OfflineDownloadService
    ) {
        self.summary = summary
        self.offlineDownloadTargetRepository = offlineDownloadTargetRepository
        self.downloadManager = downloadManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.offlineDownloadService = offlineDownloadService
    }

    // MARK: - Public

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await resolveHeaderThumb()
        await loadTrackRows()
    }

    /// Retry a single failed download
    public func retryDownload(row: TrackDownloadRow) async {
        await offlineDownloadService.retryDownload(
            trackRatingKey: row.trackRatingKey,
            sourceCompositeKey: row.sourceCompositeKey
        )
        await loadTrackRows()
    }

    /// Retry all tracks in a failed state
    public func retryAllFailed() async {
        let failedRows = tracks.filter { $0.status == .failed }
        for row in failedRows {
            await offlineDownloadService.retryDownload(
                trackRatingKey: row.trackRatingKey,
                sourceCompositeKey: row.sourceCompositeKey
            )
        }
        await loadTrackRows()
    }

    public var failedCount: Int {
        tracks.filter { $0.status == .failed }.count
    }

    // MARK: - Private

    /// Look up the entity (album/artist/playlist) from CoreData to resolve its artwork path
    private func resolveHeaderThumb() async {
        guard let ratingKey = summary.ratingKey else { return }
        let sourceKey = summary.sourceCompositeKey
        switch summary.kind {
        case .album:
            let album = try? await libraryRepository.fetchAlbum(ratingKey: ratingKey)
            thumbPath = album?.thumbPath
        case .artist:
            let artist = try? await libraryRepository.fetchArtist(ratingKey: ratingKey)
            thumbPath = artist?.thumbPath
        case .playlist:
            let playlist = try? await playlistRepository.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceKey)
            thumbPath = playlist?.compositePath
        case .library:
            thumbPath = nil
        }
    }

    private func loadTrackRows() async {
        do {
            let references = try await offlineDownloadTargetRepository.fetchTrackReferences(targetKey: summary.key)

            var rows: [TrackDownloadRow] = []
            var resolved: [Track] = []

            for ref in references {
                let download = try? await downloadManager.fetchDownload(
                    forTrackRatingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey
                )
                let cdTrack = try? await libraryRepository.fetchTrack(
                    ratingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey
                )

                let status = download?.downloadStatus ?? .pending
                let row = TrackDownloadRow(
                    id: ref.membershipID,
                    trackRatingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey,
                    title: cdTrack?.title ?? ref.trackRatingKey,
                    artistName: cdTrack?.artistName,
                    thumbPath: cdTrack?.thumbPath,
                    fallbackThumbPath: cdTrack?.album?.thumbPath,
                    albumRatingKey: cdTrack?.album?.ratingKey,
                    status: status,
                    progress: download?.progress ?? 0,
                    fileSize: download?.fileSize ?? 0,
                    errorMessage: download?.error
                )
                rows.append(row)

                // Collect playable (downloaded) tracks as full domain models
                if let cdTrack, status == .completed {
                    resolved.append(Track(from: cdTrack))
                }
            }

            // Sort: failed first, then downloading, paused, pending, completed — then alphabetically within each group
            tracks = rows.sorted { lhs, rhs in
                let lp = trackStatusSortPriority(lhs.status)
                let rp = trackStatusSortPriority(rhs.status)
                if lp != rp { return lp < rp }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            // Playable tracks ordered by disc+track number for natural playback
            playableTracks = resolved.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ DownloadTargetDetailViewModel: Failed to load tracks: \(error)")
            #endif
        }
    }

    private func trackStatusSortPriority(_ status: CDDownload.Status) -> Int {
        switch status {
        case .failed: return 0
        case .downloading: return 1
        case .paused: return 2
        case .pending: return 3
        case .completed: return 4
        }
    }
}
