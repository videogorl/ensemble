import EnsembleCore
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Installs hardware keyboard shortcuts at the application level by swizzling
/// the root hosting controller's `keyCommands`. This ensures space-bar
/// play/pause works from any screen without needing to be the first responder.
///
/// Installed once as a `.background()` modifier on RootView.
struct KeyCommandHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.isHidden = true
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        // Once we have a window, install key commands on the root VC
        DispatchQueue.main.async {
            guard let rootVC = vc.view.window?.rootViewController else { return }
            KeyCommandInjector.install(on: rootVC)
        }
    }
}

/// Swizzles `keyCommands` on the root hosting controller exactly once
/// so space-bar play/pause is available app-wide via the responder chain.
enum KeyCommandInjector {
    private static var installed = false

    static func install(on viewController: UIViewController) {
        guard !installed else { return }
        installed = true

        let originalClass: AnyClass = type(of: viewController)

        // Swizzle keyCommands getter to append our custom commands
        let originalSelector = #selector(getter: UIResponder.keyCommands)
        let swizzledSelector = #selector(UIViewController.ensemble_keyCommands)

        guard let originalMethod = class_getInstanceMethod(originalClass, originalSelector) else { return }

        // Add our method to the class first
        let swizzledImplementation: @convention(block) (UIViewController) -> [UIKeyCommand]? = { vc in
            // Call through to the original implementation
            let original = vc.ensemble_keyCommands() ?? []

            let spaceCommand = UIKeyCommand(
                input: " ",
                modifierFlags: [],
                action: #selector(UIViewController.ensemble_handleSpaceBar)
            )
            spaceCommand.discoverabilityTitle = "Play / Pause"

            return original + [spaceCommand]
        }

        let swizzledIMP = imp_implementationWithBlock(swizzledImplementation)
        let typeEncoding = method_getTypeEncoding(originalMethod)

        // Add the swizzled method, then exchange
        class_addMethod(originalClass, swizzledSelector, swizzledIMP, typeEncoding)

        if let addedMethod = class_getInstanceMethod(originalClass, swizzledSelector) {
            method_exchangeImplementations(originalMethod, addedMethod)
        }

        // Also add the handler method
        let handlerBlock: @convention(block) (UIViewController) -> Void = { _ in
            // Don't interfere if a text input is focused
            guard !KeyCommandInjector.isTextInputActive else { return }

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

        let handlerIMP = imp_implementationWithBlock(handlerBlock)
        class_addMethod(
            originalClass,
            #selector(UIViewController.ensemble_handleSpaceBar),
            handlerIMP,
            "v@:"
        )
    }

    /// Checks whether the current first responder is a text input
    static var isTextInputActive: Bool {
        _currentFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.ensemble_trapFirstResponder(_:)),
            to: nil, from: nil, for: nil
        )
        guard let responder = _currentFirstResponder else { return false }
        return responder is UITextField
            || responder is UITextView
            || responder is UISearchBar
    }

    fileprivate static weak var _currentFirstResponder: UIResponder?
}

// MARK: - Selector stubs (never called directly — implementations injected at runtime)

private extension UIViewController {
    /// Placeholder for the swizzled keyCommands — after swizzle this calls the original
    @objc func ensemble_keyCommands() -> [UIKeyCommand]? { nil }
    /// Placeholder for the space-bar handler
    @objc func ensemble_handleSpaceBar() {}
}

extension UIResponder {
    /// Captures the current first responder when sent via UIApplication.sendAction
    @objc func ensemble_trapFirstResponder(_ sender: Any) {
        KeyCommandInjector._currentFirstResponder = self
    }
}
#endif
