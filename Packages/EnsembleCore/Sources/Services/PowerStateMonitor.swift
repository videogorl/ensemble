import Combine
import Foundation
import os

/// Monitors device low power mode state and publishes changes.
/// Consumers (Aurora, LyricsCard, OfflineDownloadService) observe `isLowPowerMode`
/// to reduce GPU work and network activity when the device is conserving energy.
@MainActor
public final class PowerStateMonitor: ObservableObject {
    @Published public private(set) var isLowPowerMode: Bool

    /// Publisher for non-SwiftUI consumers that need Combine-based observation
    public var isLowPowerModePublisher: AnyPublisher<Bool, Never> {
        $isLowPowerMode.eraseToAnyPublisher()
    }

    private var cancellable: AnyCancellable?

    public init() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Listen for power state changes (Low Power Mode toggled on/off)
        cancellable = NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard self?.isLowPowerMode != newValue else { return }
                self?.isLowPowerMode = newValue

                #if DEBUG
                EnsembleLogger.info("⚡ PowerStateMonitor: Low Power Mode \(newValue ? "enabled" : "disabled")")
                #endif
            }
    }
}
