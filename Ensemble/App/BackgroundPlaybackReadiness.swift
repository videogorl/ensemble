import EnsembleCore
import Foundation
#if os(iOS)
import UIKit
#endif

/// Brings a process that was started only to play (an App Intent or a Siri hand-off) to the state a launched
/// scene reaches: accounts loaded, server connectivity known, and sync providers registered for stream resolution.
@MainActor
func prepareForBackgroundPlayback(origin: String) async {
    let container = AppRoot.container
    if container.accountManager.credentialLoadState != .loaded {
        await container.accountManager.loadAccountsAsync()
    }
    container.serverHealthChecker.prepopulateUnknownStates()
    container.networkMonitor.startMonitoring()

    // Join the health checks the launch pipeline already started instead of running a second set.
    #if os(iOS)
    if let earlyTask = (UIApplication.shared.delegate as? AppDelegate)?.earlyHealthCheckTask {
        AppLogger.info("SIRI_APP: [origin=\(origin)] Awaiting early health checks from didFinishLaunching...")
        await earlyTask.value
    }
    #endif

    let health = container.serverHealthChecker
    if !health.serverStates.values.contains(where: \.isAvailable) {
        AppLogger.info("SIRI_APP: [origin=\(origin)] No connected servers — running health checks")
        let network = container.networkMonitor
        for _ in 0..<10 where network.networkState == .unknown {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await container.syncCoordinator.refreshServerHealthStates()
    }

    // Build sync providers using the canonical account/server clients.
    container.syncCoordinator.refreshProviders()
    AppLogger.info("SIRI_APP: [origin=\(origin)] Server connectivity ready")
}
