import Foundation
#if !os(macOS)
import AVFoundation
#endif

/// Owns AVAudioSession configuration, activation helpers, and notification
/// observation so playback lifecycle policy is not split between AppDelegate and
/// PlaybackService.
final class PlaybackAudioSessionCoordinator {
    private let notificationCenter: NotificationCenter
    #if !os(macOS)
    private let sessionProvider: () -> AVAudioSession
    #endif
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var configuredMixing: Bool?

    #if !os(macOS)
    init(
        notificationCenter: NotificationCenter = .default,
        sessionProvider: @escaping () -> AVAudioSession = { AVAudioSession.sharedInstance() }
    ) {
        self.notificationCenter = notificationCenter
        self.sessionProvider = sessionProvider
    }
    #else
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }
    #endif

    func startObserving(
        onInterruption: @escaping @MainActor (Notification) -> Void,
        onRouteChange: @escaping @MainActor (Notification) -> Void
    ) {
        #if !os(macOS)
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                onInterruption(notification)
            }
        }

        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                onRouteChange(notification)
            }
        }
        #endif
    }

    func stopObserving() {
        if let interruptionObserver {
            notificationCenter.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            notificationCenter.removeObserver(routeChangeObserver)
        }
        interruptionObserver = nil
        routeChangeObserver = nil
    }

    @discardableResult
    func ensureConfigured(
        mixWithOthers: Bool = false,
        onConfigured: @escaping @MainActor () -> Void
    ) -> Bool {
        #if !os(macOS)
        let session = sessionProvider()
        let isCurrentConfiguration = session.category == .playback
            && session.mode == .default
            && session.categoryOptions.contains(.mixWithOthers) == mixWithOthers
            && (mixWithOthers || session.routeSharingPolicy == .longFormAudio)
        guard configuredMixing != mixWithOthers || !isCurrentConfiguration else { return true }

        do {
            if mixWithOthers {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            } else {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio,
                    options: []
                )
            }

            // Starting in iOS 17 / tvOS 17 / watchOS 10, AVAudioSession can ask
            // the system to surface route disconnects as interruptions. That
            // lines up better with Apple's documented coordination model and
            // reduces custom disconnect heuristics in PlaybackService.
            if #available(iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
                do {
                    try session.setPrefersInterruptionOnRouteDisconnect(true)
                    EnsembleLogger.debug("[AudioSession] prefersInterruptionOnRouteDisconnect enabled")
                } catch {
                    EnsembleLogger.debug("[AudioSession] prefersInterruptionOnRouteDisconnect failed: \(error)")
                }
            }

            configuredMixing = mixWithOthers
            Task { @MainActor in
                onConfigured()
            }
            EnsembleLogger.debug(
                "🔊 Audio session category configured (mixWithOthers=\(mixWithOthers), "
                    + "options=\(session.categoryOptions.rawValue), "
                    + "policy=\(session.routeSharingPolicy.rawValue), route=\(currentRouteDescription()))"
            )
            return true
        } catch {
            let nsError = error as NSError
            EnsembleLogger.debug(
                "⚠️ Audio session setCategory failed (domain=\(nsError.domain), code=\(nsError.code)): \(error)"
            )
            return false
        }
        #else
        return true
        #endif
    }

    func prepareRouteSelectionForPlayback() async -> Bool {
        #if !os(macOS)
        let session = sessionProvider()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            session.prepareRouteSelectionForPlayback { shouldActivate, routeSelection in
                EnsembleLogger.debug(
                    "[AudioSession] prepareRouteSelectionForPlayback shouldActivate=\(shouldActivate) route=\(routeSelection == .local ? "local" : "external")"
                )
                continuation.resume(returning: shouldActivate)
            }
        }
        #else
        return true
        #endif
    }

    @discardableResult
    func activateForPlayback(shouldStartPlayback: Bool) async -> Bool {
        #if !os(macOS)
        let session = sessionProvider()
        if shouldStartPlayback {
            do {
                try session.setActive(true)
                EnsembleLogger.debug("[AudioSession] Active route=\(currentRouteDescription())")
                return true
            } catch {
                let nsError = error as NSError
                EnsembleLogger.debug(
                    "⚠️ Audio session setActive failed; retrying once "
                        + "(domain=\(nsError.domain), code=\(nsError.code)): \(error)"
                )
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return false }
                do {
                    try session.setActive(true)
                    EnsembleLogger.debug("[AudioSession] Active after retry route=\(currentRouteDescription())")
                    return true
                } catch {
                    let nsError = error as NSError
                    EnsembleLogger.debug(
                        "⚠️ Audio session setActive failed after retry "
                            + "(domain=\(nsError.domain), code=\(nsError.code)): \(error)"
                    )
                    return false
                }
            }
        } else {
            do {
                try session.setActive(true)
                return true
            } catch {
                EnsembleLogger.debug("⚠️ Audio session setActive failed: \(error)")
                return false
            }
        }
        #else
        return true
        #endif
    }

    func currentRouteDescription() -> String {
        #if !os(macOS)
        sessionProvider().currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        #else
        return ""
        #endif
    }

    var isConfiguredForDiagnostics: Bool {
        configuredMixing != nil
    }
}
