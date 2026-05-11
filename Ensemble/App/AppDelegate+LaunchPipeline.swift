#if os(iOS)
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

        startEarlyHealthCheckTask()
        startPlaybackRestoreTaskAfterHealthChecks()
        startSiriIndexAndContextRefreshAfterHealthChecks()
        startWebSocketConnectionsAfterHealthChecks()
        startStartupSyncTaskAfterHealthChecks()
        startColdLaunchDiagnosticsTask()
        
        AppLogger.debug("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        return true
    }

    // Audio session configuration moved to PlaybackService.ensureAudioSessionConfigured()
    // to avoid Code=-50 errors when configuring before the audio system is ready.
}
#endif
