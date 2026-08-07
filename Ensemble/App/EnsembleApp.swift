import EnsembleCore
import EnsemblePersistence
import EnsembleSiriShared
import EnsembleUI
import CoreSpotlight
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
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacDockMenuAppDelegate.self) private var macDockMenuDelegate
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
                    startPersistentLogSessionIfNeeded()
                    AppLogger.info("SIRI_APP: RootView.onAppear - app UI is visible")
                    UserJourneyLogger.log(context: "app", event: "rootVisible")
                    #if os(iOS)
                    WatchCompanionBridge.shared.configure(dependencies: DependencyContainer.shared)
                    #endif
                }
                .onOpenURL { url in
                    AppLogger.info("SIRI_APP: onOpenURL called with: \(url.absoluteString)")
                    handleIncomingURL(url)
                }
                .onContinueUserActivity(SystemMediaSpotlightRouter.activityType) { userActivity in
                    handleSpotlightActivity(userActivity)
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
                    if let url = userActivity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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

    private func handleIncomingURL(_ url: URL) {
        guard let permalink = EnsemblePermalink(url: url) else {
            _ = NavigationCoordinator.handleDeepLinkInActiveScene(
                url,
                fallback: DependencyContainer.shared.navigationCoordinator
            )
            return
        }

        Task { @MainActor in
            do {
                if let destination = try await DependencyContainer.shared.ensemblePermalinkResolver.resolve(permalink) {
                    _ = NavigationCoordinator.routeExternalSearchInActiveScene(to: destination)
                } else {
                    showPermalinkNotFound(permalink)
                }
            } catch {
                AppLogger.error("PERMALINK: resolution failed kind=\(permalink.kind.rawValue): \(error.localizedDescription)")
                showPermalinkNotFound(permalink)
            }
        }
    }

    @MainActor
    private func showPermalinkNotFound(_ permalink: EnsemblePermalink) {
        DependencyContainer.shared.toastCenter.show(
            ToastPayload(
                style: .warning,
                iconSystemName: "magnifyingglass",
                title: "Couldn't find \(permalink.title)",
                message: "Search your library for another version.",
                dedupeKey: "permalink-not-found-\(permalink.kind.rawValue)-\(permalink.title)"
            )
        )
        _ = NavigationCoordinator.routeExternalSearchInActiveScene(to: .view(.search))
    }

    private func startPersistentLogSessionIfNeeded() {
        guard !hasStartedLogSession else { return }
        hasStartedLogSession = true
        let handler = DependencyContainer.shared.persistentLogService.logHandler
        EnsembleUI.EnsembleLogger.fileLogHandler = handler
        AppLogger.fileLogHandler = handler
        DependencyContainer.shared.persistentLogService.startSession()
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        #if os(iOS)
        Task { @MainActor in
            AppLogger.debug("📱 Scene phase changed to \(String(describing: phase))")
            switch phase {
            case .active:
                UserJourneyLogger.log(context: "app", event: "scenePhase", details: ["phase": "active"])
                DependencyContainer.shared.playbackService.handleApplicationDidBecomeActive()
                if #available(iOS 16.0, *) {
                    await EnsembleFocusFilter.refreshCurrent()
                }
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(true)
                let isInitialActivation = !hasHandledInitialIOSActivePhase
                if isInitialActivation {
                    hasHandledInitialIOSActivePhase = true
                }

                // Start persistent log session on first activation.
                // Wire UI + App loggers here (Core/API/Persistence wired in DependencyContainer).
                startPersistentLogSessionIfNeeded()

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

                // Resume persisted download work before foreground sync and reconciliation.
                await DependencyContainer.shared.offlineDownloadService.handleAppWillEnterForeground()

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
                await DependencyContainer.shared.offlineDownloadService.resumeSidecarAnalysis()
                WatchCompanionBridge.shared.refresh()

            case .background:
                UserJourneyLogger.log(context: "app", event: "scenePhase", details: ["phase": "background"])
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(false)
                await DependencyContainer.shared.playbackService.handleApplicationDidEnterBackground()
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
                UserJourneyLogger.log(context: "app", event: "scenePhase", details: ["phase": "inactive"])
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(false)
                await DependencyContainer.shared.playbackService.handleApplicationDidEnterBackground()
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
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(true)
                // Start persistent log session on first activation (macOS)
                startPersistentLogSessionIfNeeded()

                // Start monitoring when app becomes active (macOS)
                DependencyContainer.shared.networkMonitor.startMonitoring()
                DependencyContainer.shared.webSocketCoordinator.start()
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

                        await dependencyContainer.accountManager.loadAccountsAsync()
                        await MainActor.run {
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
                        let (syncCoordinator, foregroundWorkScheduler) = await MainActor.run {
                            (
                                DependencyContainer.shared.syncCoordinator,
                                DependencyContainer.shared.foregroundWorkScheduler
                            )
                        }
                        await MainActor.run {
                            foregroundWorkScheduler.setStartupSyncInFlight(true)
                        }
                        defer {
                            Task { @MainActor in
                                foregroundWorkScheduler.setStartupSyncInFlight(false)
                            }
                        }
                        await syncCoordinator.performStartupSync()
                        AppLogger.debug("💻 macOS: Startup sync complete")
                        let dependencyContainer = await MainActor.run { DependencyContainer.shared }
                        await dependencyContainer.emitColdLaunchDiagnostics()
                    }
                }
            case .background:
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(false)
                // Flush log session to disk but keep the file handle open so
                // logs continue capturing during background activity.
                DependencyContainer.shared.persistentLogService.flushSession()

                // Stop monitoring when app goes to background (macOS)
                DependencyContainer.shared.networkMonitor.stopMonitoring()
                DependencyContainer.shared.webSocketCoordinator.stop()

                // Stop periodic sync timer
                DependencyContainer.shared.syncCoordinator.stopPeriodicSync()
            case .inactive:
                DependencyContainer.shared.foregroundWorkScheduler.setForegroundActive(false)
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

    private func handleSpotlightActivity(_ userActivity: NSUserActivity) {
        Task { @MainActor in
            _ = SystemMediaSpotlightRouter.route(userActivity)
        }
    }

    #if os(iOS)
    private func extractPayload(from intent: INPlayMediaIntent) -> SiriPlaybackRequestPayload? {
        let fields = intent.ensembleSiriPlaybackFields
        let shuffle = fields.playShuffled

        // Try to decode from identifier first
        if let identifier = fields.normalizedIdentifier,
           let data = Data(base64Encoded: identifier),
           var payload = try? SiriPlaybackActivityCodec.decode(from: data) {
            // Prefer the live forwarded intent when iOS preserves an explicit shuffle value.
            if let shuffle, payload.shuffle != shuffle {
                payload = payload.updatingShuffle(shuffle)
            }
            return payload
        }

        // Fallback to query
        guard let query = fields.queryText else {
            return nil
        }

        let sanitizedQuery = SiriPhraseNormalizer.normalized(query)
        guard !sanitizedQuery.isEmpty else {
            return nil
        }

        return SiriPlaybackRequestPayload(
            kind: fields.primaryKind(fallbackQuery: query),
            entityID: sanitizedQuery,
            displayName: sanitizedQuery,
            artistHint: fields.artistHint,
            shuffle: shuffle
        )
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

enum SystemMediaSpotlightRouter {
    static let activityType = CSSearchableItemActionType

    static func isSpotlightActivity(_ userActivity: NSUserActivity) -> Bool {
        userActivity.activityType == activityType
    }

    @MainActor
    @discardableResult
    static func route(_ userActivity: NSUserActivity) -> Bool {
        guard let destination = destination(from: userActivity) else {
            AppLogger.debug("SPOTLIGHT_APP: Could not route Spotlight activity")
            return false
        }

        let routedImmediately = NavigationCoordinator.routeExternalSearchInActiveScene(to: destination)
        AppLogger.info(
            "SPOTLIGHT_APP: \(routedImmediately ? "Routed" : "Queued") Spotlight media result to \(String(describing: destination))"
        )
        return true
    }

    static func destination(from userActivity: NSUserActivity) -> NavigationCoordinator.Destination? {
        guard isSpotlightActivity(userActivity),
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let sourceScopedIdentifier = SystemMediaSpotlightIdentity.sourceScopedIdentifier(
                fromSpotlightIdentifier: identifier
              ) else {
            return nil
        }

        return NavigationCoordinator.systemMediaDestination(
            fromSourceScopedIdentifier: sourceScopedIdentifier
        )
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

private final class MacDockPinAction: NSObject {
    let id: String
    let sourceKey: String?
    let type: PinnedItemType

    init(pin: PinnedItem) {
        id = pin.id
        sourceKey = pin.sourceCompositeKey
        type = pin.type
    }

    var destination: NavigationCoordinator.Destination {
        switch type {
        case .album:
            return .album(id: id, sourceKey: sourceKey)
        case .artist:
            return .artist(id: id, sourceKey: sourceKey)
        case .playlist:
            return .playlist(id: id, sourceKey: sourceKey)
        }
    }
}

@MainActor
private final class MacDockMenuAppDelegate: NSObject, NSApplicationDelegate {
    private enum RepeatActionTag {
        static let off = 0
        static let all = 1
        static let one = 2
    }

    private let maxPinnedItems = 8

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        buildDockMenu()
    }

    private func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        addPinnedItems(to: menu)
        addNowPlayingItems(to: menu)
        return menu
    }

    private func addPinnedItems(to menu: NSMenu) {
        let pins = Array(DependencyContainer.shared.pinManager.pinnedItems.prefix(maxPinnedItems))
        guard !pins.isEmpty else { return }

        for pin in pins {
            let item = NSMenuItem(
                title: pin.title,
                action: #selector(openPinnedItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = MacDockPinAction(pin: pin)
            item.toolTip = "\(pin.type.displayName): \(pin.title)"
            item.image = fallbackImage(for: pin.type)
            menu.addItem(item)
            updateArtwork(for: pin, menuItem: item)
        }

        menu.addItem(.separator())
    }

    private func addNowPlayingItems(to menu: NSMenu) {
        let dependencies = DependencyContainer.shared
        let playbackService = dependencies.playbackService
        let currentTrack = playbackService.currentTrack
        let hasCurrentTrack = currentTrack != nil

        let nowPlayingTitle = currentTrack.map(Self.nowPlayingTitle(for:)) ?? "Nothing Playing"
        let nowPlayingItem = NSMenuItem(title: nowPlayingTitle, action: nil, keyEquivalent: "")
        nowPlayingItem.isEnabled = false
        nowPlayingItem.image = symbolImage(named: "music.note")
        menu.addItem(nowPlayingItem)

        let isFavorited = currentTrack.map { track in
            if let viewModel = dependencies.activeNowPlayingViewModel {
                return viewModel.isTrackFavorited(track)
            }
            return track.rating >= 8
        } ?? false

        let favoriteItem = NSMenuItem(
            title: isFavorited ? "Unfavorite" : "Favorite",
            action: #selector(toggleFavorite(_:)),
            keyEquivalent: ""
        )
        favoriteItem.target = self
        favoriteItem.isEnabled = hasCurrentTrack
        favoriteItem.image = symbolImage(named: isFavorited ? "heart.fill" : "heart")
        menu.addItem(favoriteItem)

        menu.addItem(.separator())

        let shuffleItem = NSMenuItem(
            title: playbackService.isShuffleEnabled ? "Shuffle On" : "Shuffle Off",
            action: #selector(toggleShuffle(_:)),
            keyEquivalent: ""
        )
        shuffleItem.target = self
        shuffleItem.isEnabled = hasCurrentTrack
        shuffleItem.state = playbackService.isShuffleEnabled ? .on : .off
        shuffleItem.image = symbolImage(named: "shuffle")
        menu.addItem(shuffleItem)

        addRepeatItem(title: "Repeat Off", mode: .off, tag: RepeatActionTag.off, to: menu)
        addRepeatItem(title: "Repeat All", mode: .all, tag: RepeatActionTag.all, to: menu)
        addRepeatItem(title: "Repeat One", mode: .one, tag: RepeatActionTag.one, to: menu)

        let autoplayItem = NSMenuItem(
            title: playbackService.isAutoplayEnabled ? "Autoplay On" : "Autoplay Off",
            action: #selector(toggleAutoplay(_:)),
            keyEquivalent: ""
        )
        autoplayItem.target = self
        autoplayItem.isEnabled = hasCurrentTrack
        autoplayItem.state = playbackService.isAutoplayEnabled ? .on : .off
        autoplayItem.image = symbolImage(named: "infinity")
        menu.addItem(autoplayItem)

        menu.addItem(.separator())

        let playbackTitle = playbackService.playbackState == .playing ? "Pause" : "Play"
        let playPauseItem = NSMenuItem(
            title: playbackTitle,
            action: #selector(togglePlayPause(_:)),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        playPauseItem.isEnabled = hasCurrentTrack
        playPauseItem.image = symbolImage(named: playbackService.playbackState == .playing ? "pause.fill" : "play.fill")
        menu.addItem(playPauseItem)

        let previousItem = NSMenuItem(
            title: "Previous Track",
            action: #selector(previousTrack(_:)),
            keyEquivalent: ""
        )
        previousItem.target = self
        previousItem.isEnabled = hasCurrentTrack
        previousItem.image = symbolImage(named: "backward.end.fill")
        menu.addItem(previousItem)

        let nextItem = NSMenuItem(
            title: "Next Track",
            action: #selector(nextTrack(_:)),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = canSkipForward()
        nextItem.image = symbolImage(named: "forward.end.fill")
        menu.addItem(nextItem)
    }

    private func addRepeatItem(title: String, mode: RepeatMode, tag: Int, to menu: NSMenu) {
        let playbackService = DependencyContainer.shared.playbackService
        let item = NSMenuItem(
            title: title,
            action: #selector(setRepeatMode(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = tag
        item.state = playbackService.repeatMode == mode ? .on : .off
        item.isEnabled = playbackService.currentTrack != nil
        item.image = symbolImage(named: mode == .one ? "repeat.1" : "repeat")
        menu.addItem(item)
    }

    @objc private func openPinnedItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MacDockPinAction else { return }
        NavigationCoordinator.routeExternalSearchInActiveScene(to: action.destination)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleFavorite(_: NSMenuItem) {
        let dependencies = DependencyContainer.shared
        guard let track = dependencies.playbackService.currentTrack else { return }
        let viewModel = dependencies.activeNowPlayingViewModel ?? dependencies.makeNowPlayingViewModel()

        Task { @MainActor in
            await viewModel.toggleTrackFavorite(track)
        }
    }

    @objc private func toggleShuffle(_: NSMenuItem) {
        DependencyContainer.shared.playbackService.toggleShuffle()
    }

    @objc private func setRepeatMode(_ sender: NSMenuItem) {
        let targetMode: RepeatMode
        switch sender.tag {
        case RepeatActionTag.all:
            targetMode = .all
        case RepeatActionTag.one:
            targetMode = .one
        default:
            targetMode = .off
        }

        let playbackService = DependencyContainer.shared.playbackService
        var attempts = 0
        while playbackService.repeatMode != targetMode,
              attempts < RepeatMode.allCases.count {
            playbackService.cycleRepeatMode()
            attempts += 1
        }
    }

    @objc private func toggleAutoplay(_: NSMenuItem) {
        DependencyContainer.shared.playbackService.toggleAutoplay()
    }

    @objc private func togglePlayPause(_: NSMenuItem) {
        let dependencies = DependencyContainer.shared
        if let viewModel = dependencies.activeNowPlayingViewModel {
            viewModel.togglePlayPause()
            return
        }

        let service = dependencies.playbackService
        switch service.playbackState {
        case .playing:
            service.pause()
        case .paused:
            service.resume()
        case .failed:
            Task { @MainActor in
                await service.retryCurrentTrack()
            }
        default:
            service.resume()
        }
    }

    @objc private func previousTrack(_: NSMenuItem) {
        DependencyContainer.shared.playbackService.previous()
    }

    @objc private func nextTrack(_: NSMenuItem) {
        DependencyContainer.shared.playbackService.next()
    }

    private func updateArtwork(for pin: PinnedItem, menuItem: NSMenuItem) {
        Task {
            guard let artworkImage = await artworkImage(for: pin) else { return }
            await MainActor.run {
                menuItem.image = artworkImage
            }
        }
    }

    private func artworkImage(for pin: PinnedItem) async -> NSImage? {
        let dependencies = DependencyContainer.shared
        let descriptor: ArtworkDescriptor?

        switch pin.type {
        case .album:
            if let cdAlbum = try? await dependencies.libraryRepository.fetchAlbum(
                ratingKey: pin.id,
                sourceCompositeKey: pin.sourceCompositeKey
            ) {
                let album = Album(from: cdAlbum)
                descriptor = ArtworkDescriptor(
                    path: album.thumbPath,
                    ratingKey: album.id,
                    fallbackPath: nil,
                    fallbackRatingKey: nil
                )
            } else {
                descriptor = nil
            }
        case .artist:
            if let cdArtist = try? await dependencies.libraryRepository.fetchArtist(
                ratingKey: pin.id,
                sourceCompositeKey: pin.sourceCompositeKey
            ) {
                let artist = Artist(from: cdArtist)
                descriptor = ArtworkDescriptor(
                    path: artist.thumbPath,
                    ratingKey: artist.id,
                    fallbackPath: artist.fallbackThumbPath,
                    fallbackRatingKey: artist.fallbackRatingKey
                )
            } else {
                descriptor = nil
            }
        case .playlist:
            if let cdPlaylist = try? await dependencies.playlistRepository.fetchPlaylist(
                ratingKey: pin.id,
                sourceCompositeKey: pin.sourceCompositeKey
            ) {
                let playlist = Playlist(from: cdPlaylist)
                descriptor = ArtworkDescriptor(
                    path: playlist.compositePath,
                    ratingKey: playlist.id,
                    fallbackPath: nil,
                    fallbackRatingKey: nil
                )
            } else {
                descriptor = nil
            }
        }

        guard let descriptor,
              let url = await dependencies.artworkLoader.artworkURLAsync(
                  for: descriptor.path,
                  sourceKey: pin.sourceCompositeKey,
                  ratingKey: descriptor.ratingKey,
                  fallbackPath: descriptor.fallbackPath,
                  fallbackRatingKey: descriptor.fallbackRatingKey,
                  size: 64
              ),
              url.isFileURL,
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func canSkipForward() -> Bool {
        let playbackService = DependencyContainer.shared.playbackService
        guard playbackService.currentTrack != nil else { return false }
        if playbackService.repeatMode == .all, playbackService.queue.count > 1 {
            return true
        }
        return playbackService.currentQueueIndex + 1 < playbackService.queue.count
    }

    private static func nowPlayingTitle(for track: Track) -> String {
        let artist = track.artistName ?? track.albumArtistName ?? "Unknown Artist"
        return "\(artist) - \(track.title)"
    }

    private func fallbackImage(for type: PinnedItemType) -> NSImage? {
        switch type {
        case .album:
            return symbolImage(named: "square.stack")
        case .artist:
            return symbolImage(named: "music.mic")
        case .playlist:
            return symbolImage(named: "music.note.list")
        }
    }

    private func symbolImage(named name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private struct ArtworkDescriptor {
        let path: String?
        let ratingKey: String?
        let fallbackPath: String?
        let fallbackRatingKey: String?
    }
}

private extension PinnedItemType {
    var displayName: String {
        switch self {
        case .album:
            return "Album"
        case .artist:
            return "Artist"
        case .playlist:
            return "Playlist"
        }
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
