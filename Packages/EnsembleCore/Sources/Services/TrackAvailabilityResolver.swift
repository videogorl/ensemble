import Combine
import EnsembleAPI
import Foundation

/// Availability state for a single track.
public enum TrackAvailability: Sendable, Equatable {
    /// Can play — either downloaded or server reachable.
    case available
    /// Downloaded copy available, but server is unreachable.
    case availableDownloadedOnly
    /// Not downloaded and the track's server is offline (with classified reason).
    case unavailableServerOffline(reason: ServerConnectionFailureReason)
    /// Not downloaded and the device has no network connectivity.
    case unavailableNetworkOffline
    /// Playlist membership exists, but its source library is not synced locally.
    case unavailableLibraryNotSynced

    /// Whether the track can be played right now.
    public var canPlay: Bool {
        switch self {
        case .available, .availableDownloadedOnly:
            return true
        case .unavailableServerOffline, .unavailableNetworkOffline, .unavailableLibraryNotSynced:
            return false
        }
    }

    /// Whether the UI should dim the track row.
    public var shouldDim: Bool { !canPlay }

    /// User-facing message shown when tapping an unavailable track.
    public var userMessage: String? {
        switch self {
        case .available, .availableDownloadedOnly:
            return nil
        case .unavailableNetworkOffline:
            return "Not available offline"
        case .unavailableLibraryNotSynced:
            return "Library not synced"
        case .unavailableServerOffline(let reason):
            return reason.userMessage
        }
    }
}

/// Reactive track availability resolver that combines device connectivity,
/// per-server health state, and local download status.
///
/// Instead of maintaining per-track dictionaries, it publishes a `generation`
/// counter that increments on any state change. Views observe this counter
/// via `.onChange` and re-evaluate visibility for on-screen tracks.
@MainActor
public final class TrackAvailabilityResolver: ObservableObject {
    /// Incremented whenever connectivity, server state, or download state changes.
    /// Views should observe this and re-evaluate track availability for visible rows.
    @Published public private(set) var availabilityGeneration: UInt64 = 0

    private let networkMonitor: NetworkMonitor
    private let serverHealthChecker: ServerHealthChecker
    private var cancellables = Set<AnyCancellable>()

    public init(
        networkMonitor: NetworkMonitor,
        serverHealthChecker: ServerHealthChecker
    ) {
        self.networkMonitor = networkMonitor
        self.serverHealthChecker = serverHealthChecker

        setupObservers()
    }

    // MARK: - Resolve

    /// Determine the current availability of a track.
    /// - Parameter track: The track to check. Must have `sourceCompositeKey` set.
    public func availability(for track: Track) -> TrackAvailability {
        guard track.isLibraryAvailable else {
            return .unavailableLibraryNotSynced
        }

        // Downloaded tracks are always playable
        if track.isDownloaded {
            if networkMonitor.isConnected {
                return .available
            } else {
                return .availableDownloadedOnly
            }
        }

        // Not downloaded — check device connectivity first
        guard networkMonitor.isConnected else {
            return .unavailableNetworkOffline
        }

        // Device is online — check per-server health
        let serverKey = extractServerKey(from: track.sourceCompositeKey)
        if let serverKey,
           serverHealthChecker.serverStates[serverKey] == .offline
        {
            let reason = serverHealthChecker.serverFailureReasons[serverKey] ?? .offline
            return .unavailableServerOffline(reason: reason)
        }

        return .available
    }

    // MARK: - Private

    /// Observe network state, server health, and download changes to bump the generation counter.
    private func setupObservers() {
        // Network state changes
        networkMonitor.$networkState
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.bumpGeneration()
            }
            .store(in: &cancellables)

        // Server health state changes
        serverHealthChecker.$serverStates
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.bumpGeneration()
            }
            .store(in: &cancellables)

        // Download state changes — use deferred bump (5s) since download completions
        // don't affect playability of other tracks, only download icons/offline availability.
        // This prevents 8+ separate re-render cascades during bulk download sessions.
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .sink { [weak self] _ in
                self?.bumpGenerationDeferred()
            }
            .store(in: &cancellables)
    }

    private var generationBumpTask: Task<Void, Never>?
    private var generationDeferredBumpTask: Task<Void, Never>?

    /// Fast bump (100ms debounce) for network/server state changes.
    /// These affect playability immediately and need fast UI feedback.
    private func bumpGeneration() {
        generationBumpTask?.cancel()
        generationDeferredBumpTask?.cancel() // A fast bump supersedes any pending deferred bump
        generationBumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard !Task.isCancelled else { return }
            self?.applyGenerationBump()
        }
    }

    /// Deferred bump (5s debounce) for download state changes.
    /// Downloads completing don't affect playability of other tracks —
    /// only the download icon and offline availability. Coalesces
    /// multiple download completions into a single re-render cascade.
    private func bumpGenerationDeferred() {
        // Don't override a pending fast bump (network/server changes take priority)
        if let task = generationBumpTask, !task.isCancelled { return }
        generationDeferredBumpTask?.cancel()
        generationDeferredBumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            guard !Task.isCancelled else { return }
            self?.applyGenerationBump()
        }
    }

    private func applyGenerationBump() {
        availabilityGeneration &+= 1
        EnsembleLogger.debug("🔄 TrackAvailabilityResolver: generation bumped to \(availabilityGeneration), serverStates=\(serverHealthChecker.serverStates.mapValues { $0.description })")
    }

    private func extractServerKey(from sourceCompositeKey: String?) -> String? {
        MediaSourceIdentity.parse(sourceCompositeKey)?.accountServerKey
    }
}
