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
    // Before anything can throw: whatever plays after this hand-off publishes its entity identifier.
    installNowPlayingEntityIdentifiers()
    guard await restoreFocusFilter() else {
        AppLogger.error("SIRI_APP: [origin=\(origin)] Focus filter not restored; refusing to start")
        throw EnsembleIntentError.failed("Ensemble couldn't confirm which libraries are visible. Open Ensemble and try again.")
    }
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

@MainActor private let focusRestoration = SharedRestoration()

/// Restores the active Focus filter, which only a foreground scene does otherwise, so a process started in the
/// background does not search, resolve or play libraries the Focus hides. Returns whether it is restored; when it
/// is not (a slow lookup), the caller must fail closed. Callers share one restoration; see `SharedRestoration`.
@MainActor
func restoreFocusFilter(timeout: Duration = .seconds(2)) async -> Bool {
    await focusRestoration.ensure(timeout: timeout) { await EnsembleFocusFilter.refreshCurrent() }
}

/// Starts the network monitor and waits, for up to `maxWait`, until `networkState` is online or the monitor has
/// delivered a live path; returns whether it started the monitor. A process that starts in the background otherwise reads the state cached by the previous
/// process, so a stale `.offline` or `.limited` would skip server work that the current network allows.
@MainActor
@discardableResult
func startNetworkMonitorAndAwaitCurrentState(_ network: NetworkMonitor, maxWait: Duration = .seconds(3)) async -> Bool {
    let startedMonitor = network.startMonitoring()
    let deadline = ContinuousClock.now + maxWait
    while !network.hasLivePath, !network.isConnected, ContinuousClock.now < deadline {
        // A cancelled sleep returns at once; stop waiting instead of spinning until the deadline.
        guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { break }
    }
    return startedMonitor
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
