import EnsembleCore
import EnsembleUI
import Intents
import os
import OSLog
import SwiftUI
#if os(macOS)
import AppKit
#endif
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
    #if os(macOS)
    @State private var hasStartedPlaybackRestore = false
    @State private var hasCompletedPlaybackRestore = false
    #endif
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
                .onContinueUserActivity(SiriAffinityActivityCodec.activityType) { userActivity in
                    handleSiriAffinityActivity(userActivity)
                }
                .onContinueUserActivity(SiriAddToPlaylistActivityCodec.activityType) { userActivity in
                    handleSiriAddToPlaylistActivity(userActivity)
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
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
        .applyBackgroundRefresh()
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
        .commands {
            // Settings shortcut (⌘,) — macOS app menu + iPadOS keyboard shortcut overlay
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    DependencyContainer.shared.navigationCoordinator.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            #if os(macOS)
            CommandMenu("Playback") {
                Button("Play/Pause") {
                    MacPlaybackShortcut.togglePlaybackIfAllowed()
                }
                .keyboardShortcut(.space, modifiers: [])
            }
            #endif
        }
        #if os(macOS)
        if #available(macOS 13.0, *) {
            Window("Settings", id: NavigationCoordinator.AuxiliaryPresentation.settings.windowID) {
                SettingsPresentationContainer()
                    .environment(\.dependencies, DependencyContainer.shared)
                    .frame(minWidth: 720, minHeight: 560)
            }
            Window("Downloads", id: NavigationCoordinator.AuxiliaryPresentation.downloads.windowID) {
                DownloadsPresentationContainer()
                    .environment(\.dependencies, DependencyContainer.shared)
                    .frame(minWidth: 900, minHeight: 640)
            }
        }
        #endif
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        #if os(iOS)
        Task { @MainActor in
            switch phase {
            case .active:
                // Schedule background refresh on first activation (iOS 16+)
                if #available(iOS 16.0, *) {
                    if !hasScheduledBackgroundRefresh {
                        BackgroundSyncScheduler.shared.scheduleAppRefresh()
                        hasScheduledBackgroundRefresh = true
                    }
                }

                // Resume network monitoring and WebSocket connections
                DependencyContainer.shared.networkMonitor.startMonitoring()
                DependencyContainer.shared.webSocketCoordinator.start()

                // Route foreground refresh through SyncCoordinator to coalesce
                // with network state transitions and cooldown/staleness guards.
                await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()

                // Adjust periodic sync timers based on WebSocket availability.
                let hasWebSocket = !DependencyContainer.shared.webSocketCoordinator.connectedServerKeys.isEmpty
                DependencyContainer.shared.syncCoordinator.adjustTimersForWebSocket(hasActiveWebSocket: hasWebSocket)

                // Drain any pending offline mutations now that connectivity may have resumed.
                await DependencyContainer.shared.mutationCoordinator.drainQueue()

                // Update Siri media user context in case library changed while backgrounded
                await DependencyContainer.shared.siriMediaUserContextManager.updateMediaUserContext()

            case .background:
                // Stop network monitoring and WebSocket connections to save battery.
                // Without this, WebSocket reconnect loops burn ~30% network while idle.
                DependencyContainer.shared.networkMonitor.stopMonitoring()
                DependencyContainer.shared.webSocketCoordinator.stop()
                DependencyContainer.shared.syncCoordinator.stopPeriodicSync()

            case .inactive:
                break
            @unknown default:
                break
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

                // macOS does not go through UIApplication/AppDelegate startup,
                // so we need to mirror the iPhone launch sequence here once:
                // load accounts/providers, run health checks, then restore the
                // persisted queue/current track before the first startup sync.
                if !hasStartedPlaybackRestore {
                    hasStartedPlaybackRestore = true

                    Task.detached(priority: .utility) {
                        defer {
                            Task { @MainActor in
                                hasCompletedPlaybackRestore = true
                            }
                        }

                        let dependencyContainer = await MainActor.run { DependencyContainer.shared }

                        await MainActor.run {
                            dependencyContainer.accountManager.loadAccounts()
                            dependencyContainer.serverHealthChecker.prepopulateUnknownStates()
                            dependencyContainer.syncCoordinator.refreshProviders()
                        }

                        let networkMonitor = await MainActor.run { dependencyContainer.networkMonitor }
                        if await MainActor.run(body: { networkMonitor.networkState == .unknown }) {
                            for _ in 0..<10 {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                if await MainActor.run(body: { networkMonitor.networkState != .unknown }) {
                                    break
                                }
                            }
                        }

                        AppLogger.debug("💻 macOS: Running startup health checks before playback restore...")
                        let syncCoordinator = await MainActor.run { dependencyContainer.syncCoordinator }
                        await syncCoordinator.performStartupHealthChecks()

                        AppLogger.debug("💻 macOS: Restoring persisted playback state...")
                        let playbackService = await MainActor.run { dependencyContainer.playbackService }
                        await playbackService.restorePlaybackState()
                        AppLogger.debug("💻 macOS: Playback state restoration complete")
                    }
                }

                // Perform startup sync on first activation (macOS only)
                if !hasPerformedStartupSync {
                    hasPerformedStartupSync = true
                    Task.detached(priority: .utility) {
                        // Let the one-time playback restoration run first so the
                        // queue/current track hydrate before cold-start sync churn.
                        while await MainActor.run(body: { !hasCompletedPlaybackRestore }) {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)

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
        let shuffle = intent.playShuffled

        // Try to decode from identifier first
        if let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier,
           let data = Data(base64Encoded: identifier),
           var payload = try? SiriPlaybackActivityCodec.decode(from: data) {
            // Override shuffle from live intent if not already set in payload
            if payload.shuffle == nil, let shuffle {
                payload = SiriPlaybackRequestPayload(
                    kind: payload.kind,
                    entityID: payload.entityID,
                    sourceCompositeKey: payload.sourceCompositeKey,
                    displayName: payload.displayName,
                    artistHint: payload.artistHint,
                    shuffle: shuffle
                )
            }
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

        return SiriPlaybackRequestPayload(kind: kind, entityID: query, displayName: query, shuffle: shuffle)
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

    private func handleSiriAffinityActivity(_ userActivity: NSUserActivity) {
        os_log(.info, "SIRI_APP: handleSiriAffinityActivity ENTRY - type=%{public}@", userActivity.activityType)
        Task { @MainActor in
            await DependencyContainer.shared.siriAffinityCoordinator.handle(userActivity: userActivity)
        }
    }

    private func handleSiriAddToPlaylistActivity(_ userActivity: NSUserActivity) {
        os_log(.info, "SIRI_APP: handleSiriAddToPlaylistActivity ENTRY - type=%{public}@", userActivity.activityType)
        Task { @MainActor in
            await DependencyContainer.shared.siriAddToPlaylistCoordinator.handle(userActivity: userActivity)
        }
    }
}

#if os(macOS)
private enum MacPlaybackShortcut {
    static func togglePlaybackIfAllowed() {
        guard !isTextInputActive else { return }

        let service = DependencyContainer.shared.playbackService
        switch service.playbackState {
        case .playing:
            service.pause()
        case .paused:
            service.resume()
        default:
            break
        }
    }

    private static var isTextInputActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }

        if responder is NSTextView {
            return true
        }

        if let control = responder as? NSControl {
            return control.currentEditor() != nil
        }

        return false
    }
}
#endif

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

    // Reschedule next refresh immediately for continuity (must be on main thread)
    await MainActor.run {
        BackgroundSyncScheduler.shared.scheduleAppRefresh()
    }

    // Incremental library + playlist sync so the app is fresh before the user opens it.
    // This is cheap — only fetches items added/updated since the last sync timestamp.
    let syncCoordinator = await MainActor.run {
        DependencyContainer.shared.syncCoordinator
    }
    await syncCoordinator.syncAllIncremental()

    // Hub refresh for the home screen
    let homeVM = await MainActor.run {
        DependencyContainer.shared.makeHomeViewModel()
    }
    await homeVM.refresh()

    AppLogger.debug("✅ Background refresh complete")
}
#endif
