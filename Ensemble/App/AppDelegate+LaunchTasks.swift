#if os(iOS)
import UIKit
import EnsembleCore
import os.signpost

extension AppDelegate {
    /// Starts the launch work that needs a foreground process, never while the process is in the background.
    /// A foreground launch calls it from `didFinishLaunching`; a process launched in the background (intent,
    /// Siri, refresh) calls it from its `.active` scene phases. Health checks and WebSockets start once.
    /// Startup sync, the Siri/Spotlight refresh and the iCloud bootstrap start once too, but are retried at a later activation
    /// if the app left the foreground before they were allowed to run. A background intent that needs servers
    /// runs its own bounded health check in `prepareForBackgroundPlayback`.
    func startForegroundLaunchWork() {
        let container = AppRoot.container
        let isForeground = container.foregroundWorkScheduler.isForegroundActive
        if foregroundLaunchWorkGate.claim(isForeground: isForeground) {
            AppLogger.info("LAUNCH_WORK: starting foreground launch work (health checks, WebSockets, startup sync, Siri/Spotlight refresh)")
            startEarlyHealthCheckTask()
            startWebSocketConnectionsAfterHealthChecks()
            startColdLaunchDiagnosticsTask()
        }
        if foregroundLaunchWorkGate.claimSiriRefresh(isForeground: isForeground) {
            startSiriIndexAndContextRefreshAfterHealthChecks()
        }
        if foregroundLaunchWorkGate.claimStartupSync(isForeground: isForeground) {
            startStartupSyncTaskAfterHealthChecks()
        }
        // A no-op unless the bootstrap was skipped while the scene was not active.
        container.resumeDeferredCloudBootstrap()
    }

    func startEarlyHealthCheckTask() {
        earlyHealthCheckTask = Task { @MainActor in
            let signpostID = OSSignpostID(log: LaunchTaskSignposts.log)
            os_signpost(.begin, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.earlyHealthChecks, signpostID: signpostID)
            defer {
                os_signpost(.end, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.earlyHealthChecks, signpostID: signpostID)
            }

            AppLogger.debug("📱 AppDelegate: Starting network monitor + early health checks at \(Date())")
            AppRoot.container.networkMonitor.startMonitoring()

            // If the cached state was .unknown (first launch or cleared cache),
            // wait briefly for NWPathMonitor to report real state.
            let nm = AppRoot.container.networkMonitor
            if nm.networkState == .unknown {
                for _ in 0..<10 { // 1s max
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if nm.networkState != .unknown { break }
                }
            }

            let sc = AppRoot.container.syncCoordinator
            AppLogger.debug("📱 AppDelegate: Running early health checks (network: \(nm.networkState))...")
            // Route through SyncCoordinator so lastHealthRefreshAt is set,
            // preventing the initial Unknown→Online network transition from
            // triggering a duplicate health check pass.
            await sc.performStartupHealthChecks()
            let shc = AppRoot.container.serverHealthChecker
            AppLogger.debug("📱 AppDelegate: Early health checks complete — serverStates: \(shc.serverStates)")
        }
    }

    func startPlaybackRestoreTask() {
        // Local queue hydration does not require server connectivity.
        // Skip restoration if a Siri playback execution is already in-flight — the Siri
        // handler's intent arrives before restoration completes, so restoring would
        // overwrite the Siri-initiated queue with the previous session's track.
        playbackRestoreTask = Task.detached(priority: .userInitiated) {

            let hasPending = await MainActor.run { (UIApplication.shared.delegate as? AppDelegate)?.hasPendingSiriIntent ?? false }
            if hasPending || SiriPlaybackExecutionGate.isExecuting {
                await MainActor.run {
                    self.startupRestoreWasSuppressedForSiri = true
                }
                AppLogger.debug("📱 AppDelegate: Skipping playback restoration — Siri intent pending/in-flight")
                return
            }

            AppLogger.debug("📱 AppDelegate: Getting playbackService...")
            let playbackService = await MainActor.run {
                AppRoot.container.playbackService
            }
            AppLogger.debug("📱 AppDelegate: Calling restorePlaybackState()...")
            await playbackService.restorePlaybackState()
            AppLogger.debug("📱 AppDelegate: Playback state restoration complete")
        }
    }

    func startSiriIndexAndContextRefreshAfterHealthChecks() {
        // Siri media index and WebSocket connections are sequenced behind health checks
        // so earlyHealthCheckTask gets uncontested MainActor time during launch.
        // Both start immediately after health checks (~0.4s on simulator, ~3-7s on device).
        Task { @MainActor in
            await self.earlyHealthCheckTask?.value

            guard AppRoot.container.networkMonitor.networkState.isConnected else {
                AppLogger.debug(
                    "📱 AppDelegate: Deferring Siri media index/context refresh while network is \(AppRoot.container.networkMonitor.networkState.description); the next activation retries it"
                )
                self.foregroundLaunchWorkGate.finishSiriRefresh(ran: false)
                return
            }

            let signpostID = OSSignpostID(log: LaunchTaskSignposts.log)
            os_signpost(.begin, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.siriMediaRefresh, signpostID: signpostID)
            defer {
                os_signpost(.end, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.siriMediaRefresh, signpostID: signpostID)
            }

            let ran = await refreshSystemMediaSurfaces()
            self.foregroundLaunchWorkGate.finishSiriRefresh(ran: ran)
        }
    }

    func startWebSocketConnectionsAfterHealthChecks() {
        // Start WebSocket connections after health checks complete.
        // This enables real-time push notifications from Plex servers.
        Task { @MainActor in
            await self.earlyHealthCheckTask?.value
            AppRoot.container.webSocketCoordinator.start()
        }
    }

    func startStartupSyncTaskAfterHealthChecks() {
        // Perform startup sync after early health checks complete so sync requests
        // inherit the same endpoint selection as playback restore and WebSocket setup.
        // Without this sequencing, startup sync can race a stale local URL and spend
        // its first request budget on a timeout before failover updates the client.
        let appGroupIdentifier = Self.appGroupIdentifier
        let pendingPlaybackFilename = Self.pendingPlaybackFilename
        startupSyncTask = Task.detached(priority: .utility) {
            await self.earlyHealthCheckTask?.value
            let signpostID = OSSignpostID(log: LaunchTaskSignposts.log)
            os_signpost(.begin, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.startupSync, signpostID: signpostID)
            defer {
                os_signpost(.end, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.startupSync, signpostID: signpostID)
            }

            // Check if Siri playback was recently triggered. If so, wait a short time
            // to let the audio session activate and route selection complete.
            // Sync at .utility priority won't compete meaningfully with the Siri audio
            // path which runs at default/userInitiated priority.
            let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            let pendingFile = appGroup?.appendingPathComponent(pendingPlaybackFilename)
            let hasPendingSiri = pendingFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

            if hasPendingSiri {
                AppLogger.debug("📱 AppDelegate: Pending Siri playback detected, deferring startup sync 2s...")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s for audio session setup
            }

            AppLogger.debug("📱 AppDelegate: Starting startup sync...")
            let (syncCoordinator, foregroundWorkScheduler) = await MainActor.run {
                (
                    AppRoot.container.syncCoordinator,
                    AppRoot.container.foregroundWorkScheduler
                )
            }
            guard await foregroundWorkScheduler.waitUntilAllowed(.startupSync, policy: .idleOnly) else {
                AppLogger.debug("📱 AppDelegate: Startup sync skipped because foreground work is unavailable; the next activation retries it")
                await MainActor.run { self.foregroundLaunchWorkGate.finishStartupSync(ran: false) }
                return
            }
            await MainActor.run {
                foregroundWorkScheduler.setStartupSyncInFlight(true)
            }
            defer {
                Task { @MainActor in
                    foregroundWorkScheduler.setStartupSyncInFlight(false)
                }
            }
            await syncCoordinator.performStartupSync()
            await MainActor.run { self.foregroundLaunchWorkGate.finishStartupSync(ran: true) }
            AppLogger.debug("📱 AppDelegate: Startup sync complete")
        }
    }

    func startColdLaunchDiagnosticsTask() {
        // Emit one structured startup summary after the launch pipeline settles so
        // device logs capture the post-bootstrap sync/playback/offline state in a
        // single line instead of requiring manual reconstruction from many events.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.earlyHealthCheckTask?.value
            await self.playbackRestoreTask?.value
            await self.startupSyncTask?.value
            let playbackRestoreWasSuppressedForSiri = await MainActor.run {
                self.startupRestoreWasSuppressedForSiri
            }
            await AppRoot.container.emitColdLaunchDiagnostics(
                playbackRestoreWasSuppressedForSiri: playbackRestoreWasSuppressedForSiri
            )
        }
    }
}

private enum LaunchTaskSignposts {
    static let log = OSLog(subsystem: "com.videogorl.ensemble", category: "startup-performance")
    static let earlyHealthChecks: StaticString = "Early Health Checks"
    static let siriMediaRefresh: StaticString = "Siri Media Refresh"
    static let startupSync: StaticString = "Startup Sync"
}
#endif
