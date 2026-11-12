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
        // runs, so the scheduler and download service do not treat it as foreground; the first `.active` scene
        // phase starts the launch work and flips the scheduler.
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
            AppLogger.info("LAUNCH_WORK: kind=\(launchKind.rawValue) foregroundLaunchWork=deferred until the first foreground activation")
        }
        startPlaybackRestoreTask()
        logLaunchPhase("launchTasks.scheduled")
        
        AppLogger.debug("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        logLaunchPhase("didFinishLaunching.return")
        return true
    }

    // Audio session configuration moved to PlaybackService.ensureAudioSessionConfigured()
    // to avoid Code=-50 errors when configuring before the audio system is ready.
}
#endif
