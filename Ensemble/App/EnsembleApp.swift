import EnsembleCore
import EnsembleUI
import Intents
import os
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
                .onAppear {
                    os_log(.info, "SIRI_APP: RootView.onAppear - app UI is visible")
                }
                .onOpenURL { url in
                    os_log(.info, "SIRI_APP: onOpenURL called with: %{public}@", url.absoluteString)
                    _ = DependencyContainer.shared.navigationCoordinator.handleDeepLink(url)
                }
                .onContinueUserActivity(SiriPlaybackActivityCodec.activityType) { userActivity in
                    handleSiriPlaybackActivity(userActivity)
                }
                .onContinueUserActivity("INPlayMediaIntent") { userActivity in
                    os_log(.info, "SIRI_APP: Received INPlayMediaIntent activity via SwiftUI")
                    handleGenericSiriActivity(userActivity)
                }
                .onContinueUserActivity("com.apple.intents.PlayMediaIntent") { userActivity in
                    os_log(.info, "SIRI_APP: Received com.apple.intents.PlayMediaIntent activity via SwiftUI")
                    handleGenericSiriActivity(userActivity)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    os_log(.info, "SIRI_APP: Received web browsing activity: %{public}@", userActivity.webpageURL?.absoluteString ?? "nil")
                }
                .userActivity("com.videogorl.ensemble.active") { activity in
                    // This registers a user activity so we can track if the app becomes active
                    activity.title = "Ensemble Active"
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
                await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()

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

    private func handleGenericSiriActivity(_ userActivity: NSUserActivity) {
        os_log(.info, "SIRI_APP: handleGenericSiriActivity - type=%{public}@", userActivity.activityType)

        // First try our custom payload
        if let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) {
            os_log(.info, "SIRI_APP: Found custom payload in generic activity")
            #if os(iOS)
            executeSiriPlaybackInBackground(payload: payload, origin: "genericActivityCustomPayload")
            #endif
            return
        }

        #if os(iOS)
        // Try to extract from INInteraction
        if let interaction = userActivity.interaction,
           let playMediaIntent = interaction.intent as? INPlayMediaIntent {
            os_log(.info, "SIRI_APP: Found INPlayMediaIntent in interaction")
            if let payload = extractPayload(from: playMediaIntent) {
                executeSiriPlaybackInBackground(payload: payload, origin: "genericActivityInteraction")
                return
            }
        }
        #endif

        os_log(.error, "SIRI_APP: Could not extract playable payload from generic activity")
    }

    #if os(iOS)
    private func extractPayload(from intent: INPlayMediaIntent) -> SiriPlaybackRequestPayload? {
        // Try to decode from identifier first
        if let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier,
           let data = Data(base64Encoded: identifier),
           let payload = try? SiriPlaybackActivityCodec.decode(from: data) {
            return payload
        }

        // Fallback to query
        guard let query = intent.mediaItems?.first?.title
                ?? intent.mediaContainer?.title
                ?? intent.mediaSearch?.mediaName,
              !query.isEmpty else {
            return nil
        }

        let mediaType = intent.mediaSearch?.mediaType
            ?? intent.mediaContainer?.type
            ?? intent.mediaItems?.first?.type
            ?? .unknown

        let kind: SiriMediaKind
        switch mediaType {
        case .song: kind = .track
        case .album: kind = .album
        case .artist: kind = .artist
        case .playlist: kind = .playlist
        default: kind = .track
        }

        return SiriPlaybackRequestPayload(kind: kind, entityID: query, displayName: query)
    }
    #endif

    private func handleSiriPlaybackActivity(_ userActivity: NSUserActivity) {
        os_log(.info, "SIRI_APP: EnsembleApp.handleSiriPlaybackActivity ENTRY - type=%{public}@", userActivity.activityType)
        os_log(.info, "SIRI_APP: userInfo keys: %{public}@", String(describing: userActivity.userInfo?.keys.map { "\($0)" } ?? []))

        guard let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) else {
            os_log(.error, "SIRI_APP: EnsembleApp could not decode Siri payload from userActivity")
            // Try to log the raw userInfo for debugging
            if let userInfo = userActivity.userInfo {
                for (key, value) in userInfo {
                    os_log(.info, "SIRI_APP: userInfo[%{public}@] = %{public}@", "\(key)", "\(type(of: value))")
                }
            }
            return
        }

        os_log(
            .info,
            "SIRI_APP: EnsembleApp forwarding payload kind=%{public}@ entity=%{public}@",
            payload.kind.rawValue,
            payload.entityID
        )
        #if os(iOS)
        executeSiriPlaybackInBackground(payload: payload, origin: "swiftUIContinue")
        #else
        Task { @MainActor in
            try? await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
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
