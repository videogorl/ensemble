#if os(iOS)
import AVFoundation
import UIKit
import EnsembleCore

class AppDelegate: NSObject, UIApplicationDelegate {
    private var coverFlowRotationSupportEnabled = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLogger.debug("📱 AppDelegate: didFinishLaunching at \(Date())")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCoverFlowRotationSupportChanged(_:)),
            name: AppOrientationNotifications.coverFlowRotationSupportChanged,
            object: nil
        )
        
        // Configure audio session for background playback
        configureAudioSession()
        
        // Start network monitoring immediately (non-blocking)
        // Network monitor will publish initial state asynchronously
        Task.detached(priority: .utility) {
            await MainActor.run {
                AppLogger.debug("📱 AppDelegate: Starting network monitor at \(Date())")
                DependencyContainer.shared.networkMonitor.startMonitoring()
                AppLogger.debug("📱 AppDelegate: Network monitor started at \(Date())")
            }
        }
        
        // Restore playback state after network monitor has had time to detect connectivity
        // This prevents false "offline" errors during startup
        Task.detached(priority: .utility) {
            AppLogger.debug("📱 AppDelegate: Waiting for network monitor to initialize...")
            
            // Wait for network monitor to report a non-Unknown state
            let networkMonitor = await MainActor.run { DependencyContainer.shared.networkMonitor }
            var attempts = 0
            let maxAttempts = 20 // 2 seconds max wait
            
            while attempts < maxAttempts {
                let state = await MainActor.run { networkMonitor.networkState }
                if state != .unknown {
                    AppLogger.debug("📱 AppDelegate: Network state detected: \(state)")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                attempts += 1
            }
            
            // Small additional delay to ensure connections are stable
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            AppLogger.debug("📱 AppDelegate: Getting playbackService...")
            let playbackService = await MainActor.run {
                DependencyContainer.shared.playbackService
            }
            AppLogger.debug("📱 AppDelegate: Calling restorePlaybackState()...")
            await playbackService.restorePlaybackState()
            AppLogger.debug("📱 AppDelegate: Playback state restoration complete")
        }
        
        // Perform startup sync (non-blocking, runs in background)
        Task.detached(priority: .utility) {
            // Wait a bit longer to ensure the app is fully initialized
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
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
        
        AppLogger.debug("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        return true
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: AppOrientationNotifications.coverFlowRotationSupportChanged,
            object: nil
        )
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            AppLogger.debug("Failed to configure audio session: \(error)")
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Handle background download completion
        completionHandler()
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Stop network monitoring to save battery
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.stopMonitoring()
            
            // Stop periodic sync timers
            DependencyContainer.shared.syncCoordinator.stopPeriodicSync()
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        // Resume network monitoring when app returns to foreground
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.startMonitoring()

            // Route foreground refresh through SyncCoordinator to coalesce
            // with network state transitions and cooldown/staleness guards.
            await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()
            
            // Restart periodic sync timers
            DependencyContainer.shared.syncCoordinator.startPeriodicSync()
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if coverFlowRotationSupportEnabled {
            return .allButUpsideDown
        }
        return .portrait
    }

    @objc
    private func handleCoverFlowRotationSupportChanged(_ notification: Notification) {
        guard let isEnabled = notification.object as? Bool else { return }
        guard coverFlowRotationSupportEnabled != isEnabled else { return }

        coverFlowRotationSupportEnabled = isEnabled
        refreshSupportedOrientations()
    }

    private func refreshSupportedOrientations() {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                if #available(iOS 16.0, *) {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }

        UIViewController.attemptRotationToDeviceOrientation()
    }
}
#endif
