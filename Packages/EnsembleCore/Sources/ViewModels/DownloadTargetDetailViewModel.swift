import Combine
import CoreData
import EnsembleAPI
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
    /// Quality string stored on the completed download (e.g. "original", "high", "medium", "low")
    public let downloadedQuality: String?
    /// Disc number from track metadata (for sort ordering)
    public let discNumber: Int32
    /// Track number from track metadata (for sort ordering)
    public let trackNumber: Int32
    /// Index within parent container (used for playlist ordering)
    public let index: Int

    public var sourceScopedID: String {
        sourceScopedIdentity(ratingKey: trackRatingKey, sourceCompositeKey: sourceCompositeKey)
    }

    public func playableTrackIndex(in tracks: [Track]) -> Int? {
        tracks.firstIndex { $0.sourceScopedID == sourceScopedID }
    }
}

struct TrackDownloadRowStats {
    let failedCount: Int
    let completedCount: Int
    let totalCount: Int
    let downloadedBytes: Int64
    let status: CDOfflineDownloadTarget.Status

    var progress: Float {
        guard totalCount > 0 else { return 0 }
        return Float(completedCount) / Float(totalCount)
    }

    init() {
        failedCount = 0
        completedCount = 0
        totalCount = 0
        downloadedBytes = 0
        status = .pending
    }

    init(rows: [TrackDownloadRow]) {
        var failedCount = 0
        var completedCount = 0
        var downloadedBytes: Int64 = 0
        var hasDownloading = false
        var hasPaused = false

        for row in rows {
            switch row.status {
            case .failed:
                failedCount += 1
            case .completed:
                completedCount += 1
                downloadedBytes += row.fileSize
            case .downloading:
                hasDownloading = true
            case .paused:
                hasPaused = true
            case .pending:
                break
            }
        }

        self.failedCount = failedCount
        self.completedCount = completedCount
        self.totalCount = rows.count
        self.downloadedBytes = downloadedBytes

        if failedCount > 0 {
            status = .failed
        } else if completedCount >= rows.count && !rows.isEmpty {
            status = .completed
        } else if hasDownloading {
            status = .downloading
        } else if hasPaused {
            status = .paused
        } else {
            status = .pending
        }
    }
}

/// ViewModel for the per-track download detail view of a single offline target
@MainActor
public final class DownloadTargetDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = [] {
        didSet { trackStats = TrackDownloadRowStats(rows: tracks) }
    }
    @Published public private(set) var playableTracks: [Track] = []
    @Published public private(set) var isLoading = false
    /// Resolved thumb path for the target entity (album/artist/playlist artwork)
    @Published public private(set) var thumbPath: String?
    /// Why the download queue is currently paused (observed from OfflineDownloadService)
    @Published public private(set) var queueStatusReason: QueueStatusReason = .idle

    public let summary: DownloadedItemSummary

    private let offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()
    private var trackStats = TrackDownloadRowStats()

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

        // Observe queue status reason from the download service
        offlineDownloadService.$queueStatusReason
            .receive(on: DispatchQueue.main)
            .assign(to: &$queueStatusReason)

        // Re-load track rows when the view context merges background download changes.
        // This fires AFTER CoreData merges background saves to the view context, ensuring
        // loadTrackRows() reads up-to-date CDDownload records. Debounced to coalesce
        // rapid successive track completions.
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: CoreDataStack.shared.viewContext)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.loadTrackRows() }
            }
            .store(in: &cancellables)
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
        trackStats.failedCount
    }

    // MARK: - Live Target Stats (derived from tracks, updated reactively)

    /// Live completed track count computed from current track rows
    public var liveCompletedCount: Int {
        trackStats.completedCount
    }

    /// Live total track count from current track rows
    public var liveTotalCount: Int {
        trackStats.totalCount
    }

    /// Live overall progress (0.0–1.0) computed from track rows
    public var liveProgress: Float {
        trackStats.progress
    }

    /// Live downloaded bytes total from completed tracks
    public var liveDownloadedBytes: Int64 {
        trackStats.downloadedBytes
    }

    /// Live target-level status derived from individual track statuses
    public var liveStatus: CDOfflineDownloadTarget.Status {
        trackStats.status
    }

    /// Explicitly redownload completed tracks whose quality differs from the current setting.
    public func redownloadAtCurrentQuality() async -> OfflineDownloadQualityRefreshResult {
        let result = await offlineDownloadService.redownloadTargetAtCurrentQuality(key: summary.key)
        await loadTrackRows()
        return result
    }

    // MARK: - Private

    /// Look up the entity (album/artist/playlist) from CoreData to resolve its artwork path
    private func resolveHeaderThumb() async {
        guard let ratingKey = summary.ratingKey else { return }
        let sourceKey = summary.sourceCompositeKey
        switch summary.kind {
        case .album:
            let album = try? await libraryRepository.fetchAlbum(ratingKey: ratingKey, sourceCompositeKey: sourceKey)
            thumbPath = album?.thumbPath
        case .artist:
            let artist = try? await libraryRepository.fetchArtist(ratingKey: ratingKey, sourceCompositeKey: sourceKey)
            thumbPath = artist?.thumbPath
        case .playlist:
            let playlist = try? await playlistRepository.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceKey)
            thumbPath = playlist?.compositePath
        case .library, .favorites:
            thumbPath = nil
        }
    }

    private func loadTrackRows() async {
        do {
            let references = try await offlineDownloadTargetRepository.fetchTrackReferences(targetKey: summary.key)

            var rows: [TrackDownloadRow] = []
            var resolved: [Track] = []

            for (index, ref) in references.enumerated() {
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
                    errorMessage: download?.error,
                    downloadedQuality: download?.quality,
                    discNumber: cdTrack?.discNumber ?? 0,
                    trackNumber: cdTrack?.trackNumber ?? 0,
                    index: index
                )
                rows.append(row)

                // Collect playable (downloaded) tracks as full domain models
                if let cdTrack, status == .completed {
                    resolved.append(Track(from: cdTrack))
                }
            }

            // Sort completed tracks by metadata order; in-progress/pending/failed float to top by status
            tracks = rows.sorted { lhs, rhs in
                let lp = trackStatusSortPriority(lhs.status)
                let rp = trackStatusSortPriority(rhs.status)
                if lp != rp { return lp < rp }
                // Within same status, sort by metadata order
                return metadataOrder(lhs, rhs)
            }

            // Playable tracks ordered by metadata order for natural playback
            playableTracks = resolved.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        } catch {
            EnsembleLogger.debug("❌ DownloadTargetDetailViewModel: Failed to load tracks: \(error)")
        }
    }

    /// Sort by metadata order: playlist targets use index, album/artist use disc+track number
    private func metadataOrder(_ lhs: TrackDownloadRow, _ rhs: TrackDownloadRow) -> Bool {
        switch summary.kind {
        case .playlist:
            return lhs.index < rhs.index
        case .album, .artist, .library, .favorites:
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func trackStatusSortPriority(_ status: CDDownload.Status) -> Int {
        switch status {
        case .downloading: return 0
        case .pending: return 1
        case .paused: return 2
        case .failed: return 3
        case .completed: return 4
        }
    }
}
