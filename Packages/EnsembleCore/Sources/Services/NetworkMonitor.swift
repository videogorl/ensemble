import Combine
import Foundation
import Network

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

/// Monitors network connectivity state using NWPathMonitor
@MainActor
public final class NetworkMonitor: ObservableObject {
    @Published public private(set) var networkState: NetworkState = .unknown
    @Published public private(set) var isConnected: Bool = false

    private let monitorFactory: () -> any NetworkPathMonitoring
    private let monitorQueue: DispatchQueue
    private let debounceNanoseconds: UInt64

    private var monitor: (any NetworkPathMonitoring)?
    private var isMonitoring = false
    /// When true, NWPathMonitor updates are ignored so the simulated state sticks
    private var isSimulatingOffline = false
    private var debounceTask: Task<Void, Never>?

    // UserDefaults key for persisting last-known network state across launches
    private static let cachedStateKey = "lastKnownNetworkState"

    internal private(set) var monitorGeneration = 0
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
            networkState = cached
            isConnected = cached.isConnected
            #if DEBUG
            EnsembleLogger.debug("📡 NetworkMonitor: Restored cached state: \(cached.description)")
            #endif
        }
    }

    // MARK: - State Persistence

    /// Persist current network state for optimistic startup on next launch
    private func persistState(_ state: NetworkState) {
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

        #if DEBUG
        EnsembleLogger.debug("📡 NetworkMonitor: Started monitoring (generation \(monitorGeneration))")
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

        #if DEBUG
        EnsembleLogger.debug("📡 NetworkMonitor: Stopped monitoring")
        #endif
    }

    // MARK: - Testing Helpers

    #if DEBUG
    /// Simulate an offline or online state for manual testing from the Settings Developer section.
    /// Sets a flag so NWPathMonitor updates don't overwrite the simulated state.
    public func simulateOffline(_ offline: Bool) {
        isSimulatingOffline = offline
        let state: NetworkState = offline ? .offline : .online(.wifi)
        injectNetworkStateForTesting(state, debounced: false)
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

    internal func injectNetworkStateForTesting(_ state: NetworkState, debounced: Bool = true) {
        if debounced {
            debounceStateUpdate(state: state)
        } else {
            updateState(to: state)
        }
    }

    // MARK: - Private Methods

    /// Debounce network state updates to avoid rapid changes.
    /// Ignored when offline simulation is active so the monitor doesn't overwrite the simulated state.
    private func debounceStateUpdate(path: NWPath) {
        guard !isSimulatingOffline else { return }
        debounceStateUpdate(state: networkState(from: path))
    }

    /// Debounce known state updates for testing and lifecycle-safe handling.
    private func debounceStateUpdate(state: NetworkState) {
        debounceTask?.cancel()

        debounceTask = Task { @MainActor [weak self] in
            if let self, self.debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            }

            guard !Task.isCancelled else { return }
            self?.updateState(to: state)
        }
    }

    /// Update the published state and persist for optimistic startup.
    private func updateState(to newState: NetworkState) {
        let newIsConnected = newState.isConnected
        guard newState != networkState || newIsConnected != isConnected else { return }

        #if DEBUG
        EnsembleLogger.debug("📡 NetworkMonitor: State changed to \(newState.description)")
        #endif

        networkState = newState
        isConnected = newIsConnected
        persistState(newState)
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
        #if DEBUG
        if isConstrained {
            EnsembleLogger.debug(
                "📡 NetworkMonitor: Path is constrained (Low Data Mode) - treating as online \(networkType.description)"
            )
        }
        #endif

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
