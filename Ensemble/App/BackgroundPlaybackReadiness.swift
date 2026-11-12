import EnsembleCore
import Foundation
#if os(iOS)
import UIKit
#endif

/// Brings a process that was started only to play (an App Intent or a Siri hand-off) to the state a launched
/// scene reaches: accounts loaded, server connectivity known, and sync providers registered for stream resolution.
///
/// The connectivity wait is bounded by `timeout` (an intent has about 30 s in all, and a forced health pass can sit
/// behind a 120 s resource timeout). It is skipped offline, where downloaded tracks and queued mutations need no
/// server. Running out of time is not an error: providers still register, and a stream that cannot resolve fails
/// on its own. Missing credentials are an error.
@MainActor
func prepareForBackgroundPlayback(origin: String, timeout: Duration = .seconds(8)) async throws {
    let container = AppRoot.container
    if container.accountManager.credentialLoadState != .loaded {
        await container.accountManager.loadAccountsAsync()
    }
    try Task.checkCancellation()
    guard container.accountManager.credentialLoadState == .loaded else {
        AppLogger.error("SIRI_APP: [origin=\(origin)] Credentials unavailable after loading accounts")
        throw EnsembleIntentError.credentialsUnavailable
    }
    container.serverHealthChecker.prepopulateUnknownStates()

    await waitBounded(timeout) {
        // Offline needs no server, so decide that before joining a health check that cannot succeed.
        let network = container.networkMonitor
        await startNetworkMonitorAndAwaitCurrentState(network)
        guard network.networkState != .offline else {
            AppLogger.info("SIRI_APP: [origin=\(origin)] Offline — skipping server health checks")
            return
        }

        // Join the health checks the launch pipeline already started instead of running a second set.
        #if os(iOS)
        if let earlyTask = (UIApplication.shared.delegate as? AppDelegate)?.earlyHealthCheckTask {
            AppLogger.info("SIRI_APP: [origin=\(origin)] Awaiting early health checks from didFinishLaunching...")
            await earlyTask.value
        }
        #endif

        if !container.serverHealthChecker.serverStates.values.contains(where: \.isAvailable) {
            AppLogger.info("SIRI_APP: [origin=\(origin)] No connected servers — running health checks")
            await container.syncCoordinator.refreshServerHealthStates()
        }
    }

    // A cancelled intent must not register providers or start anything.
    try Task.checkCancellation()
    container.syncCoordinator.refreshProviders()
    AppLogger.info("SIRI_APP: [origin=\(origin)] Server connectivity ready")
}

/// Starts the network monitor and waits, for up to `maxWait`, until `networkState` is online or the monitor has
/// delivered a live path. A process that starts in the background otherwise reads the state cached by the previous
/// process, so a stale `.offline` or `.limited` would skip server work that the current network allows.
@MainActor
func startNetworkMonitorAndAwaitCurrentState(_ network: NetworkMonitor, maxWait: Duration = .seconds(3)) async {
    network.startMonitoring()
    let deadline = ContinuousClock.now + maxWait
    while !network.hasLivePath, !network.isConnected, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Waits for `work` or `timeout`, whichever comes first. `work` is never cancelled: it may be waiting on a health
/// refresh other callers share, and it is harmless once the caller has moved on.
@MainActor
private func waitBounded(_ timeout: Duration, _ work: @escaping @MainActor () async -> Void) async {
    let (finished, signal) = AsyncStream.makeStream(of: Void.self)
    Task { @MainActor in
        await work()
        signal.yield()
    }
    let deadline = Task {
        try? await Task.sleep(for: timeout)
        signal.yield()
    }
    await finished.first { _ in true }
    deadline.cancel()
}
