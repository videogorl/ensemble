#if os(iOS)
import AVFoundation
import Intents
import UIKit
import EnsembleCore
import EnsembleSiriShared

extension AppDelegate {
    func registerForSiriPendingPlaybackNotification() {
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
        AppLogger.info("SIRI_APP: Registered for Darwin notification: \(Self.darwinNotificationName)")
    }

    func registerForSiriAffinityNotification() {
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            notifyCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                appDelegate.handleSiriPendingAffinityNotification()
            },
            Self.darwinAffinityNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        AppLogger.info("SIRI_APP: Registered for Darwin notification: \(Self.darwinAffinityNotificationName)")
    }

    private func handleSiriPendingAffinityNotification() {
        AppLogger.info("SIRI_APP: Received trigger for pending affinity")

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }

        let fileURL = containerURL.appendingPathComponent(Self.pendingAffinityFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.debug("SIRI_APP: No pending affinity file found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            try FileManager.default.removeItem(at: fileURL)

            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let affinityTypeStr = dict["affinityType"] as? String else {
                AppLogger.error("SIRI_APP: Failed to decode affinity payload")
                return
            }

            let affinityType: SiriAffinityType
            switch affinityTypeStr {
            case "love": affinityType = .love
            case "dislike": affinityType = .dislike
            case "remove": affinityType = .remove
            default: affinityType = .love
            }

            let payload = SiriAffinityRequestPayload(affinityType: affinityType)
            AppLogger.info("SIRI_APP: Executing affinity request: \(affinityTypeStr)")

            Task { @MainActor in
                try? await DependencyContainer.shared.siriAffinityCoordinator.execute(payload: payload)
            }
        } catch {
            AppLogger.error("SIRI_APP: Failed to read/process affinity file: \(error.localizedDescription)")
        }
    }

    func registerForSiriAddToPlaylistNotification() {
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            notifyCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                appDelegate.handleSiriPendingAddToPlaylistNotification()
            },
            Self.darwinAddToPlaylistNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        AppLogger.info("SIRI_APP: Registered for Darwin notification: \(Self.darwinAddToPlaylistNotificationName)")
    }

    private func handleSiriPendingAddToPlaylistNotification() {
        AppLogger.info("SIRI_APP: Received trigger for pending add-to-playlist")

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }

        let fileURL = containerURL.appendingPathComponent(Self.pendingAddToPlaylistFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.debug("SIRI_APP: No pending add-to-playlist file found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            try FileManager.default.removeItem(at: fileURL)

            let decoder = JSONDecoder()
            let payload = try decoder.decode(SiriAddToPlaylistRequestPayload.self, from: data)
            AppLogger.info("SIRI_APP: Executing add-to-playlist: playlist=\(payload.playlistDisplayName ?? "unknown")")

            Task { @MainActor in
                try? await DependencyContainer.shared.siriAddToPlaylistCoordinator.execute(payload: payload)
            }
        } catch {
            AppLogger.error("SIRI_APP: Failed to read/process add-to-playlist file: \(error.localizedDescription)")
        }
    }

    private func handleSiriPendingPlaybackNotification() {
        AppLogger.info("SIRI_APP: Received trigger for pending playback")

        // Read and execute the pending payload
        guard let payload = readAndClearPendingPayload() else {
            // This is expected if multiple triggers (Darwin + Background URL Session) arrive
            // and the first one already cleared the payload.
            AppLogger.debug("SIRI_APP: No pending payload found (already processed or not present)")
            return
        }

        AppLogger.info("SIRI_APP: Executing pending payload kind=\(payload.kind.rawValue) entity=\(payload.entityID)")
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
                displayName: extensionPayload.displayName,
                artistHint: extensionPayload.artistHint,
                shuffle: extensionPayload.shuffle
            )
        } catch {
            AppLogger.error("SIRI_APP: Failed to read pending payload: \(error.localizedDescription)")
            return nil
        }
    }

    func application(
        _ application: UIApplication,
        handlerFor intent: INIntent
    ) -> Any? {
        AppLogger.info("SIRI_APP: application(handlerFor:) called with intent type: \(String(describing: type(of: intent)))")

        // Mark that a Siri intent is pending so playback restoration is suppressed.
        // This is set synchronously before any async work, preventing the restoration
        // task from overwriting the Siri-initiated queue.
        hasPendingSiriIntent = true

        // INPlayMediaIntent is NOT in the app's Info.plist INIntentsSupported,
        // so iOS routes the initial intent through the Siri extension. The
        // extension returns .handleInApp which triggers AirPlay route setup
        // from HomePod, then iOS forwards the intent here for execution.
        // We must return a handler so the forwarded intent succeeds.
        if intent is INPlayMediaIntent {
            AppLogger.info("SIRI_APP: Returning InAppPlayMediaIntentHandler for forwarded INPlayMediaIntent")
            return InAppPlayMediaIntentHandler()
        }

        if intent is INAddMediaIntent {
            AppLogger.info("SIRI_APP: Returning handler for INAddMediaIntent")
            // INAddMediaIntent is handled via NSUserActivity delivery, not in-app handler
        }

        if intent is INUpdateMediaAffinityIntent {
            AppLogger.info("SIRI_APP: Returning handler for INUpdateMediaAffinityIntent")
            // INUpdateMediaAffinityIntent is handled via NSUserActivity delivery
        }

        AppLogger.info("SIRI_APP: No handler for intent type, returning nil")
        return nil
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        AppLogger.info("SIRI_APP: AppDelegate.continue(userActivity:) ENTRY - type=\(userActivity.activityType)")

        // Log all details about the incoming activity
        let forwardedIntent: String
        if let intent = userActivity.interaction?.intent {
            forwardedIntent = String(describing: type(of: intent))
        } else {
            forwardedIntent = "nil"
        }
        AppLogger.info("SIRI_APP: activity type=\(userActivity.activityType), intent=\(forwardedIntent)")
        AppLogger.info(
            "SIRI_APP: interaction=\(userActivity.interaction != nil ? "present" : "nil"), userInfo keys=\(String(describing: userActivity.userInfo?.keys.map { "\($0)" } ?? []))"
        )

        // Log if this is a Siri-initiated activity
        if let interaction = userActivity.interaction {
            AppLogger.info("SIRI_APP: interaction.intentHandlingStatus=\(interaction.intentHandlingStatus.rawValue)")
            if let playMediaIntent = interaction.intent as? INPlayMediaIntent {
                AppLogger.info("SIRI_APP: INPlayMediaIntent found in interaction")
                AppLogger.info(
                    "SIRI_APP: mediaItems count=\(playMediaIntent.mediaItems?.count ?? 0), container=\(playMediaIntent.mediaContainer?.title ?? "nil")"
                )
                if let firstItem = playMediaIntent.mediaItems?.first {
                    AppLogger.info(
                        "SIRI_APP: firstItem title=\(firstItem.title ?? "nil"), identifier=\(firstItem.identifier ?? "nil")"
                    )
                }
            }
        }

        guard let payload = siriPlaybackPayload(from: userActivity) else {
            AppLogger.error("SIRI_APP: Payload decode FAILED - returning false")
            return false
        }

        AppLogger.info("SIRI_APP: Payload decoded - kind=\(payload.kind.rawValue), entityID=\(payload.entityID)")

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
        let shuffle = intent.playShuffled

        if let identifier = rawIdentifier,
           var decoded = decodePayloadIdentifier(identifier),
           decoded.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion {
            // Override shuffle from the live intent if it wasn't already set in the payload
            if decoded.shuffle == nil, let shuffle {
                decoded = SiriPlaybackRequestPayload(
                    kind: decoded.kind,
                    entityID: decoded.entityID,
                    sourceCompositeKey: decoded.sourceCompositeKey,
                    displayName: decoded.displayName,
                    artistHint: decoded.artistHint,
                    shuffle: shuffle
                )
            }
            return decoded
        }

        // Fallback to query if identifier is missing or failed to decode.
        if let query = siriQueryText(from: intent), !query.isEmpty {
            let sanitizedQuery = normalizedSiriQuery(query)

            let kind = siriMediaKind(from: intent)
            AppLogger.debug("AppDelegate: Siri fallback payload for query='\(sanitizedQuery)' kind=\(kind.rawValue)")

            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: sanitizedQuery,
                sourceCompositeKey: nil,
                displayName: sanitizedQuery,
                artistHint: intent.mediaSearch?.artistName,
                shuffle: shuffle
            )
        }

        if let rawIdentifier {
            let kind = siriMediaKind(from: intent)
            AppLogger.debug("AppDelegate: Siri fallback payload using raw identifier kind=\(kind.rawValue)")
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: rawIdentifier,
                sourceCompositeKey: nil,
                displayName: intent.mediaItems?.first?.title ?? intent.mediaContainer?.title ?? rawIdentifier,
                artistHint: intent.mediaSearch?.artistName,
                shuffle: shuffle
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
            let hasMediaName = intent.mediaSearch?.mediaName.map { !$0.isEmpty } ?? false
            // Only infer .artist/.album when mediaName is absent.
            // "Play [song] by [artist]" has both → default to .track.
            if let artistName = intent.mediaSearch?.artistName, !artistName.isEmpty, !hasMediaName {
                return .artist
            }
            if let albumName = intent.mediaSearch?.albumName, !albumName.isEmpty, !hasMediaName {
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
        SiriPhraseNormalizer.normalized(value)
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

/// Mirrors the extension's SiriPayloadIdentifier for decoding from App Group
private struct ExtensionSiriPayloadIdentifier: Codable {
    let schemaVersion: Int
    let kind: String
    let entityID: String
    let sourceCompositeKey: String?
    let displayName: String?
    let artistHint: String?
    let shuffle: Bool?
}

func executeSiriPlaybackInBackground(
    payload: SiriPlaybackRequestPayload,
    origin: String,
    intentCompletion: ((INPlayMediaIntentResponse) -> Void)? = nil
) {
    guard let executionSignature = SiriPlaybackExecutionGate.beginExecution(payload: payload) else {
        AppLogger.info(
            "SIRI_APP: [origin=\(origin)] Skipping duplicate Siri payload kind=\(payload.kind.rawValue) entity=\(payload.entityID)"
        )
        intentCompletion?(INPlayMediaIntentResponse(code: .success, userActivity: nil))
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
        // Load accounts synchronously (already done in didFinishLaunching,
        // but harmless and safe for the cold-launch race).
        DependencyContainer.shared.accountManager.loadAccounts()
        DependencyContainer.shared.serverHealthChecker.prepopulateUnknownStates()

        // Await the early health check task from didFinishLaunching instead of
        // running a separate set of health checks. This avoids redundant work
        // and means Siri can proceed as soon as the already-in-flight checks finish.
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let shc = DependencyContainer.shared.serverHealthChecker
        if let earlyTask = appDelegate?.earlyHealthCheckTask {
            AppLogger.info("SIRI_APP: [origin=\(origin)] Awaiting early health checks from didFinishLaunching...")
            await earlyTask.value
        } else {
            AppLogger.info("SIRI_APP: [origin=\(origin)] No earlyHealthCheckTask found — running standalone health checks")
        }

        // Log server states at this point for diagnostics
        let statesSummary = shc.serverStates.map { "\($0.key.suffix(8)):\($0.value.isAvailable ? "up" : "down")" }.joined(separator: ",")
        AppLogger.info("SIRI_APP: [origin=\(origin)] Post-health serverStates: [\(statesSummary)]")

        // If early checks didn't find any connected servers (edge case: first
        // launch, network delay, etc.), fall back to running our own checks.
        let hasConnectedServers = shc.serverStates.values.contains { $0.isAvailable }
        if !hasConnectedServers {
            AppLogger.info("SIRI_APP: [origin=\(origin)] No connected servers — running fallback health checks")
            let nm = DependencyContainer.shared.networkMonitor
            for _ in 0..<10 {
                if nm.networkState != .unknown { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            await shc.checkAllServers()
            let postFallback = shc.serverStates.map { "\($0.key.suffix(8)):\($0.value.isAvailable ? "up" : "down")" }.joined(separator: ",")
            AppLogger.info("SIRI_APP: [origin=\(origin)] Post-fallback serverStates: [\(postFallback)]")
        }

        // Build sync providers (needed for stream URL resolution) and update
        // API client connections from the registry endpoints.
        let sc = DependencyContainer.shared.syncCoordinator
        sc.refreshProviders()
        await sc.refreshAPIClientConnections()
        AppLogger.info("SIRI_APP: [origin=\(origin)] Server connectivity ready")

        do {
            let playbackService = DependencyContainer.shared.playbackService
            var categoryConfigured = playbackService.ensureAudioSessionConfigured()
            if !categoryConfigured {
                for attempt in 1...3 {
                    AppLogger.info("SIRI_APP: [origin=\(origin)] setCategory retry \(attempt)/3")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    categoryConfigured = playbackService.ensureAudioSessionConfigured()
                    if categoryConfigured { break }
                }
                if !categoryConfigured {
                    AppLogger.error("SIRI_APP: [origin=\(origin)] setCategory failed after retries — proceeding anyway")
                }
            }

            let shouldStartPlayback = await playbackService.preparePlaybackRouteSelection()
            AppLogger.info("SIRI_APP: [origin=\(origin)] prepareRouteSelection: shouldActivate=\(shouldStartPlayback ? 1 : 0)")
            if !shouldStartPlayback {
                AppLogger.info("SIRI_APP: [origin=\(origin)] System declined route activation — activating anyway")
            }
            await playbackService.activatePlaybackAudioSession(shouldStartPlayback: shouldStartPlayback)

            let initialRoute = playbackService.currentAudioRouteDescription()
            AppLogger.info("SIRI_APP: [origin=\(origin)] Audio session activated; initial route: \(initialRoute)")

            AppLogger.info("SIRI_APP: [origin=\(origin)] Calling coordinator.execute()")
            try await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)

            let routeAfter = playbackService.currentAudioRouteDescription()
            AppLogger.info("SIRI_APP: [origin=\(origin)] Coordinator execute SUCCESS; route: \(routeAfter)")

            // Complete the intent response AFTER playback starts. Keeping
            // the intent handler alive until now preserves the system's
            // routing association with the requesting HomePod/AirPlay device.
            intentCompletion?(INPlayMediaIntentResponse(code: .success, userActivity: nil))

            // After playback starts, give the system time to establish the
            // AirPlay route to HomePod. Once we see it, nudge the player.
            let switchedAfterExecute = await waitForPotentialExternalRoute(
                origin: origin,
                phase: "postExecute",
                timeoutNanoseconds: 10_000_000_000
            )
            if switchedAfterExecute {
                AppLogger.info("SIRI_APP: [origin=\(origin)] External route appeared post-execute; nudging playback in 500ms")
                try? await Task.sleep(nanoseconds: 500_000_000)
                DependencyContainer.shared.playbackService.nudgeForAirPlayRoute()
            }
        } catch {
            if let siriError = error as? SiriPlaybackCoordinatorError {
                AppLogger.error("SIRI_APP: [origin=\(origin)] Coordinator error: \(siriError.localizedDescription)")
            } else {
                AppLogger.error("SIRI_APP: [origin=\(origin)] Unexpected error: \(error.localizedDescription)")
            }
            intentCompletion?(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
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
            AppLogger.info("SIRI_APP: [origin=\(origin)][phase=\(phase)] Route switched to external: \(route)")
            return true
        }
    }

    let route = session.currentRoute.outputs
        .map { "\($0.portType.rawValue):\($0.portName)" }
        .joined(separator: ",")
    AppLogger.info("SIRI_APP: [origin=\(origin)][phase=\(phase)] Route remained local after wait: \(route)")
    return false
}

private func hasExternalOutputRoute(_ outputs: [AVAudioSessionPortDescription]) -> Bool {
    outputs.contains { output in
        output.portType != .builtInSpeaker && output.portType != .builtInReceiver
    }
}

enum SiriPlaybackExecutionGate {
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

    /// Returns true if any Siri playback execution is currently in-flight.
    static var isExecuting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inFlightSignatures.isEmpty
    }

    private static func pruneExpiredEntries(now: Date) {
        lastExecutionDates = lastExecutionDates.filter { now.timeIntervalSince($0.value) <= duplicateWindow }
    }
}

// MARK: - In-App Intent Handler

/// Handles INPlayMediaIntent when iOS routes it directly to the app (handleInApp path on iOS 18+)
final class InAppPlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        AppLogger.info("SIRI_APP: InAppPlayMediaIntentHandler.handle() called")

        guard let payload = payload(from: intent) else {
            AppLogger.error("SIRI_APP: InAppPlayMediaIntentHandler - failed to decode payload/query from intent")
            completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
            return
        }

        AppLogger.info(
            "SIRI_APP: InAppPlayMediaIntentHandler - accepted payload kind=\(payload.kind.rawValue) entity=\(payload.entityID)"
        )

        // Return .success immediately so Siri doesn't time out during cold
        // launch. On a fresh start the server health checks + playback setup
        // can take 5-8 seconds, which exceeds Siri's ~8 second timeout.
        // The extension already established the AirPlay route via .handleInApp,
        // so we just need to acknowledge the intent quickly and start playback
        // in the background.
        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))

        executeSiriPlaybackInBackground(
            payload: payload,
            origin: "inAppIntentHandler",
            intentCompletion: nil
        )
    }

    private func payload(from intent: INPlayMediaIntent) -> SiriPlaybackRequestPayload? {
        let rawIdentifier = normalizedIntentIdentifier(from: intent)
        let shuffle = intent.playShuffled

        if let identifier = rawIdentifier,
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

        if let query = queryText(from: intent), !query.isEmpty {
            let sanitizedQuery = normalizedSiriQuery(query)
            guard !sanitizedQuery.isEmpty else {
                return nil
            }

            AppLogger.info("SIRI_APP: InAppPlayMediaIntentHandler - using fallback query: \(sanitizedQuery)")
            let kind = mediaKindFrom(intent: intent, fallbackQuery: query)
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: sanitizedQuery,
                sourceCompositeKey: nil,
                displayName: sanitizedQuery,
                artistHint: intent.mediaSearch?.artistName,
                shuffle: shuffle
            )
        }

        if let rawIdentifier {
            AppLogger.info("SIRI_APP: InAppPlayMediaIntentHandler - using raw identifier fallback")
            let kind = mediaKindFrom(intent: intent, fallbackQuery: nil)
            return SiriPlaybackRequestPayload(
                kind: kind,
                entityID: rawIdentifier,
                sourceCompositeKey: nil,
                displayName: intent.mediaItems?.first?.title ?? intent.mediaContainer?.title ?? rawIdentifier,
                artistHint: intent.mediaSearch?.artistName,
                shuffle: shuffle
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
            let hasMediaName = intent.mediaSearch?.mediaName.map { !$0.isEmpty } ?? false
            if let artistName = intent.mediaSearch?.artistName, !artistName.isEmpty, !hasMediaName { return .artist }
            if let albumName = intent.mediaSearch?.albumName, !albumName.isEmpty, !hasMediaName { return .album }
            if intent.mediaContainer?.type == .playlist { return .playlist }
            if let inferred = inferredSiriMediaKind(from: fallbackQuery) { return inferred }
            return .track
        }
    }

    private func normalizedSiriQuery(_ value: String) -> String {
        SiriPhraseNormalizer.normalized(value)
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
