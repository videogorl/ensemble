import Combine
import EnsembleSupport
import Foundation

/// Monitors device power and thermal state and publishes changes.
/// Consumers (Aurora, LyricsCard, OfflineDownloadService) observe `isLowPowerMode`
/// to reduce GPU work and network activity when the device is conserving energy.
@MainActor
@Observable
public final class PowerStateMonitor {
    public private(set) var isLowPowerMode: Bool {
        didSet { if isLowPowerMode != oldValue { broadcast.send(snapshot) } }
    }
    public private(set) var thermalState: ProcessInfo.ThermalState {
        didSet { if thermalState != oldValue { broadcast.send(snapshot) } }
    }

    public struct Snapshot: Equatable, Sendable {
        public var isLowPowerMode: Bool
        public var thermalState: ProcessInfo.ThermalState
    }

    public var snapshot: Snapshot {
        Snapshot(isLowPowerMode: isLowPowerMode, thermalState: thermalState)
    }
    @ObservationIgnored private let broadcast = Broadcast<Snapshot>()

    /// The current snapshot, then each change.
    public func snapshots() -> AsyncStream<Snapshot> {
        broadcast.stream(startingWith: snapshot)
    }

    // NotificationCenter publishers are Apple's transport for these system signals.
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    public init() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState

        // Listen for power state changes (Low Power Mode toggled on/off)
        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard self?.isLowPowerMode != newValue else { return }
                self?.isLowPowerMode = newValue

                EnsembleLogger.info("⚡ PowerStateMonitor: Low Power Mode \(newValue ? "enabled" : "disabled")")
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let newValue = ProcessInfo.processInfo.thermalState
                guard self?.thermalState != newValue else { return }
                self?.thermalState = newValue
                EnsembleLogger.info("🌡️ PowerStateMonitor: thermal state \(Self.label(for: newValue))")
            }
            .store(in: &cancellables)
    }

    private static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
