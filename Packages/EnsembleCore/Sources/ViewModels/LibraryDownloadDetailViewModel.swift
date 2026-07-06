import Combine
import CoreData
import EnsemblePersistence
import Foundation

/// ViewModel for the library download detail view — shows ALL downloaded tracks for a
/// sourceCompositeKey regardless of which target type (library, album, playlist, artist)
/// triggered the download.
@MainActor
public final class LibraryDownloadDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = [] {
        didSet { trackStats = TrackDownloadRowStats(rows: tracks) }
    }
    @Published public private(set) var playableTracks: [Track] = []
    @Published public private(set) var isLoading = false
    /// Why the download queue is currently paused
    @Published public private(set) var queueStatusReason: QueueStatusReason = .idle

    public let sourceCompositeKey: String
    public let title: String

    private let downloadManager: DownloadManagerProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()
    private var trackStats = TrackDownloadRowStats()

    public init(
        sourceCompositeKey: String,
        title: String,
        downloadManager: DownloadManagerProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        offlineDownloadService: OfflineDownloadService
    ) {
        self.sourceCompositeKey = sourceCompositeKey
        self.title = title
        self.downloadManager = downloadManager
        self.libraryRepository = libraryRepository
        self.offlineDownloadService = offlineDownloadService

        // Observe queue status
        offlineDownloadService.$queueStatusReason
            .receive(on: DispatchQueue.main)
            .assign(to: &$queueStatusReason)

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
                    downloadedQuality: download.quality,
                    discNumber: track.discNumber,
                    trackNumber: track.trackNumber,
                    index: index
                )
                rows.append(row)

                // Collect playable (completed) tracks as domain models
                if status == .completed {
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
