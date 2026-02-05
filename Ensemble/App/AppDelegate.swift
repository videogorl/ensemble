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
        
        // Start network monitoring with a delay to avoid blocking app launch
        // This allows the UI to become responsive first
        Task.detached(priority: .utility) {
            print("📱 AppDelegate: Delayed network monitor start at \(Date())")
            // Small delay to let UI initialize
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                print("📱 AppDelegate: Starting network monitor at \(Date())")
                DependencyContainer.shared.networkMonitor.startMonitoring()
                print("📱 AppDelegate: Network monitor started at \(Date())")
            }
        }
        
        // Restore playback state
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            let playbackService = await MainActor.run {
                DependencyContainer.shared.playbackService
            }
            await playbackService.restorePlaybackState()
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
        }
    }
}
