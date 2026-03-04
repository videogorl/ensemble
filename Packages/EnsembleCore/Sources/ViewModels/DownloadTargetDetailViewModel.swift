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
}

/// ViewModel for the per-track download detail view of a single offline target
@MainActor
public final class DownloadTargetDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = []
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
        tracks.filter { $0.status == .failed }.count
    }

    /// Number of completed tracks whose quality doesn't match the current download quality setting
    public var qualityMismatchCount: Int {
        let desired = UserDefaults.standard.string(forKey: "downloadQuality") ?? "original"
        return tracks.filter { row in
            row.status == .completed && row.downloadedQuality != nil && row.downloadedQuality != desired
        }.count
    }

    /// True when this target has actionable issues that a refresh could resolve
    public var needsRefresh: Bool {
        qualityMismatchCount > 0 || failedCount > 0
    }

    // MARK: - Live Target Stats (derived from tracks, updated reactively)

    /// Live completed track count computed from current track rows
    public var liveCompletedCount: Int {
        tracks.filter { $0.status == .completed }.count
    }

    /// Live total track count from current track rows
    public var liveTotalCount: Int {
        tracks.count
    }

    /// Live overall progress (0.0–1.0) computed from track rows
    public var liveProgress: Float {
        guard !tracks.isEmpty else { return 0 }
        return Float(liveCompletedCount) / Float(liveTotalCount)
    }

    /// Live downloaded bytes total from completed tracks
    public var liveDownloadedBytes: Int64 {
        tracks.filter { $0.status == .completed }.reduce(0) { $0 + $1.fileSize }
    }

    /// Live target-level status derived from individual track statuses
    public var liveStatus: CDOfflineDownloadTarget.Status {
        if tracks.contains(where: { $0.status == .failed }) { return .failed }
        if liveCompletedCount >= liveTotalCount && liveTotalCount > 0 { return .completed }
        if tracks.contains(where: { $0.status == .downloading }) { return .downloading }
        if tracks.contains(where: { $0.status == .paused }) { return .paused }
        return .pending
    }

    /// Re-reconcile the target, re-queue mismatched/failed downloads, and restart the queue
    public func refreshTarget() async {
        await offlineDownloadService.refreshTarget(key: summary.key)
        await loadTrackRows()
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
            #if DEBUG
            EnsembleLogger.debug("❌ DownloadTargetDetailViewModel: Failed to load tracks: \(error)")
            #endif
        }
    }

    /// Sort by metadata order: playlist targets use index, album/artist use disc+track number
    private func metadataOrder(_ lhs: TrackDownloadRow, _ rhs: TrackDownloadRow) -> Bool {
        switch summary.kind {
        case .playlist:
            return lhs.index < rhs.index
        case .album, .artist, .library:
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
