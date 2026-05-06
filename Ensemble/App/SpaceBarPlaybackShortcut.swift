#if os(iOS)
import GameController
import UIKit
import EnsembleCore

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
