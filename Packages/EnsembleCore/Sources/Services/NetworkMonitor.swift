import Foundation
import Network
import Combine

/// Monitors network connectivity state using NWPathMonitor
@MainActor
public final class NetworkMonitor: ObservableObject {
    @Published public private(set) var networkState: NetworkState = .unknown
    @Published public private(set) var isConnected: Bool = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.ensemble.networkmonitor")
    private var isMonitoring = false
    private var debounceTask: Task<Void, Never>?

    public init() {}

    // MARK: - Public Methods

    /// Start monitoring network state changes
    public func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true

        monitor.pathUpdateHandler = { [weak self] path in
            // Debounce rapid network changes to avoid excessive health checks
            Task { @MainActor [weak self] in
                self?.debounceStateUpdate(path: path)
            }
        }

        monitor.start(queue: monitorQueue)
        print("📡 NetworkMonitor: Started monitoring")
    }

    /// Stop monitoring network state changes (for battery optimization)
    public func stopMonitoring() {
        guard isMonitoring else { return }

        monitor.cancel()
        isMonitoring = false
        debounceTask?.cancel()
        debounceTask = nil

        print("📡 NetworkMonitor: Stopped monitoring")
    }

    // MARK: - Private Methods

    /// Debounce network state updates to avoid rapid changes
    private func debounceStateUpdate(path: NWPath) {
        // Cancel any pending update
        debounceTask?.cancel()

        // Schedule new update after 300ms
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

            guard !Task.isCancelled else { return }
            self?.updateState(from: path)
        }
    }

    /// Update the published state based on NWPath
    private func updateState(from path: NWPath) {
        let newState = networkState(from: path)
        let newIsConnected = newState.isConnected

        // Only publish if state actually changed
        if newState != networkState || newIsConnected != isConnected {
            print("📡 NetworkMonitor: State changed to \(newState.description)")
            networkState = newState
            isConnected = newIsConnected
        }
    }

    /// Convert NWPath to NetworkState
    private func networkState(from path: NWPath) -> NetworkState {
        switch path.status {
        case .satisfied:
            // Check if it's a captive portal (limited connectivity)
            if path.isConstrained {
                return .limited
            }
            return .online(networkType(from: path))

        case .unsatisfied:
            return .offline

        case .requiresConnection:
            return .offline

        @unknown default:
            return .unknown
        }
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
        monitor.cancel()
        debounceTask?.cancel()
    }
}
