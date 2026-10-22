import AsyncAlgorithms
import Combine
import CoreData
import EnsemblePersistence
import EnsembleSupport
import Foundation
import Observation

/// ViewModel for the library download detail view — shows ALL downloaded tracks for a
/// sourceCompositeKey regardless of which target type (library, album, playlist, artist)
/// triggered the download.
@MainActor
@Observable
public final class LibraryDownloadDetailViewModel {
    public private(set) var tracks: [TrackDownloadRow] = [] {
        didSet { trackStats = TrackDownloadRowStats(rows: tracks) }
    }
    public private(set) var playableTracks: [Track] = []
    public private(set) var isLoading = false
    /// Why the download queue is currently paused
    public private(set) var queueStatusReason: QueueStatusReason = .idle

    public let sourceCompositeKey: String
    public let title: String

    private let downloadManager: DownloadManagerProtocol
    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var subscriptions: [StreamSubscription] = []
    @ObservationIgnored private var isStarted = false
    private var trackStats = TrackDownloadRowStats()

    public init(
        sourceCompositeKey: String,
        title: String,
        downloadManager: DownloadManagerProtocol,
        offlineDownloadService: OfflineDownloadService
    ) {
        self.sourceCompositeKey = sourceCompositeKey
        self.title = title
        self.downloadManager = downloadManager
        self.offlineDownloadService = offlineDownloadService
        queueStatusReason = offlineDownloadService.queueStatusReason
    }

    /// Starts following queue status and download changes. Safe to call on
    /// every appearance.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        subscriptions.append(offlineDownloadService.snapshots().map(\.queueStatusReason).removeDuplicates().dropFirst().observe(self) { model, reason in
            model.queueStatusReason = reason
        })

        // Re-load when CoreData view context merges background download changes
        NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: CoreDataStack.shared.viewContext
        )
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
        await loadTrackRows()
    }

    /// Retry a single failed download
    public func retryDownload(row: TrackDownloadRow) async {
        await offlineDownloadService.retryDownload(row: row)
        await loadTrackRows()
    }

    /// Retry all failed downloads in this library
    public func retryAllFailed() async {
        await offlineDownloadService.retryFailedDownloads(in: tracks)
        await loadTrackRows()
    }

    public var failedCount: Int {
        trackStats.failedCount
    }

    // MARK: - Live Stats

    public var liveCompletedCount: Int {
        trackStats.completedCount
    }

    public var liveTotalCount: Int {
        trackStats.totalCount
    }

    public var liveProgress: Float {
        trackStats.progress
    }

    public var liveDownloadedBytes: Int64 {
        trackStats.downloadedBytes
    }

    public var liveStatus: CDOfflineDownloadTarget.Status {
        trackStats.status
    }

    // MARK: - Private

    /// Fetches all CDDownload records for this library's sourceCompositeKey
    private func loadTrackRows() async {
        do {
            let downloads = try await downloadManager.fetchDownloads(
                forSourceCompositeKey: sourceCompositeKey
            )

            var rows: [TrackDownloadRow] = []
            var resolved: [Track] = []

            for (index, download) in downloads.enumerated() {
                guard let track = download.track else { continue }

                let status = download.downloadStatus
                let row = TrackDownloadRow(
                    id: download.objectID.uriRepresentation().absoluteString,
                    trackRatingKey: track.ratingKey,
                    sourceCompositeKey: track.sourceCompositeKey ?? sourceCompositeKey,
                    title: track.title,
                    artistName: track.artistName,
                    thumbPath: track.thumbPath,
                    fallbackThumbPath: track.album?.thumbPath,
                    albumRatingKey: track.album?.ratingKey,
                    status: status,
                    progress: download.progress,
                    fileSize: download.fileSize,
                    errorMessage: download.error,
                    downloadedQuality: download.installedQuality,
                    discNumber: track.discNumber,
                    trackNumber: track.trackNumber,
                    index: index,
                    hasStoredFile: download.hasStoredFile
                )
                rows.append(row)

                // Collect playable (completed) tracks as domain models
                if download.hasStoredFile {
                    resolved.append(Track(from: track))
                }
            }

            // Sort completed tracks by disc/track number; in-progress/pending/failed float to top
            tracks = rows.sorted { lhs, rhs in
                let lp = lhs.statusSortPriority
                let rp = rhs.statusSortPriority
                if lp != rp { return lp < rp }
                return lhs.isOrderedBeforeByDiscTrackTitle(rhs)
            }

            // Playable tracks in natural order (disc + track number)
            playableTracks = resolved.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        } catch {
            EnsembleLogger.debug("❌ LibraryDownloadDetailVM: Failed to load tracks: \(error)")
        }
    }

}
