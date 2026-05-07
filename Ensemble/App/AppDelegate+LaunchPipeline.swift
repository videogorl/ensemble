#if os(iOS)
import Intents
import UIKit
import EnsembleCore

extension AppDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLogger.debug("📱 AppDelegate: didFinishLaunching at \(Date())")
        EnsembleStartupTiming.launchTime = AppDelegate.launchTime
        startupRestoreWasSuppressedForSiri = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStageFlowRotationSupportChanged(_:)),
            name: AppOrientationNotifications.stageFlowRotationSupportChanged,
            object: nil
        )
        
        // Audio session is configured lazily on first playback (PlaybackService.ensureAudioSessionConfigured)
        // to avoid Code=-50 failures at launch before the audio system is ready.
        configureSiriAuthorization()

        // Install space-bar → play/pause hardware keyboard shortcut
        SpaceBarPlaybackShortcut.install()

        // Register for Darwin notifications from Siri extension
        registerForSiriPendingPlaybackNotification()
        registerForSiriAffinityNotification()
        registerForSiriAddToPlaylistNotification()

        // Register optional iOS 26+ continued processing handler for offline downloads.
        DependencyContainer.shared.offlineBackgroundExecutionCoordinator.register()

        // CloudKit profile sync relies on silent push delivery for live updates.
        application.registerForRemoteNotifications()

        // Load accounts synchronously before any Siri/playback code runs.
        // This is critical for cold launches from Siri where the coordinator
        // needs accounts loaded before RootView.task has a chance to run.
        DependencyContainer.shared.accountManager.loadAccounts()

        // Pre-populate server health states with .unknown immediately after accounts load.
        // This ensures TrackAvailabilityResolver treats tracks from unchecked servers as
        // unavailable (dimmed) until health checks confirm reachability, preventing the
        // brief window where all tracks appear available at startup.
        DependencyContainer.shared.serverHealthChecker.prepopulateUnknownStates()

        // Start network monitor and health checks in a single high-priority task.
        // NetworkMonitor restores cached state on init (usually Online from the
        // previous session), so health checks can begin immediately without polling
        // for network state — this eliminates ~1.5s of scheduling + poll overhead.
        // The task is stored so executeSiriPlaybackInBackground can await it instead
        // of running redundant checks.
        earlyHealthCheckTask = Task { @MainActor in
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

        // Restore playback state after health checks complete (needs server connectivity).
        // Skip restoration if a Siri playback execution is already in-flight — the Siri
        // handler's intent arrives before restoration completes, so restoring would
        // overwrite the Siri-initiated queue with the previous session's track.
        playbackRestoreTask = Task.detached(priority: .utility) {
            // Wait for early health checks to finish (they populate server endpoints)
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

        // Siri media index and WebSocket connections are sequenced behind health checks
        // so earlyHealthCheckTask gets uncontested MainActor time during launch.
        // Both start immediately after health checks (~0.4s on simulator, ~3-7s on device).
        Task { @MainActor in
            await self.earlyHealthCheckTask?.value

            let indexStore = DependencyContainer.shared.siriMediaIndexStore
            if indexStore.loadIndex(maxAge: 3600) == nil {
                let rebuilt = await indexStore.rebuildIndex()
                AppLogger.debug("AppDelegate: Siri media index rebuilt at launch (items: \(rebuilt?.items.count ?? 0))")
            }
            if #available(iOS 16.0, *) {
                EnsembleAppShortcutsProvider.updateAppShortcutParameters()
                AppLogger.debug("SIRI_SHORTCUT: refreshed App Shortcuts parameter metadata")
            }

            // Update Siri media user context with current library statistics
            await DependencyContainer.shared.siriMediaUserContextManager.updateMediaUserContext()
        }

        // Start WebSocket connections after health checks complete.
        // This enables real-time push notifications from Plex servers.
        Task { @MainActor in
            await self.earlyHealthCheckTask?.value
            DependencyContainer.shared.webSocketCoordinator.start()
        }

        // Perform startup sync after early health checks complete so sync requests
        // inherit the same endpoint selection as playback restore and WebSocket setup.
        // Without this sequencing, startup sync can race a stale local URL and spend
        // its first request budget on a timeout before failover updates the client.
        let appGroupIdentifier = Self.appGroupIdentifier
        let pendingPlaybackFilename = Self.pendingPlaybackFilename
        startupSyncTask = Task.detached(priority: .utility) {
            await self.earlyHealthCheckTask?.value

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

            // Start periodic sync timer after startup sync completes
            await MainActor.run {
                syncCoordinator.startPeriodicSync()
            }
        }

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
        
        AppLogger.debug("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppLogger.debug("📱 AppDelegate: Registered for remote notifications")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.debug("📱 AppDelegate: Remote notification registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let didHandle = await DependencyContainer.shared.cloudSyncService.handleRemoteNotification(userInfo: userInfo)
            completionHandler(didHandle ? .newData : .noData)
        }
    }

    // Audio session configuration moved to PlaybackService.ensureAudioSessionConfigured()
    // to avoid Code=-50 errors when configuring before the audio system is ready.

    private func configureSiriAuthorization() {
        let status = INPreferences.siriAuthorizationStatus()
        AppLogger.debug("AppDelegate: Siri authorization status at launch: \(status.rawValue)")

        guard status == .notDetermined else {
            return
        }

        INPreferences.requestSiriAuthorization { newStatus in
            AppLogger.debug("AppDelegate: Siri authorization prompt result: \(newStatus.rawValue)")
        }
    }
}
#endif
