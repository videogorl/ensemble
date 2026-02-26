#if os(iOS)
import AVFoundation
import AppIntents
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
        }
        
        // Perform startup sync (non-blocking, runs in background)
        Task.detached(priority: .utility) {
            // Wait a bit longer to ensure the app is fully initialized
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
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
            // Use long-form route sharing so Siri/HomePod handoff can prefer
            // remote playback routes instead of forcing local speaker output.
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
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

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Handle background download completion
        completionHandler()
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

        let forwardedIntent: String
        if let intent = userActivity.interaction?.intent {
            forwardedIntent = String(describing: type(of: intent))
        } else {
            forwardedIntent = "nil"
        }
        os_log(.info, "SIRI_APP: activity type=%{public}@, intent=%{public}@", userActivity.activityType, forwardedIntent)

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
        if let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier,
           let decoded = decodePayloadIdentifier(identifier),
           decoded.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion {
            return decoded
        }

        // Fallback to query if identifier is missing or failed to decode
        guard let query = siriQueryText(from: intent), !query.isEmpty else {
            return nil
        }
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

    private func decodePayloadIdentifier(_ identifier: String) -> SiriPlaybackRequestPayload? {
        guard let data = Data(base64Encoded: identifier) else {
            return nil
        }
        return try? SiriPlaybackActivityCodec.decode(from: data)
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

            // Route foreground refresh through SyncCoordinator to coalesce
            // with network state transitions and cooldown/staleness guards.
            await DependencyContainer.shared.syncCoordinator.handleAppWillEnterForeground()
            
            // Restart periodic sync timers
            DependencyContainer.shared.syncCoordinator.startPeriodicSync()
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
                    timeoutNanoseconds: 4_000_000_000
                )
                if switchedAfterExecute {
                    os_log(
                        .info,
                        "SIRI_APP: [origin=%{public}@] External route appeared post-execute; nudging resume",
                        origin
                    )
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
        if let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier,
           let data = Data(base64Encoded: identifier),
           let payload = try? SiriPlaybackActivityCodec.decode(from: data) {
            return payload
        }

        guard let query = queryText(from: intent), !query.isEmpty else {
            return nil
        }
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
#endif
