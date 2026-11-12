import EnsembleCore
import Foundation
#if os(iOS)
import UIKit
#endif

/// Brings a process that was started only to play (an App Intent or a Siri hand-off) to the state a launched
/// scene reaches: Focus filter restored, accounts loaded, network state current, and sync providers registered
/// for stream resolution.
///
/// It does not wait for server health. Playback resolves a local or cached file without a server, and otherwise
/// checks only the track's own server (`SyncCoordinator.ensureServerConnection`); a server whose health is still
/// unknown counts as available. The all-servers health pass starts here (unless the launch pipeline already has
/// it running) for the rest of the app, and is skipped offline. Missing credentials are an error.
@MainActor
func prepareForBackgroundPlayback(origin: String) async throws {
    let container = AppRoot.container
    // The network wait is independent of the Focus lookup, so they overlap.
    async let networkReady = startNetworkMonitorAndAwaitCurrentState(container.networkMonitor)
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
    _ = await networkReady

    // A cancelled intent must not register providers or start anything.
    try Task.checkCancellation()
    container.syncCoordinator.refreshProviders()
    startServerHealthChecksIfNeeded(origin: origin)
    AppLogger.info("SIRI_APP: [origin=\(origin)] Ready for playback")
}

/// Starts, without awaiting, the health pass that a foreground launch would have started. Offline needs no server.
@MainActor
private func startServerHealthChecksIfNeeded(origin: String) {
    guard AppRoot.container.networkMonitor.networkState != .offline else {
        AppLogger.info("SIRI_APP: [origin=\(origin)] Offline — skipping server health checks")
        return
    }
    #if os(iOS)
    if (UIApplication.shared.delegate as? AppDelegate)?.earlyHealthCheckTask != nil { return }
    #endif
    AppLogger.info("SIRI_APP: [origin=\(origin)] Starting server health checks in the background")
    Task { @MainActor in await AppRoot.container.syncCoordinator.refreshServerHealthStates() }
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
