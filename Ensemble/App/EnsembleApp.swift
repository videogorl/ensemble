import EnsembleCore
import EnsembleUI
import Foundation
import Intents
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import BackgroundTasks
#endif

@main
struct EnsembleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @Environment(\.scenePhase) private var scenePhase
    @FocusedValue(\.ensembleRefreshAction) private var focusedRefreshAction
    @State private var hasPerformedStartupSync = false
    @State private var hasStartedLogSession = false
    @State private var hasHandledInitialIOSActivePhase = false
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
                    AppLogger.info("SIRI_APP: RootView.onAppear - app UI is visible")
                }
                .onOpenURL { url in
                    AppLogger.info("SIRI_APP: onOpenURL called with: \(url.absoluteString)")
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
                    AppLogger.info("SIRI_APP: Received INPlayMediaIntent activity via SwiftUI")
                    handleGenericSiriActivity(userActivity)
                }
                .onContinueUserActivity("com.apple.intents.PlayMediaIntent") { userActivity in
                    AppLogger.info("SIRI_APP: Received com.apple.intents.PlayMediaIntent activity via SwiftUI")
                    handleGenericSiriActivity(userActivity)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    AppLogger.info("SIRI_APP: Received web browsing activity: \(userActivity.webpageURL?.absoluteString ?? "nil")")
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
        .commands {
            // Settings shortcut (⌘,) — macOS app menu + iPadOS keyboard shortcut overlay
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    guard EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesSettingsShortcut else { return }
                    NavigationCoordinator.openProfileFromActiveScene(
                        fallback: DependencyContainer.shared.navigationCoordinator
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesSettingsShortcut)
            }

            #if os(iOS)
            CommandGroup(after: .toolbar) {
                Button(focusedRefreshAction?.title ?? "Refresh") {
                    guard EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesRefreshCommand,
                          let action = focusedRefreshAction else { return }
                    Task { @MainActor in
                        await action.perform()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(focusedRefreshAction == nil || !EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesRefreshCommand)
            }
            #endif

            #if os(macOS)
            CommandGroup(after: .sidebar) {
                Button(focusedRefreshAction?.title ?? "Refresh") {
                    guard EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesRefreshCommand,
                          let action = focusedRefreshAction else { return }
                    Task { @MainActor in
                        await action.perform()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(focusedRefreshAction == nil || !EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesRefreshCommand)
            }

            CommandMenu("Playback") {
                Button("Play/Pause") {
                    if EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesPlaybackCommandMenu {
                        MacPlaybackShortcut.togglePlaybackIfAllowed()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!EnsemblePlatformFeaturePolicy.currentCommandPolicy.providesPlaybackCommandMenu)
            }
            #endif
        }
        #if os(macOS)
        if #available(macOS 13.0, *) {
            Window("Profile", id: NavigationCoordinator.AuxiliaryPresentation.profile.windowID) {
                ProfilePresentationContainer()
                    .environment(\.dependencies, DependencyContainer.shared)
                    .environmentObject(DependencyContainer.shared.navigationCoordinator)
                    .ensembleAuxiliaryWindowFrame(.profile)
            }
            .defaultSize(
                width: EnsembleScaffold.AuxiliaryWindow.Configuration.profile.idealWidth,
                height: EnsembleScaffold.AuxiliaryWindow.Configuration.profile.idealHeight
            )
            .windowResizability(.contentSize)

            Window("Downloads", id: NavigationCoordinator.AuxiliaryPresentation.downloads.windowID) {
                DownloadsPresentationContainer()
                    .environment(\.dependencies, DependencyContainer.shared)
                    .environmentObject(DependencyContainer.shared.navigationCoordinator)
                    .ensembleAuxiliaryWindowFrame(.downloads)
            }
            .defaultSize(
                width: EnsembleScaffold.AuxiliaryWindow.Configuration.downloads.idealWidth,
                height: EnsembleScaffold.AuxiliaryWindow.Configuration.downloads.idealHeight
            )
            .windowResizability(.contentSize)
        }
        #endif
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        #if os(iOS)
        Task { @MainActor in
            AppLogger.debug("📱 Scene phase changed to \(String(describing: phase))")
            switch phase {
            case .active:
                let isInitialActivation = !hasHandledInitialIOSActivePhase
                if isInitialActivation {
                    hasHandledInitialIOSActivePhase = true
                }

                // Start persistent log session on first activation.
                // Wire UI + App loggers here (Core/API/Persistence wired in DependencyContainer).
                if !hasStartedLogSession {
                    hasStartedLogSession = true
                    let handler = DependencyContainer.shared.persistentLogService.logHandler
                    EnsembleUI.EnsembleLogger.fileLogHandler = handler
                    AppLogger.fileLogHandler = handler
                    DependencyContainer.shared.persistentLogService.startSession()
                }

                // Schedule background refresh on first activation (iOS 16+)
                if #available(iOS 16.0, *) {
                    if !hasScheduledBackgroundRefresh {
                        BackgroundSyncScheduler.shared.scheduleAppRefresh()
                        hasScheduledBackgroundRefresh = true
                    }
                }

                if isInitialActivation {
                    // Cold-launch startup already started network monitoring and queued
                    // WebSocket startup behind early health checks in AppDelegate.
                    // Skipping the duplicate start here keeps launch sequencing owned by
                    // one path instead of racing the scene activation hook.
                    AppLogger.debug("📱 EnsembleApp: Initial active phase — launch pipeline owns monitor/WebSocket startup")
                } else {
                    // Resume network monitoring and WebSocket connections
                    DependencyContainer.shared.networkMonitor.startMonitoring()
                    DependencyContainer.shared.webSocketCoordinator.start()
                }

                if isInitialActivation {
                    AppLogger.debug("📱 EnsembleApp: Initial active phase — skipping foreground freshness after cold-launch pipeline")
                } else {
                    // Route foreground freshness through one coordinator so iOS 15
                    // foreground refresh and iOS background refresh share the same work.
                    await DependencyContainer.shared.backgroundRefreshCoordinator.performForegroundFreshnessRefresh()
                    await DependencyContainer.shared.reconcileSyncOnForeground()
                }

                // Drain any pending offline mutations now that connectivity may have resumed.
                await DependencyContainer.shared.mutationCoordinator.drainQueue()

                // Restart display timer if music was actively playing when backgrounded.
                // Also resumes sidecar analysis so pending FFT jobs process in foreground.
                DependencyContainer.shared.audioAnalyzer.exitBackground()
                await DependencyContainer.shared.offlineDownloadService.handleAppWillEnterForeground()
                await DependencyContainer.shared.offlineDownloadService.resumeSidecarAnalysis()

            case .background:
                // Flush log session to disk but keep the file handle open so
                // logs continue capturing during background audio playback.
                DependencyContainer.shared.persistentLogService.flushSession()
                DependencyContainer.shared.persistPlaybackStateSnapshot()

                // Stop the frequency display timer to prevent it from burning main thread
                // CPU during background audio playback (~3ms/sec saved on main thread).
                // Uses enterBackground() rather than pauseUpdates() so the music-pause
                // flag is preserved — exitBackground() on foreground restarts correctly.
                DependencyContainer.shared.audioAnalyzer.enterBackground()

                // Suspend sidecar FFT analysis. Without this, a 75-track batch download
                // completing in background can sustain ~95% CPU (FFT at background priority
                // outlasts iOS's background CPU budget), triggering a SIGKILL after ~2min.
                await DependencyContainer.shared.offlineDownloadService.suspendSidecarAnalysis()
                await DependencyContainer.shared.offlineDownloadService.handleAppDidEnterBackground()

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
                // Start persistent log session on first activation (macOS)
                if !hasStartedLogSession {
                    hasStartedLogSession = true
                    let handler = DependencyContainer.shared.persistentLogService.logHandler
                    EnsembleUI.EnsembleLogger.fileLogHandler = handler
                    AppLogger.fileLogHandler = handler
                    DependencyContainer.shared.persistentLogService.startSession()
                }

                // Start monitoring when app becomes active (macOS)
                DependencyContainer.shared.networkMonitor.startMonitoring()
                DependencyContainer.shared.offlineBackgroundExecutionCoordinator.register()
                await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()
                await DependencyContainer.shared.reconcileSyncOnForeground()

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
                        let dependencyContainer = await MainActor.run { DependencyContainer.shared }
                        await dependencyContainer.emitColdLaunchDiagnostics()
                    }
                }
            case .background:
                // Flush log session to disk but keep the file handle open so
                // logs continue capturing during background activity.
                DependencyContainer.shared.persistentLogService.flushSession()

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
        AppLogger.info("SIRI_APP: handleGenericSiriActivity - type=\(userActivity.activityType)")

        // First try our custom payload
        if let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) {
            AppLogger.info("SIRI_APP: Found custom payload in generic activity")
            #if os(iOS)
            executeSiriPlaybackInBackground(payload: payload, origin: "genericActivityCustomPayload")
            #endif
            return
        }

        #if os(iOS)
        // Try to extract from INInteraction
        if let interaction = userActivity.interaction,
           let playMediaIntent = interaction.intent as? INPlayMediaIntent {
            AppLogger.info("SIRI_APP: Found INPlayMediaIntent in interaction")
            if let payload = extractPayload(from: playMediaIntent) {
                executeSiriPlaybackInBackground(payload: payload, origin: "genericActivityInteraction")
                return
            }
        }
        #endif

        AppLogger.error("SIRI_APP: Could not extract playable payload from generic activity")
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
        AppLogger.info("SIRI_APP: EnsembleApp.handleSiriPlaybackActivity ENTRY - type=\(userActivity.activityType)")
        AppLogger.info("SIRI_APP: userInfo keys: \(String(describing: userActivity.userInfo?.keys.map { "\($0)" } ?? []))")

        guard let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) else {
            AppLogger.error("SIRI_APP: EnsembleApp could not decode Siri payload from userActivity")
            // Try to log the raw userInfo for debugging
            if let userInfo = userActivity.userInfo {
                for (key, value) in userInfo {
                    AppLogger.info("SIRI_APP: userInfo[\(key)] = \(type(of: value))")
                }
            }
            return
        }

        AppLogger.info("SIRI_APP: EnsembleApp forwarding payload kind=\(payload.kind.rawValue) entity=\(payload.entityID)")
        #if os(iOS)
        executeSiriPlaybackInBackground(payload: payload, origin: "swiftUIContinue")
        #else
        Task { @MainActor in
            try? await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
        }
        #endif
    }

    private func handleSiriAffinityActivity(_ userActivity: NSUserActivity) {
        AppLogger.info("SIRI_APP: handleSiriAffinityActivity ENTRY - type=\(userActivity.activityType)")
        Task { @MainActor in
            await DependencyContainer.shared.siriAffinityCoordinator.handle(userActivity: userActivity)
        }
    }

    private func handleSiriAddToPlaylistActivity(_ userActivity: NSUserActivity) {
        AppLogger.info("SIRI_APP: handleSiriAddToPlaylistActivity ENTRY - type=\(userActivity.activityType)")
        Task { @MainActor in
            await DependencyContainer.shared.siriAddToPlaylistCoordinator.handle(userActivity: userActivity)
        }
    }
}

#if os(macOS)
private extension View {
    func ensembleAuxiliaryWindowFrame(
        _ configuration: EnsembleScaffold.AuxiliaryWindow.Configuration
    ) -> some View {
        frame(
            minWidth: configuration.minWidth,
            idealWidth: configuration.idealWidth,
            maxWidth: configuration.maxWidth,
            minHeight: configuration.minHeight,
            idealHeight: configuration.idealHeight
        )
    }
}
#endif

// MARK: - Playback Shortcut

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

    let refreshCoordinator = await MainActor.run {
        DependencyContainer.shared.backgroundRefreshCoordinator
    }
    await refreshCoordinator.performAppRefresh()

    AppLogger.debug("✅ Background refresh complete")
}
#endif
