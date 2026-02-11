import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPerformedStartupSync = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.dependencies, DependencyContainer.shared)
                .onOpenURL { url in
                    _ = DependencyContainer.shared.navigationCoordinator.handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        #if os(macOS)
        Task { @MainActor in
            switch phase {
            case .active:
                // Start monitoring when app becomes active (macOS)
                DependencyContainer.shared.networkMonitor.startMonitoring()
                
                // Perform startup sync on first activation (macOS only)
                if !hasPerformedStartupSync {
                    hasPerformedStartupSync = true
                    Task.detached(priority: .utility) {
                        // Wait for network monitor to stabilize
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        
                        print("💻 macOS: Starting startup sync...")
                        let syncCoordinator = await MainActor.run {
                            DependencyContainer.shared.syncCoordinator
                        }
                        await syncCoordinator.performStartupSync()
                        print("💻 macOS: Startup sync complete")
                    }
                }
            case .background:
                // Stop monitoring when app goes to background (macOS)
                DependencyContainer.shared.networkMonitor.stopMonitoring()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        #endif
    }
}
