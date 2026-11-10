import EnsembleSupport
import Foundation
import Network
import EnsembleAPI

protocol NetworkPathMonitoring: AnyObject {
    var pathUpdateHandler: ((NWPath) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()

    var pathUpdateHandler: ((NWPath) -> Void)? {
        get { monitor.pathUpdateHandler }
        set { monitor.pathUpdateHandler = newValue }
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

/// What `NetworkMonitor` knows about connectivity.
public struct NetworkSnapshot: Equatable, Sendable {
    public var state: NetworkState
    public var isConstrained: Bool
    public var isConnected: Bool { state.isConnected }

    public init(state: NetworkState = .unknown, isConstrained: Bool = false) {
        self.state = state
        self.isConstrained = isConstrained
    }
}

/// What makes one network path a different route for a download: whether it is usable and which
/// interface is preferred. Extra interfaces appearing (cellular while Wi-Fi stays primary) and the
/// expensive or constrained flags do not change the route.
struct PathSignature: Equatable {
    let status: NWPath.Status
    let primaryInterfaceType: NWInterface.InterfaceType?
    let primaryInterfaceName: String?

    init(status: NWPath.Status, primaryInterfaceType: NWInterface.InterfaceType?, primaryInterfaceName: String?) {
        self.status = status
        self.primaryInterfaceType = primaryInterfaceType
        self.primaryInterfaceName = primaryInterfaceName
    }

    init(_ path: NWPath) {
        self.init(
            status: path.status,
            primaryInterfaceType: path.availableInterfaces.first?.type,
            primaryInterfaceName: path.availableInterfaces.first?.name
        )
    }
}

/// Monitors network connectivity state using NWPathMonitor
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var snapshot = NetworkSnapshot() {
        didSet {
            if snapshot != oldValue { broadcast.send(snapshot) }
        }
    }
    public var networkState: NetworkState { snapshot.state }
    public var isConnected: Bool { snapshot.isConnected }
    public var isConstrained: Bool { snapshot.isConstrained }
    @ObservationIgnored private let broadcast = Broadcast<NetworkSnapshot>()
    @ObservationIgnored private let pathBroadcast = Broadcast<UInt64>()
    @ObservationIgnored private var lastPathSignature: PathSignature?
    @ObservationIgnored private var pathChangePending = false
    /// Counts debounced changes of the network path, including a new route on the same interface
    /// type (another Wi-Fi network), which `snapshot` does not show.
    public private(set) var pathGeneration: UInt64 = 0

    /// Each debounced path change, as its new `pathGeneration`.
    public func pathChanges() -> AsyncStream<UInt64> {
        pathBroadcast.stream()
    }

    /// The current snapshot, then each change.
    public func snapshots() -> AsyncStream<NetworkSnapshot> {
        broadcast.stream(startingWith: snapshot)
    }

    private let monitorFactory: () -> any NetworkPathMonitoring
    private let monitorQueue: DispatchQueue
    private let debounceNanoseconds: UInt64

    @ObservationIgnored private var monitor: (any NetworkPathMonitoring)?
    private var isMonitoring = false
    /// When true, NWPathMonitor updates are ignored so the simulated state sticks
    private var isSimulatingOffline = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    // UserDefaults key for persisting last-known network state across launches
    private static let cachedStateKey = "lastKnownNetworkState"
    private static let cachedConstrainedKey = "lastKnownNetworkWasConstrained"

    internal private(set) var monitorGeneration = 0
    public private(set) var routingGeneration: UInt64 = 0
    /// Runs synchronously on every routing change, before stream listeners,
    /// so `AccountManager` re-resolves server connections before sync or
    /// playback react to the new network.
    var onRoutingChanged: (() -> Void)?
    var reachabilityContext: NetworkReachabilityContext {
        switch networkState {
        case .online(.wifi), .online(.wired): return .localNetwork
        case .online(.cellular), .online(.other): return .remoteNetwork
        case .offline, .limited, .unknown: return .unknown
        }
    }
    internal var isMonitoringForTesting: Bool { isMonitoring }

    public convenience init() {
        self.init(
            debounceNanoseconds: 1_000_000_000,
            monitorQueue: DispatchQueue(label: "com.ensemble.networkmonitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
    }

    internal init(
        debounceNanoseconds: UInt64,
        monitorQueue: DispatchQueue,
        monitorFactory: @escaping () -> any NetworkPathMonitoring
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.monitorQueue = monitorQueue
        self.monitorFactory = monitorFactory

        // Seed initial state from cached value so dependents don't wait for
        // NWPathMonitor's first callback (~1-5s). The monitor will correct
        // this if the real state differs.
        let cached = Self.loadCachedState()
        if cached != .unknown {
            snapshot = NetworkSnapshot(
                state: cached,
                isConstrained: UserDefaults.standard.bool(forKey: Self.cachedConstrainedKey)
            )
            EnsembleLogger.debug("📡 NetworkMonitor: Restored cached state: \(cached.description)")
        }
    }

    // MARK: - State Persistence

    /// Persist current network state for optimistic startup on next launch
    private func persistState(_ state: NetworkState, isConstrained: Bool) {
        let raw: String
        switch state {
        case .online(let type):
            switch type {
            case .wifi: raw = "online_wifi"
            case .cellular: raw = "online_cellular"
            case .wired: raw = "online_wired"
            case .other: raw = "online_other"
            }
        case .offline: raw = "offline"
        case .limited: raw = "limited"
        case .unknown: raw = "unknown"
        }
        UserDefaults.standard.set(raw, forKey: Self.cachedStateKey)
        UserDefaults.standard.set(isConstrained, forKey: Self.cachedConstrainedKey)
    }

    /// Load cached network state from UserDefaults
    private static func loadCachedState() -> NetworkState {
        guard let raw = UserDefaults.standard.string(forKey: cachedStateKey) else {
            return .unknown
        }
        switch raw {
        case "online_wifi": return .online(.wifi)
        case "online_cellular": return .online(.cellular)
        case "online_wired": return .online(.wired)
        case "online_other": return .online(.other)
        case "offline": return .offline
        case "limited": return .limited
        default: return .unknown
        }
    }

    // MARK: - Public Methods

    /// Start monitoring network state changes
    public func startMonitoring() {
        guard !isMonitoring else { return }

        let newMonitor = monitorFactory()
        newMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.debounceStateUpdate(path: path)
            }
        }
        newMonitor.start(queue: monitorQueue)
        monitor = newMonitor
        isMonitoring = true
        monitorGeneration += 1
        routingGeneration &+= 1
        onRoutingChanged?()

        EnsembleLogger.debug("📡 NetworkMonitor: Started monitoring (generation \(monitorGeneration))")
        #if DEBUG
        restoreDebugSimulationIfNeeded()
        #endif
    }

    /// Stop monitoring network state changes (for battery optimization)
    public func stopMonitoring() {
        guard isMonitoring else { return }

        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        isMonitoring = false

        debounceTask?.cancel()
        debounceTask = nil

        EnsembleLogger.debug("📡 NetworkMonitor: Stopped monitoring")
    }

    // MARK: - Testing Helpers

    #if DEBUG
    /// Simulate an offline or online state for manual testing from the Settings Developer section.
    /// Sets a flag so NWPathMonitor updates don't overwrite the simulated state.
    public func simulateOffline(_ offline: Bool) {
        isSimulatingOffline = offline
        let state: NetworkState = offline ? .offline : .online(.wifi)
        injectNetworkStateForTesting(state, isConstrained: false, debounced: false)
    }

    /// Re-apply debug simulation on cold start if the toggle was left on.
    /// Called from `startMonitoring()` after the monitor is up.
    public func restoreDebugSimulationIfNeeded() {
        let persisted = UserDefaults.standard.bool(forKey: "debugSimulateOffline")
        if persisted {
            EnsembleLogger.debug("📡 NetworkMonitor: Restoring debug offline simulation from cold start")
            simulateOffline(true)
        }
    }
    #endif

    internal func injectNetworkStateForTesting(
        _ state: NetworkState,
        isConstrained: Bool = false,
        pathChanged: Bool = false,
        debounced: Bool = true
    ) {
        pathChangePending = pathChangePending || pathChanged
        if debounced {
            debounceStateUpdate(state: state, isConstrained: isConstrained)
        } else {
            updateState(to: state, isConstrained: isConstrained)
        }
    }

    // MARK: - Private Methods

    /// Debounce network state updates to avoid rapid changes.
    /// Ignored when offline simulation is active so the monitor doesn't overwrite the simulated state.
    private func debounceStateUpdate(path: NWPath) {
        guard !isSimulatingOffline else { return }
        let signature = PathSignature(path)
        if let lastPathSignature, lastPathSignature != signature { pathChangePending = true }
        lastPathSignature = signature
        debounceStateUpdate(
            state: networkState(from: path),
            isConstrained: path.status == .satisfied && path.isConstrained
        )
    }

    /// Debounce known state updates for testing and lifecycle-safe handling.
    private func debounceStateUpdate(state: NetworkState, isConstrained: Bool = false) {
        debounceTask?.cancel()

        debounceTask = Task { @MainActor [weak self] in
            if let self, self.debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            }

            guard !Task.isCancelled, let self else { return }
            self.updateState(to: state, isConstrained: isConstrained)
            if self.pathChangePending {
                self.pathChangePending = false
                self.pathGeneration &+= 1
                self.pathBroadcast.send(self.pathGeneration)
            }
        }
    }

    /// Update the published state and persist for optimistic startup.
    private func updateState(to newState: NetworkState, isConstrained newIsConstrained: Bool) {
        let newSnapshot = NetworkSnapshot(state: newState, isConstrained: newIsConstrained)
        guard newSnapshot != snapshot else { return }

        EnsembleLogger.debug("📡 NetworkMonitor: State changed to \(newState.description)")

        snapshot = newSnapshot
        persistState(newState, isConstrained: newIsConstrained)
        routingGeneration &+= 1
        onRoutingChanged?()
    }

    /// Convert NWPath to NetworkState
    private func networkState(from path: NWPath) -> NetworkState {
        switch path.status {
        case .satisfied:
            return Self.stateForSatisfiedPath(
                networkType: networkType(from: path),
                isConstrained: path.isConstrained
            )

        case .unsatisfied:
            return .offline

        case .requiresConnection:
            return .offline

        @unknown default:
            return .unknown
        }
    }

    /// Normalizes satisfied paths into connectivity state.
    ///
    /// `NWPath.isConstrained` indicates Low Data Mode and should not be treated as offline.
    internal static func stateForSatisfiedPath(networkType: NetworkType, isConstrained: Bool) -> NetworkState {
        if isConstrained {
            EnsembleLogger.debug(
                "📡 NetworkMonitor: Path is constrained (Low Data Mode) - treating as online \(networkType.description)"
            )
        }

        return .online(networkType)
    }

    /// Determine the network type from NWPath
    private func networkType(from path: NWPath) -> NetworkType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        } else {
            return .other
        }
    }

    deinit {
        monitor?.cancel()
        debounceTask?.cancel()
    }
}
