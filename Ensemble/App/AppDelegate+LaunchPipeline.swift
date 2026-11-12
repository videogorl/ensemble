#if os(iOS)
import UIKit
import EnsembleCore

extension AppDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchPhaseStart = Date()
        func logLaunchPhase(_ phase: String) {
            let elapsed = Date().timeIntervalSince(launchPhaseStart)
            AppLogger.info("PERF_LAUNCH: \(phase) elapsed=\(String(format: "%.3f", elapsed))s")
        }

        AppLogger.debug("📱 AppDelegate: didFinishLaunching at \(Date())")
        logLaunchPhase("didFinishLaunching.start")
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillEnterForeground(_:)),
            name: UIScene.willEnterForegroundNotification,
            object: nil
        )

        configureSiriAuthorization()
        logLaunchPhase("siriAuthorization.configured")

        // Register for Darwin notifications from Siri extension
        registerForSiriPendingPlaybackNotification()
        registerForSiriAffinityNotification()
        registerForSiriAddToPlaylistNotification()
        logLaunchPhase("siriNotifications.registered")

        let dependencies = AppRoot.container
        logLaunchPhase("dependencyContainer.ready")

        // Before any launch work, so a launch with no scene (App Intent, Siri) writes a session log too.
        let launchKind = ProcessLaunchKind.classify(
            hasUserActivity: launchOptions?[.userActivityDictionary] != nil,
            hasURL: launchOptions?[.url] != nil,
            hasRemoteNotification: launchOptions?[.remoteNotification] != nil
        )
        AppRoot.startPersistentLogSession(launch: launchKind)

        // No scene exists yet, so `applicationState` is `.background` even for a foreground launch and cannot
        // classify it. Unless the launch options say the user started it, assume background before any launch task
        // runs, so the scheduler and download service do not treat it as foreground; the window scene entering the
        // foreground (`sceneWillEnterForeground`) starts the launch work and flips the scheduler.
        let isForegroundLaunch = launchKind.isForegroundLaunch(
            applicationIsBackground: application.applicationState == .background
        )
        if !isForegroundLaunch {
            dependencies.foregroundWorkScheduler.setForegroundActive(false)
            dependencies.offlineDownloadService.beginInBackground()
        }

        // CloudKit profile sync relies on silent push delivery for live updates.
        application.registerForRemoteNotifications()
        logLaunchPhase("remoteNotifications.requested")

        // Load accounts synchronously before any Siri/playback code runs.
        // This is critical for cold launches from Siri where the coordinator
        // needs accounts loaded before RootView.task has a chance to run.
        dependencies.accountManager.loadAccounts()
        logLaunchPhase("accounts.loaded")

        EnsembleAppShortcutsProvider.updateAppShortcutParameters()
        AppLogger.debug("SIRI_SHORTCUT: refreshed App Shortcuts parameter metadata at launch")
        logLaunchPhase("appShortcuts.refreshed")

        // Pre-populate server health states with .unknown immediately after accounts load.
        // This ensures TrackAvailabilityResolver treats tracks from unchecked servers as
        // unavailable (dimmed) until health checks confirm reachability, preventing the
        // brief window where all tracks appear available at startup.
        dependencies.serverHealthChecker.prepopulateUnknownStates()
        logLaunchPhase("serverHealth.prepopulated")

        // Playback restore stays on every launch: current-track intents need the queue.
        if isForegroundLaunch {
            AppLogger.info("LAUNCH_WORK: kind=\(launchKind.rawValue) foregroundLaunchWork=started")
            startForegroundLaunchWork()
        } else {
            AppLogger.info("LAUNCH_WORK: kind=\(launchKind.rawValue) foregroundLaunchWork=deferred until a window scene enters the foreground")
        }
        startPlaybackRestoreTask()
        logLaunchPhase("launchTasks.scheduled")
        
        AppLogger.debug("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        logLaunchPhase("didFinishLaunching.return")
        return true
    }

    /// The earliest reliable foreground signal. UIKit posts it when a scene is about to become visible, never for a
    /// scene connected in the background (a snapshot, an intent or a background task), so it cannot start launch
    /// work for a background-only process. It precedes the first `.active` scene phase, which stays the fallback.
    /// The scheduler flips first: the gate only claims while it reports foreground.
    @objc
    func sceneWillEnterForeground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene.session.role == .windowApplication,
              !foregroundLaunchWorkGate.hasStarted else { return }
        AppLogger.info("LAUNCH_WORK: kind=\(ProcessLaunchKind.foregroundScene.rawValue) window scene entering the foreground")
        AppRoot.container.foregroundWorkScheduler.setForegroundActive(true)
        startForegroundLaunchWork()
    }

    // Audio session configuration moved to PlaybackService.ensureAudioSessionConfigured()
    // to avoid Code=-50 errors when configuring before the audio system is ready.
}
#endif
