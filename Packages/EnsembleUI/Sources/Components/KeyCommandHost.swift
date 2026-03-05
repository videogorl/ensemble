import EnsembleCore
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Invisible UIViewControllerRepresentable that injects hardware keyboard
/// shortcuts into the responder chain. Installed once at the root so
/// commands work everywhere except when a text field is focused.
struct KeyCommandHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyCommandViewController {
        KeyCommandViewController()
    }

    func updateUIViewController(_ uiViewController: KeyCommandViewController, context: Context) {}
}

final class KeyCommandViewController: UIViewController {
    private let playbackService = DependencyContainer.shared.playbackService

    override var keyCommands: [UIKeyCommand]? {
        // Space bar (no modifiers) to toggle play/pause
        let spaceCommand = UIKeyCommand(
            input: " ",
            modifierFlags: [],
            action: #selector(handleSpaceBar)
        )
        spaceCommand.discoverabilityTitle = "Play / Pause"
        return [spaceCommand]
    }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func handleSpaceBar() {
        // Don't interfere if a text input is currently focused
        guard !isTextInputActive else { return }

        switch playbackService.playbackState {
        case .playing:
            playbackService.pause()
        case .paused:
            playbackService.resume()
        default:
            break
        }
    }

    /// Returns true when the current first responder is a text input (UITextField, UITextView, UISearchBar)
    private var isTextInputActive: Bool {
        guard let responder = UIResponder.findFirstResponder() else { return false }
        return responder is UITextField
            || responder is UITextView
            || responder is UISearchBar
    }
}

// MARK: - First Responder Discovery

private extension UIResponder {
    /// Walks the responder chain to find the current first responder.
    static weak var currentFirstResponder: UIResponder?

    /// Temporarily sets `currentFirstResponder` by sending a no-op action through the chain.
    static func findFirstResponder() -> UIResponder? {
        currentFirstResponder = nil
        UIApplication.shared.sendAction(#selector(trapFirstResponder(_:)), to: nil, from: nil, for: nil)
        return currentFirstResponder
    }

    @objc private func trapFirstResponder(_ sender: Any) {
        UIResponder.currentFirstResponder = self
    }
}
#endif
