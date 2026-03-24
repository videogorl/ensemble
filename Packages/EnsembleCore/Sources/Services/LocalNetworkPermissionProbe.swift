import Foundation
import Network

/// Triggers the iOS local network permission dialog by briefly browsing
/// for Bonjour services. Call this before any flow that probes local server
/// endpoints so the user sees the permission prompt up-front rather than
/// having connections silently fail.
///
/// The probe is best-effort: if the dialog was already shown (granted or
/// denied), the browse completes immediately with no visible prompt.
public enum LocalNetworkPermissionProbe {
    /// Key used to track whether the probe has already run this app install.
    private static let hasPromptedKey = "localNetworkPermissionPrompted"

    /// Whether the permission prompt has already been triggered (this install or a previous launch).
    public static var hasPrompted: Bool {
        UserDefaults.standard.bool(forKey: hasPromptedKey)
    }

    /// Trigger a brief Bonjour browse for `_plex._tcp` to surface the local
    /// network permission dialog. Returns once the browse has started (the
    /// dialog will appear independently). Safe to call multiple times — only
    /// the first call per app install performs the actual browse.
    public static func promptIfNeeded() async {
        guard !hasPrompted else { return }
        UserDefaults.standard.set(true, forKey: hasPromptedKey)

        // Browse for a short duration to trigger the system dialog.
        // The dialog appears asynchronously; we just need the browse to start.
        let browser = NWBrowser(
            for: .bonjour(type: "_plex._tcp", domain: nil),
            using: .tcp
        )

        // Use an actor to safely coordinate the one-shot continuation resume
        // across the NWBrowser callback queue and the timeout dispatch.
        let gate = ResumeGate()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    // Browse started (or failed) — permission dialog triggered
                    Task { await gate.resumeOnce(continuation) }
                default:
                    break
                }
            }

            browser.start(queue: .global(qos: .userInitiated))

            // Safety timeout so we never block the UI indefinitely
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                Task {
                    await gate.resumeOnce(continuation)
                    browser.cancel()
                }
            }
        }
    }
}

/// Actor that ensures a continuation is resumed exactly once.
private actor ResumeGate {
    private var hasResumed = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Never>) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume()
    }
}
