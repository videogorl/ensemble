import EnsembleCore
import EnsembleUI
import OSLog
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

enum AppLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "app")

    static func debug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { String(describing: $0) }.joined(separator: separator)
        let suffix = terminator == "\n" ? "" : terminator
        logger.debug("\(message + suffix, privacy: .public)")
    }
}

@main
struct EnsembleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPerformedStartupSync = false
    #if os(iOS)
    @State private var hasScheduledBackgroundRefresh = false
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.dependencies, DependencyContainer.shared)
                .installGlobalToastWindow(toastCenter: DependencyContainer.shared.toastCenter)
                .onOpenURL { url in
                    _ = DependencyContainer.shared.navigationCoordinator.handleDeepLink(url)
                }
        }
        .applyBackgroundRefresh()
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            if phase == .active && !hasScheduledBackgroundRefresh {
                // Schedule only after SwiftUI has registered the backgroundTask handler.
                BackgroundSyncScheduler.shared.scheduleAppRefresh()
                hasScheduledBackgroundRefresh = true
            }
        }
        #endif

        #if os(macOS)
        Task { @MainActor in
            switch phase {
            case .active:
                // Start monitoring when app becomes active (macOS)
                DependencyContainer.shared.networkMonitor.startMonitoring()

                // Start periodic sync timer
                DependencyContainer.shared.syncCoordinator.startPeriodicSync()

                // Perform startup sync on first activation (macOS only)
                if !hasPerformedStartupSync {
                    hasPerformedStartupSync = true
                    Task.detached(priority: .utility) {
                        // Wait for network monitor to stabilize
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                        AppLogger.debug("💻 macOS: Starting startup sync...")
                        let syncCoordinator = await MainActor.run {
                            DependencyContainer.shared.syncCoordinator
                        }
                        await syncCoordinator.performStartupSync()
                        AppLogger.debug("💻 macOS: Startup sync complete")
                    }
                }
            case .background:
                // Stop monitoring when app goes to background (macOS)
                DependencyContainer.shared.networkMonitor.stopMonitoring()

                // Stop periodic sync timer
                DependencyContainer.shared.syncCoordinator.stopPeriodicSync()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        #endif
    }
}

// MARK: - Background Refresh Extension

extension Scene {
    /// Adds background refresh capability on iOS 16+, no-op on iOS 15 and other platforms
    func applyBackgroundRefresh() -> some Scene {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return self.backgroundTask(.appRefresh("com.videogorl.ensemble.refresh")) {
                await performBackgroundRefresh()
            }
        } else {
            return self
        }
        #else
        return self
        #endif
    }
}

#if os(iOS)
/// Perform background refresh - lightweight hub sync
@available(iOS 13.0, *)
private func performBackgroundRefresh() async {
    AppLogger.debug("🔄 Background refresh triggered")

    // Reschedule next refresh immediately for continuity
    BackgroundSyncScheduler.shared.scheduleAppRefresh()

    // Perform lightweight hub refresh
    let homeVM = await MainActor.run {
        DependencyContainer.shared.makeHomeViewModel()
    }

    await homeVM.refresh()

    AppLogger.debug("✅ Background refresh complete")
}
#endif
