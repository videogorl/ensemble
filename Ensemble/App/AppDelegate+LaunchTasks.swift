#if os(iOS)
import UIKit
import EnsembleCore
import os.signpost

extension AppDelegate {
    func startEarlyHealthCheckTask() {
        earlyHealthCheckTask = Task { @MainActor in
            let signpostID = OSSignpostID(log: LaunchTaskSignposts.log)
            os_signpost(.begin, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.earlyHealthChecks, signpostID: signpostID)
            defer {
                os_signpost(.end, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.earlyHealthChecks, signpostID: signpostID)
            }

            AppLogger.debug("📱 AppDelegate: Starting network monitor + early health checks at \(Date())")
            DependencyContainer.shared.networkMonitor.startMonitoring()

            // If the cached state was .unknown (first launch or cleared cache),
            // wait briefly for NWPathMonitor to report real state.
            let nm = DependencyContainer.shared.networkMonitor
            if nm.networkState == .unknown {
                for _ in 0..<10 { // 1s max
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if nm.networkState != .unknown { break }
                }
            }

            let sc = DependencyContainer.shared.syncCoordinator
            AppLogger.debug("📱 AppDelegate: Running early health checks (network: \(nm.networkState))...")
            // Route through SyncCoordinator so lastHealthRefreshAt is set,
            // preventing the initial Unknown→Online network transition from
            // triggering a duplicate health check pass.
            await sc.performStartupHealthChecks()
            let shc = DependencyContainer.shared.serverHealthChecker
            AppLogger.debug("📱 AppDelegate: Early health checks complete — serverStates: \(shc.serverStates)")
        }
    }

    func startPlaybackRestoreTaskAfterHealthChecks() {
        // Restore playback state after health checks complete (needs server connectivity).
        // Skip restoration if a Siri playback execution is already in-flight — the Siri
        // handler's intent arrives before restoration completes, so restoring would
        // overwrite the Siri-initiated queue with the previous session's track.
        playbackRestoreTask = Task.detached(priority: .utility) {
            await self.earlyHealthCheckTask?.value

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
                DependencyContainer.shared.playbackService
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

            guard DependencyContainer.shared.networkMonitor.networkState.isConnected else {
                AppLogger.debug(
                    "📱 AppDelegate: Deferring Siri media index/context refresh while network is \(DependencyContainer.shared.networkMonitor.networkState.description)"
                )
                return
            }

            let signpostID = OSSignpostID(log: LaunchTaskSignposts.log)
            os_signpost(.begin, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.siriMediaRefresh, signpostID: signpostID)
            defer {
                os_signpost(.end, log: LaunchTaskSignposts.log, name: LaunchTaskSignposts.siriMediaRefresh, signpostID: signpostID)
            }

            let indexStore = DependencyContainer.shared.siriMediaIndexStore
            if indexStore.loadIndex(maxAge: 3600) == nil {
                let rebuilt = await indexStore.rebuildIndex()
                AppLogger.debug("AppDelegate: Siri media index rebuilt at launch (items: \(rebuilt?.items.count ?? 0))")
            }
            if #available(iOS 16.0, *) {
                EnsembleAppShortcutsProvider.updateAppShortcutParameters()
                AppLogger.debug("SIRI_SHORTCUT: refreshed App Shortcuts parameter metadata")
            }

            // Refresh system media context and Spotlight from the shared media index.
            await DependencyContainer.shared.systemMediaIntegrationService.updateMediaUserContext()
            await DependencyContainer.shared.systemMediaIntegrationService.refreshSpotlightIndex()
        }
    }

    func startWebSocketConnectionsAfterHealthChecks() {
        // Start WebSocket connections after health checks complete.
        // This enables real-time push notifications from Plex servers.
        Task { @MainActor in
            await self.earlyHealthCheckTask?.value
            DependencyContainer.shared.webSocketCoordinator.start()
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
            let syncCoordinator = await MainActor.run {
                DependencyContainer.shared.syncCoordinator
            }
            await syncCoordinator.performStartupSync()
            AppLogger.debug("📱 AppDelegate: Startup sync complete")

            // Start periodic sync timer after startup sync completes.
            await MainActor.run {
                syncCoordinator.startPeriodicSync()
            }
        }
    }

    func startColdLaunchDiagnosticsTask() {
        // Emit one structured startup summary after the launch pipeline settles so
        // device logs capture the post-bootstrap sync/playback/offline state in a
        // single line instead of requiring manual reconstruction from many events.
        coldLaunchDiagnosticsTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.earlyHealthCheckTask?.value
            await self.playbackRestoreTask?.value
            await self.startupSyncTask?.value
            let playbackRestoreWasSuppressedForSiri = await MainActor.run {
                self.startupRestoreWasSuppressedForSiri
            }
            await DependencyContainer.shared.emitColdLaunchDiagnostics(
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
