import Combine
import EnsembleAPI
import EnsemblePersistence
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

    /// Whether the track can be played right now.
    public var canPlay: Bool {
        switch self {
        case .available, .availableDownloadedOnly:
            return true
        case .unavailableServerOffline, .unavailableNetworkOffline:
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
    private let downloadManager: DownloadManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        networkMonitor: NetworkMonitor,
        serverHealthChecker: ServerHealthChecker,
        downloadManager: DownloadManagerProtocol
    ) {
        self.networkMonitor = networkMonitor
        self.serverHealthChecker = serverHealthChecker
        self.downloadManager = downloadManager

        setupObservers()
    }

    // MARK: - Resolve

    /// Determine the current availability of a track.
    /// - Parameter track: The track to check. Must have `sourceCompositeKey` set.
    public func availability(for track: Track) -> TrackAvailability {
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
        if let serverKey {
            let state = serverHealthChecker.serverStates[serverKey]
            if let state, !state.isAvailable {
                let reason = serverHealthChecker.serverFailureReasons[serverKey] ?? .offline
                return .unavailableServerOffline(reason: reason)
            }
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

        // Download state changes (tracks downloaded or removed)
        NotificationCenter.default.publisher(for: Notification.Name("OfflineDownloadsDidChange"))
            .sink { [weak self] _ in
                self?.bumpGeneration()
            }
            .store(in: &cancellables)
    }

    private func bumpGeneration() {
        availabilityGeneration &+= 1
    }

    /// Extract the server key (accountId:serverId) from a source composite key.
    /// Source composite keys follow the format: "plex:<accountId>:<serverId>:<libraryId>"
    private func extractServerKey(from sourceCompositeKey: String?) -> String? {
        guard let key = sourceCompositeKey else { return nil }
        let parts = key.split(separator: ":")
        // Expected format: "plex:accountId:serverId:libraryId"
        guard parts.count >= 3 else { return nil }
        return "\(parts[1]):\(parts[2])"
    }
}
