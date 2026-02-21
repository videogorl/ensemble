#if os(iOS)
import AVFoundation
import UIKit
import EnsembleCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("📱 AppDelegate: didFinishLaunching at \(Date())")
        
        // Configure audio session for background playback
        configureAudioSession()
        
        // Start network monitoring immediately (non-blocking)
        // Network monitor will publish initial state asynchronously
        Task.detached(priority: .utility) {
            await MainActor.run {
                print("📱 AppDelegate: Starting network monitor at \(Date())")
                DependencyContainer.shared.networkMonitor.startMonitoring()
                print("📱 AppDelegate: Network monitor started at \(Date())")
            }
        }
        
        // Restore playback state after network monitor has had time to detect connectivity
        // This prevents false "offline" errors during startup
        Task.detached(priority: .utility) {
            print("📱 AppDelegate: Waiting for network monitor to initialize...")
            
            // Wait for network monitor to report a non-Unknown state
            let networkMonitor = await MainActor.run { DependencyContainer.shared.networkMonitor }
            var attempts = 0
            let maxAttempts = 20 // 2 seconds max wait
            
            while attempts < maxAttempts {
                let state = await MainActor.run { networkMonitor.networkState }
                if state != .unknown {
                    print("📱 AppDelegate: Network state detected: \(state)")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                attempts += 1
            }
            
            // Small additional delay to ensure connections are stable
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            print("📱 AppDelegate: Getting playbackService...")
            let playbackService = await MainActor.run {
                DependencyContainer.shared.playbackService
            }
            print("📱 AppDelegate: Calling restorePlaybackState()...")
            await playbackService.restorePlaybackState()
            print("📱 AppDelegate: Playback state restoration complete")
        }
        
        // Perform startup sync (non-blocking, runs in background)
        Task.detached(priority: .utility) {
            // Wait a bit longer to ensure the app is fully initialized
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            print("📱 AppDelegate: Starting startup sync...")
            let syncCoordinator = await MainActor.run {
                DependencyContainer.shared.syncCoordinator
            }
            await syncCoordinator.performStartupSync()
            print("📱 AppDelegate: Startup sync complete")
            
            // Start periodic sync timer after startup sync completes
            await MainActor.run {
                syncCoordinator.startPeriodicSync()
            }
        }
        
        print("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        return true
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
            print("Failed to configure audio session: \(error)")
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

            // Proactively check server health and update connections
            // (network monitor will also trigger this, but doing it immediately ensures faster failover)
            await DependencyContainer.shared.serverHealthChecker.checkAllServers()
            await DependencyContainer.shared.syncCoordinator.refreshAPIClientConnections()
            
            // Restart periodic sync timers
            DependencyContainer.shared.syncCoordinator.startPeriodicSync()
        }
    }
}
#endif
