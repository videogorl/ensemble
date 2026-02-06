import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    @Environment(\.scenePhase) private var scenePhase

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
