#if os(iOS)
import AVFoundation
import AppIntents
import GameController
import Intents
import os
import UIKit
import EnsembleCore

class AppDelegate: NSObject, UIApplicationDelegate {
    private var coverFlowRotationSupportEnabled = false
    private static let siriAppNameSuffixes = [" ensemble music", " ensemble"]
    private static let siriTrailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    private static let siriLeadingMediaTypePrefixes = [
        "the playlist ",
        "playlist ",
        "the album ",
        "album ",
        "the artist ",
        "artist ",
        "the song ",
        "song ",
        "the track ",
        "track "
    ]
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let pendingPlaybackFilename = "siri-pending-playback.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingPlayback"

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
        configureSiriAuthorization()

        // Install space-bar → play/pause hardware keyboard shortcut
        SpaceBarPlaybackShortcut.install()

        // Register for Darwin notification from Siri extension
        registerForSiriPendingPlaybackNotification()

        // Register optional iOS 26+ continued processing handler for offline downloads.
        DependencyContainer.shared.offlineBackgroundExecutionCoordinator.register()

        // Load accounts synchronously before any Siri/playback code runs.
        // This is critical for cold launches from Siri where the coordinator
        // needs accounts loaded before RootView.task has a chance to run.
        DependencyContainer.shared.accountManager.loadAccounts()
        
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

        // Ensure Siri media index exists even before the next sync/account-change notification.
        Task { @MainActor in
            let indexStore = DependencyContainer.shared.siriMediaIndexStore
            if indexStore.loadIndex(maxAge: 3600) == nil {
                let rebuilt = await indexStore.rebuildIndex()
                #if DEBUG
                AppLogger.debug("📱 AppDelegate: Siri media index rebuilt at launch (items: \(rebuilt?.items.count ?? 0))")
                #endif
            }
            if #available(iOS 16.0, *) {
                EnsembleAppShortcutsProvider.updateAppShortcutParameters()
                #if DEBUG
                AppLogger.debug("SIRI_SHORTCUT: refreshed App Shortcuts parameter metadata")
                #endif
            }
            
            // Update Siri media user context with current library statistics
            await DependencyContainer.shared.siriMediaUserContextManager.updateMediaUserContext()
        }
        
        // Start WebSocket connections after accounts are loaded and network is starting.
        // This enables real-time push notifications from Plex servers.
        Task { @MainActor in
            DependencyContainer.shared.webSocketCoordinator.start()
        }

        // Perform startup sync (non-blocking, runs in background)
        Task.detached(priority: .utility) {
            // Wait longer to ensure any Siri playback has a chance to start first.
            // Resource contention during background launch is a common cause of
            // audio session interruptions.
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            // If Siri playback was recently triggered, wait even longer.
            // Using a simple file-based check as a global flag since some functions are top-level.
            let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.videogorl.ensemble")
            let pendingFile = appGroup?.appendingPathComponent("siri-pending-playback.json")
            let hasPendingSiri = pendingFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            
            if hasPendingSiri {
                AppLogger.debug("📱 AppDelegate: Pending Siri playback detected, deferring startup sync further...")
                try? await Task.sleep(nanoseconds: 10_000_000_000) // Another 10s
            }

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
            // Use default routing to allow both local speaker and external routes.
            // The .allowAirPlay option enables HomePod/AirPlay without requiring
            // .longFormAudio policy (which deprioritizes local speaker playback).
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP, .allowBluetooth]
            )
        } catch {
            AppLogger.debug("Failed to configure audio session: \(error)")
        }
    }

    private func configureSiriAuthorization() {
        let status = INPreferences.siriAuthorizationStatus()
        #if DEBUG
        AppLogger.debug("📱 AppDelegate: Siri authorization status at launch: \(status.rawValue)")
        #endif

        guard status == .notDetermined else {
            return
        }

        INPreferences.requestSiriAuthorization { newStatus in
            #if DEBUG
            AppLogger.debug("📱 AppDelegate: Siri authorization prompt result: \(newStatus.rawValue)")
            #endif
        }
    }

    private func registerForSiriPendingPlaybackNotification() {
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            notifyCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                appDelegate.handleSiriPendingPlaybackNotification()
            },
            Self.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        os_log(.info, "SIRI_APP: Registered for Darwin notification: %{public}@", Self.darwinNotificationName)
    }

    private func handleSiriPendingPlaybackNotification() {
        os_log(.info, "SIRI_APP: Received trigger for pending playback")

        // Read and execute the pending payload
        guard let payload = readAndClearPendingPayload() else {
            // This is expected if multiple triggers (Darwin + Background URL Session) arrive
            // and the first one already cleared the payload.
            os_log(.debug, "SIRI_APP: No pending payload found (already processed or not present)")
            return
        }

        os_log(.info, "SIRI_APP: Executing pending payload kind=%{public}@ entity=%{public}@", payload.kind.rawValue, payload.entityID)
        executeSiriPlaybackInBackground(payload: payload, origin: "pendingPlaybackTrigger")
    }

    private func readAndClearPendingPayload() -> SiriPlaybackRequestPayload? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }

        let pendingFile = containerURL.appendingPathComponent(Self.pendingPlaybackFilename)

        guard FileManager.default.fileExists(atPath: pendingFile.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: pendingFile)

            // Clear the file immediately to prevent duplicate execution
            try FileManager.default.removeItem(at: pendingFile)

            // Decode the payload (extension uses SiriPayloadIdentifier, we need to convert)
            let decoder = JSONDecoder()
            let extensionPayload = try decoder.decode(ExtensionSiriPayloadIdentifier.self, from: data)

            // Convert to app payload format
            let kind: SiriMediaKind
            switch extensionPayload.kind {
            case "track": kind = .track
            case "album": kind = .album
            case "artist": kind = .artist
            case "playlist": kind = .playlist
            default: kind = .track
            }

            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: extensionPayload.entityID,
                sourceCompositeKey: extensionPayload.sourceCompositeKey,
                displayName: extensionPayload.displayName
            )
        } catch {
            os_log(.error, "SIRI_APP: Failed to read pending payload: %{public}@", error.localizedDescription)
            return nil
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

    // MARK: - Scene Will Connect (iOS 13+ scene lifecycle)

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        os_log(.info, "SIRI_APP: configurationForConnecting - activities=%{public}d, intents=%{public}d",
               options.userActivities.count,
               options.shortcutItem != nil ? 1 : 0)

        // Check if there's a Siri userActivity in the connection options
        for activity in options.userActivities {
            os_log(.info, "SIRI_APP: scene connection has activity type=%{public}@", activity.activityType)
            if activity.activityType == "com.videogorl.ensemble.siri.playmedia" {
                os_log(.info, "SIRI_APP: Detected Siri playmedia activity in scene connection!")
            }
        }

        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // MARK: - Intent Handling (iOS 18+ may route handleInApp through this)

    func application(
        _ application: UIApplication,
        handlerFor intent: INIntent
    ) -> Any? {
        os_log(.info, "SIRI_APP: application(handlerFor:) called with intent type: %{public}@", String(describing: type(of: intent)))

        if let playMediaIntent = intent as? INPlayMediaIntent {
            os_log(.info, "SIRI_APP: Returning InAppPlayMediaIntentHandler for INPlayMediaIntent")
            return InAppPlayMediaIntentHandler()
        }

        os_log(.info, "SIRI_APP: No handler for intent type, returning nil")
        return nil
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        os_log(.info, "SIRI_APP: AppDelegate.continue(userActivity:) ENTRY - type=%{public}@", userActivity.activityType)

        // Log all details about the incoming activity
        let forwardedIntent: String
        if let intent = userActivity.interaction?.intent {
            forwardedIntent = String(describing: type(of: intent))
        } else {
            forwardedIntent = "nil"
        }
        os_log(.info, "SIRI_APP: activity type=%{public}@, intent=%{public}@", userActivity.activityType, forwardedIntent)
        os_log(.info, "SIRI_APP: interaction=%{public}@, userInfo keys=%{public}@",
               userActivity.interaction != nil ? "present" : "nil",
               String(describing: userActivity.userInfo?.keys.map { "\($0)" } ?? []))

        // Log if this is a Siri-initiated activity
        if let interaction = userActivity.interaction {
            os_log(.info, "SIRI_APP: interaction.intentHandlingStatus=%{public}ld", interaction.intentHandlingStatus.rawValue)
            if let playMediaIntent = interaction.intent as? INPlayMediaIntent {
                os_log(.info, "SIRI_APP: INPlayMediaIntent found in interaction")
                os_log(.info, "SIRI_APP: mediaItems count=%{public}d, container=%{public}@",
                       playMediaIntent.mediaItems?.count ?? 0,
                       playMediaIntent.mediaContainer?.title ?? "nil")
                if let firstItem = playMediaIntent.mediaItems?.first {
                    os_log(.info, "SIRI_APP: firstItem title=%{public}@, identifier=%{public}@",
                           firstItem.title ?? "nil",
                           firstItem.identifier ?? "nil")
                }
            }
        }

        guard let payload = siriPlaybackPayload(from: userActivity) else {
            os_log(.error, "SIRI_APP: Payload decode FAILED - returning false")
            return false
        }

        os_log(.info, "SIRI_APP: Payload decoded - kind=%{public}@, entityID=%{public}@", payload.kind.rawValue, payload.entityID)

        executeSiriPlaybackInBackground(payload: payload, origin: "continueUserActivity")

        return true
    }

    /// Accepts both extension-supplied user activity payloads and direct Siri forwarded intents.
    private func siriPlaybackPayload(from userActivity: NSUserActivity) -> SiriPlaybackRequestPayload? {
        if let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) {
            return payload
        }

        guard let playMediaIntent = userActivity.interaction?.intent as? INPlayMediaIntent else {
            return nil
        }

        return payload(fromForwardedPlayMediaIntent: playMediaIntent)
    }

    private func payload(fromForwardedPlayMediaIntent intent: INPlayMediaIntent) -> SiriPlaybackRequestPayload? {
        let rawIdentifier = normalizedIntentIdentifier(from: intent)

        if let identifier = rawIdentifier,
           let decoded = decodePayloadIdentifier(identifier),
           decoded.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion {
            return decoded
        }

        // Fallback to query if identifier is missing or failed to decode.
        if let query = siriQueryText(from: intent), !query.isEmpty {
            let sanitizedQuery = normalizedSiriQuery(query)

            let kind = siriMediaKind(from: intent)
            #if DEBUG
            AppLogger.debug("📱 AppDelegate: Siri fallback payload for query='\(sanitizedQuery)' kind=\(kind.rawValue)")
            #endif

            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: sanitizedQuery,
                sourceCompositeKey: nil,
                displayName: sanitizedQuery
            )
        }

        if let rawIdentifier {
            let kind = siriMediaKind(from: intent)
            #if DEBUG
            AppLogger.debug("📱 AppDelegate: Siri fallback payload using raw identifier kind=\(kind.rawValue)")
            #endif
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: rawIdentifier,
                sourceCompositeKey: nil,
                displayName: intent.mediaItems?.first?.title ?? intent.mediaContainer?.title ?? rawIdentifier
            )
        }

        return nil
    }

    private func decodePayloadIdentifier(_ identifier: String) -> SiriPlaybackRequestPayload? {
        guard let data = Data(base64Encoded: identifier) else {
            return nil
        }
        return try? SiriPlaybackActivityCodec.decode(from: data)
    }

    private func normalizedIntentIdentifier(from intent: INPlayMediaIntent) -> String? {
        let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func siriQueryText(from intent: INPlayMediaIntent) -> String? {
        if let explicit = intent.mediaItems?.first?.title, !explicit.isEmpty {
            return explicit
        }
        if let containerTitle = intent.mediaContainer?.title, !containerTitle.isEmpty {
            return containerTitle
        }
        if let mediaSearch = intent.mediaSearch {
            if let searched = mediaSearch.mediaName, !searched.isEmpty {
                return searched
            }
            if let artistName = mediaSearch.artistName, !artistName.isEmpty {
                return artistName
            }
            if let albumName = mediaSearch.albumName, !albumName.isEmpty {
                return albumName
            }
        }
        return nil
    }

    private func siriMediaKind(from intent: INPlayMediaIntent) -> SiriMediaKind {
        let mediaType = intent.mediaSearch?.mediaType
            ?? intent.mediaContainer?.type
            ?? intent.mediaItems?.first?.type
            ?? .unknown

        switch mediaType {
        case .song:
            return .track
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        default:
            if let artistName = intent.mediaSearch?.artistName, !artistName.isEmpty {
                return .artist
            }
            if let albumName = intent.mediaSearch?.albumName, !albumName.isEmpty {
                return .album
            }
            if intent.mediaContainer?.type == .playlist {
                return .playlist
            }
            if let inferred = inferredSiriMediaKind(from: siriQueryText(from: intent)) {
                return inferred
            }
            return .track
        }
    }

    private func normalizedSiriQuery(_ value: String) -> String {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for suffix in Self.siriAppNameSuffixes where normalized.hasSuffix(suffix) {
            let trimmed = normalized.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return strippingLeadingMediaTypePrefix(
                from: trimTrailingConnectorWords(in: trimmed)
            )
        }

        return strippingLeadingMediaTypePrefix(
            from: trimTrailingConnectorWords(in: normalized)
        )
    }

    private func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, Self.siriTrailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private func strippingLeadingMediaTypePrefix(from value: String) -> String {
        for prefix in Self.siriLeadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return value
    }

    private func inferredSiriMediaKind(from query: String?) -> SiriMediaKind? {
        guard let query else { return nil }
        let normalized = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("the playlist ") || normalized.hasPrefix("playlist ") {
            return .playlist
        }
        if normalized.hasPrefix("the album ") || normalized.hasPrefix("album ") {
            return .album
        }
        if normalized.hasPrefix("the artist ") || normalized.hasPrefix("artist ") {
            return .artist
        }
        if normalized.hasPrefix("the song ")
            || normalized.hasPrefix("song ")
            || normalized.hasPrefix("the track ")
            || normalized.hasPrefix("track ") {
            return .track
        }
        return nil
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Stop network monitoring and WebSocket connections to save battery
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.stopMonitoring()
            DependencyContainer.shared.webSocketCoordinator.stop()

            // Stop periodic sync timers
            DependencyContainer.shared.syncCoordinator.stopPeriodicSync()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Resume network monitoring and WebSocket connections
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.startMonitoring()
            DependencyContainer.shared.webSocketCoordinator.start()

            // Route foreground refresh through SyncCoordinator to coalesce
            // with network state transitions and cooldown/staleness guards.
            await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()

            // Adjust periodic sync timers based on WebSocket availability.
            // With active WebSocket, polling is relaxed (4h); without it, default (1h).
            let hasWebSocket = !DependencyContainer.shared.webSocketCoordinator.connectedServerKeys.isEmpty
            DependencyContainer.shared.syncCoordinator.adjustTimersForWebSocket(hasActiveWebSocket: hasWebSocket)

            // Drain any pending offline mutations now that connectivity may have resumed.
            // The queue also drains automatically when isConnected transitions to true,
            // but an explicit call here handles the case where connectivity never dropped.
            await DependencyContainer.shared.mutationCoordinator.drainQueue()

            // Update Siri media user context in case library changed while backgrounded
            await DependencyContainer.shared.siriMediaUserContextManager.updateMediaUserContext()
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

/// Mirrors the extension's SiriPayloadIdentifier for decoding from App Group
private struct ExtensionSiriPayloadIdentifier: Codable {
    let schemaVersion: Int
    let kind: String
    let entityID: String
    let sourceCompositeKey: String?
    let displayName: String?
}

func executeSiriPlaybackInBackground(payload: SiriPlaybackRequestPayload, origin: String) {
    guard let executionSignature = SiriPlaybackExecutionGate.beginExecution(payload: payload) else {
        os_log(
            .info,
            "SIRI_APP: [origin=%{public}@] Skipping duplicate Siri payload kind=%{public}@ entity=%{public}@",
            origin,
            payload.kind.rawValue,
            payload.entityID
        )
        return
    }

    let application = UIApplication.shared
    let backgroundTaskID = application.beginBackgroundTask(withName: "SiriPlayback.\(origin)")

    Task { @MainActor in
        defer {
            SiriPlaybackExecutionGate.finishExecution(signature: executionSignature)
            if backgroundTaskID != .invalid {
                application.endBackgroundTask(backgroundTaskID)
            }
        }

        // Siri can launch us without the normal UI lifecycle warmup.
        DependencyContainer.shared.accountManager.loadAccounts()

        // Give the system a moment to settle after wake-up before we start
        // demanding audio session priority and network resources.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        do {
            let hadExternalRouteBeforeExecute = await waitForPotentialExternalRoute(origin: origin)
            try? AVAudioSession.sharedInstance().setActive(true)

            let routeBefore = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            os_log(.info, "SIRI_APP: [origin=%{public}@] Audio route BEFORE execute: %{public}@", origin, routeBefore)
            os_log(.info, "SIRI_APP: [origin=%{public}@] Calling coordinator.execute()", origin)
            try await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
            
            let routeAfter = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            os_log(.info, "SIRI_APP: [origin=%{public}@] Audio route AFTER execute: %{public}@", origin, routeAfter)
            os_log(.info, "SIRI_APP: [origin=%{public}@] Coordinator execute SUCCESS", origin)

            // If the request started locally, give HomePod/AirPlay one more chance
            // to finalize route transfer after playback setup.
            if !hadExternalRouteBeforeExecute {
                let switchedAfterExecute = await waitForPotentialExternalRoute(
                    origin: origin,
                    phase: "postExecute",
                    timeoutNanoseconds: 6_000_000_000
                )
                if switchedAfterExecute {
                    os_log(
                        .info,
                        "SIRI_APP: [origin=%{public}@] External route appeared post-execute; nudging resume in 500ms",
                        origin
                    )
                    // Wait a tiny bit more for the hardware/buffer to settle
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    DependencyContainer.shared.playbackService.resume()
                }
            }
        } catch {
            if let siriError = error as? SiriPlaybackCoordinatorError {
                os_log(.error, "SIRI_APP: [origin=%{public}@] Coordinator error: %{public}@", origin, siriError.localizedDescription)
            } else {
                os_log(.error, "SIRI_APP: [origin=%{public}@] Unexpected error: %{public}@", origin, error.localizedDescription)
            }
        }
    }
}

@MainActor
@discardableResult
private func waitForPotentialExternalRoute(
    origin: String,
    phase: String = "preExecute",
    timeoutNanoseconds: UInt64 = 6_000_000_000
) async -> Bool {
    let session = AVAudioSession.sharedInstance()
    let initialOutputs = session.currentRoute.outputs
    guard !hasExternalOutputRoute(initialOutputs) else {
        return true
    }

    // HomePod requests can establish the AirPlay route shortly after Siri
    // wakes the app. Poll briefly before and after playback setup to avoid
    // racing local speaker playback when route transfer is still in flight.
    let stepNanoseconds: UInt64 = 250_000_000
    var waited: UInt64 = 0

    while waited < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: stepNanoseconds)
        waited += stepNanoseconds

        let outputs = session.currentRoute.outputs
        if hasExternalOutputRoute(outputs) {
            let route = outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            os_log(
                .info,
                "SIRI_APP: [origin=%{public}@][phase=%{public}@] Route switched to external: %{public}@",
                origin,
                phase,
                route
            )
            return true
        }
    }

    let route = session.currentRoute.outputs
        .map { "\($0.portType.rawValue):\($0.portName)" }
        .joined(separator: ",")
    os_log(
        .info,
        "SIRI_APP: [origin=%{public}@][phase=%{public}@] Route remained local after wait: %{public}@",
        origin,
        phase,
        route
    )
    return false
}

private func hasExternalOutputRoute(_ outputs: [AVAudioSessionPortDescription]) -> Bool {
    outputs.contains { output in
        output.portType != .builtInSpeaker && output.portType != .builtInReceiver
    }
}

private enum SiriPlaybackExecutionGate {
    private static var lastExecutionDates: [String: Date] = [:]
    private static var inFlightSignatures: Set<String> = []
    private static let lock = NSLock()
    private static let duplicateWindow: TimeInterval = 8

    static func beginExecution(payload: SiriPlaybackRequestPayload) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let signature = [
            payload.kind.rawValue,
            payload.entityID
        ].joined(separator: "|")

        let now = Date()
        pruneExpiredEntries(now: now)

        if inFlightSignatures.contains(signature) {
            return nil
        }

        if let lastExecutionDate = lastExecutionDates[signature],
           now.timeIntervalSince(lastExecutionDate) <= duplicateWindow {
            return nil
        }

        inFlightSignatures.insert(signature)
        lastExecutionDates[signature] = now
        return signature
    }

    static func finishExecution(signature: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlightSignatures.remove(signature)
    }

    private static func pruneExpiredEntries(now: Date) {
        lastExecutionDates = lastExecutionDates.filter { now.timeIntervalSince($0.value) <= duplicateWindow }
    }
}

// MARK: - In-App Intent Handler

/// Handles INPlayMediaIntent when iOS routes it directly to the app (handleInApp path on iOS 18+)
final class InAppPlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let siriAppNameSuffixes = [" ensemble music", " ensemble"]
    private static let siriTrailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    private static let siriLeadingMediaTypePrefixes = [
        "the playlist ",
        "playlist ",
        "the album ",
        "album ",
        "the artist ",
        "artist ",
        "the song ",
        "song ",
        "the track ",
        "track "
    ]

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        os_log(.info, "SIRI_APP: InAppPlayMediaIntentHandler.handle() called")

        guard let payload = payload(from: intent) else {
            os_log(.error, "SIRI_APP: InAppPlayMediaIntentHandler - failed to decode payload/query from intent")
            completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
            return
        }

        os_log(
            .info,
            "SIRI_APP: InAppPlayMediaIntentHandler - accepted payload kind=%{public}@ entity=%{public}@",
            payload.kind.rawValue,
            payload.entityID
        )

        // Reply immediately so Siri/HomePod does not time out while playback setup performs network work.
        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
        executePlaybackAsync(payload: payload)
    }

    private func executePlaybackAsync(payload: SiriPlaybackRequestPayload) {
        executeSiriPlaybackInBackground(payload: payload, origin: "inAppIntentHandler")
    }

    private func payload(from intent: INPlayMediaIntent) -> SiriPlaybackRequestPayload? {
        let rawIdentifier = normalizedIntentIdentifier(from: intent)

        if let identifier = rawIdentifier,
           let data = Data(base64Encoded: identifier),
           let payload = try? SiriPlaybackActivityCodec.decode(from: data) {
            return payload
        }

        if let query = queryText(from: intent), !query.isEmpty {
            let sanitizedQuery = normalizedSiriQuery(query)
            guard !sanitizedQuery.isEmpty else {
                return nil
            }

            os_log(.info, "SIRI_APP: InAppPlayMediaIntentHandler - using fallback query: %{public}@", sanitizedQuery)
            let kind = mediaKindFrom(intent: intent, fallbackQuery: query)
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: sanitizedQuery,
                sourceCompositeKey: nil,
                displayName: sanitizedQuery
            )
        }

        if let rawIdentifier {
            os_log(.info, "SIRI_APP: InAppPlayMediaIntentHandler - using raw identifier fallback")
            let kind = mediaKindFrom(intent: intent, fallbackQuery: nil)
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: rawIdentifier,
                sourceCompositeKey: nil,
                displayName: intent.mediaItems?.first?.title ?? intent.mediaContainer?.title ?? rawIdentifier
            )
        }

        return nil
    }

    private func normalizedIntentIdentifier(from intent: INPlayMediaIntent) -> String? {
        let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func queryText(from intent: INPlayMediaIntent) -> String? {
        if let explicit = intent.mediaItems?.first?.title, !explicit.isEmpty {
            return explicit
        }
        if let containerTitle = intent.mediaContainer?.title, !containerTitle.isEmpty {
            return containerTitle
        }
        if let mediaSearch = intent.mediaSearch {
            if let searched = mediaSearch.mediaName, !searched.isEmpty {
                return searched
            }
            if let artistName = mediaSearch.artistName, !artistName.isEmpty {
                return artistName
            }
            if let albumName = mediaSearch.albumName, !albumName.isEmpty {
                return albumName
            }
            if let genreName = mediaSearch.genreNames?.first, !genreName.isEmpty {
                return genreName
            }
            if let moodName = mediaSearch.moodNames?.first, !moodName.isEmpty {
                return moodName
            }
        }
        return nil
    }

    private func mediaKindFrom(intent: INPlayMediaIntent, fallbackQuery: String?) -> SiriMediaKind {
        let mediaType = intent.mediaSearch?.mediaType
            ?? intent.mediaContainer?.type
            ?? intent.mediaItems?.first?.type
            ?? .unknown

        switch mediaType {
        case .song: return .track
        case .album: return .album
        case .artist: return .artist
        case .playlist: return .playlist
        default:
            if let artistName = intent.mediaSearch?.artistName, !artistName.isEmpty { return .artist }
            if let albumName = intent.mediaSearch?.albumName, !albumName.isEmpty { return .album }
            if intent.mediaContainer?.type == .playlist { return .playlist }
            if let inferred = inferredSiriMediaKind(from: fallbackQuery) { return inferred }
            return .track
        }
    }

    private func normalizedSiriQuery(_ value: String) -> String {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for suffix in Self.siriAppNameSuffixes where normalized.hasSuffix(suffix) {
            let trimmed = normalized.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return strippingLeadingMediaTypePrefix(
                from: trimTrailingConnectorWords(in: trimmed)
            )
        }

        return strippingLeadingMediaTypePrefix(
            from: trimTrailingConnectorWords(in: normalized)
        )
    }

    private func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, Self.siriTrailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private func strippingLeadingMediaTypePrefix(from value: String) -> String {
        for prefix in Self.siriLeadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return value
    }

    private func inferredSiriMediaKind(from query: String?) -> SiriMediaKind? {
        guard let query else { return nil }
        let normalized = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("the playlist ") || normalized.hasPrefix("playlist ") {
            return .playlist
        }
        if normalized.hasPrefix("the album ") || normalized.hasPrefix("album ") {
            return .album
        }
        if normalized.hasPrefix("the artist ") || normalized.hasPrefix("artist ") {
            return .artist
        }
        if normalized.hasPrefix("the song ")
            || normalized.hasPrefix("song ")
            || normalized.hasPrefix("the track ")
            || normalized.hasPrefix("track ") {
            return .track
        }
        return nil
    }
}

// MARK: - Space Bar → Play/Pause Keyboard Shortcut

/// Intercepts hardware keyboard space-bar presses to toggle play/pause.
///
/// Uses two independent mechanisms for reliability:
/// 1. `UIApplication.sendEvent` swizzle — catches UIPressesEvent before responder chain
/// 2. `GCKeyboard` (GameController framework) — independent HID-level keyboard monitoring
///
/// Text-field safety: tracks UITextField/UITextView begin/end editing notifications
/// so the space bar is only intercepted when no text input is active.
enum SpaceBarPlaybackShortcut {
    private static var installed = false

    /// Tracks how many text inputs are currently editing.
    private static var activeTextInputCount = 0

    /// Call once from `AppDelegate.didFinishLaunchingWithOptions`.
    static func install() {
        guard !installed else { return }
        installed = true

        installSendEventSwizzle()
        installGCKeyboardMonitoring()
        observeTextInputLifecycle()
    }

    /// Whether a text field or text view is currently being edited.
    static var isTextInputActive: Bool { activeTextInputCount > 0 }

    /// Toggles playback if in a playing or paused state.
    static func togglePlayback() {
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

    // MARK: - Mechanism 1: sendEvent Swizzle

    private static func installSendEventSwizzle() {
        let originalSelector = #selector(UIApplication.sendEvent(_:))
        let swizzledSelector = #selector(UIApplication.ensemble_interceptEvent(_:))

        guard let originalMethod = class_getInstanceMethod(UIApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIApplication.self, swizzledSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    // MARK: - Mechanism 2: GCKeyboard (GameController)

    private static func installGCKeyboardMonitoring() {
        // Check for already-connected keyboard
        if let keyboard = GCKeyboard.coalesced {
            configureGCKeyboard(keyboard)
        }

        // Watch for keyboard connect/disconnect
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil, queue: .main
        ) { notification in
            if let keyboard = notification.object as? GCKeyboard {
                configureGCKeyboard(keyboard)
            }
        }
    }

    private static func configureGCKeyboard(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { _, _, keyCode, pressed in
            guard pressed, keyCode == .spacebar else { return }
            DispatchQueue.main.async {
                guard !isTextInputActive else { return }
                togglePlayback()
            }
        }
    }

    // MARK: - Text Input Tracking

    private static func observeTextInputLifecycle() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { _ in activeTextInputCount += 1 }

        nc.addObserver(
            forName: UITextField.textDidEndEditingNotification,
            object: nil, queue: .main
        ) { _ in activeTextInputCount = max(0, activeTextInputCount - 1) }

        nc.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { _ in activeTextInputCount += 1 }

        nc.addObserver(
            forName: UITextView.textDidEndEditingNotification,
            object: nil, queue: .main
        ) { _ in activeTextInputCount = max(0, activeTextInputCount - 1) }
    }
}

// MARK: - UIApplication Swizzle Target

extension UIApplication {
    /// After swizzle this replaces `sendEvent(_:)`.
    /// Intercepts bare space-bar presses when no text input is active.
    @objc func ensemble_interceptEvent(_ event: UIEvent) {
        // Fast path: only inspect press events (hardware keyboard)
        if event.type == .presses, let pressEvent = event as? UIPressesEvent {
            for press in pressEvent.allPresses {
                guard let key = press.key,
                      key.keyCode == .keyboardSpacebar,
                      // Bare space only — ignore Cmd+Space, Shift+Space, etc.
                      key.modifierFlags.intersection([.command, .alternate, .control, .shift]).isEmpty,
                      !SpaceBarPlaybackShortcut.isTextInputActive else {
                    continue
                }

                // Toggle on key-down; consume all phases so scroll views
                // don't also page-scroll.
                if press.phase == .began {
                    SpaceBarPlaybackShortcut.togglePlayback()
                }
                return
            }
        }

        // All other events → original path
        ensemble_interceptEvent(event)
    }
}
#endif
