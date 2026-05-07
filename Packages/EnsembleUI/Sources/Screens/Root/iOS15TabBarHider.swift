#if os(iOS)
import SwiftUI
import UIKit

/// Hides the UITabBar on iOS 15 where .toolbar(_, for: .tabBar) is unavailable.
struct iOS15TabBarHider: UIViewRepresentable {
    let isHidden: Bool

    func makeUIView(context: Context) -> TabBarProbeView {
        let view = TabBarProbeView()
        view.targetHidden = isHidden
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: TabBarProbeView, context: Context) {
        view.targetHidden = isHidden
        view.applyTabBarVisibility()
    }

    final class TabBarProbeView: UIView {
        var targetHidden: Bool = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.applyTabBarVisibility()
            }
        }

        func applyTabBarVisibility() {
            guard let window,
                  let tabBarController = Self.findTabBarController(from: window.rootViewController) else {
                return
            }
            if tabBarController.tabBar.isHidden != targetHidden {
                tabBarController.tabBar.isHidden = targetHidden
            }
        }

        /// Recursively search the view controller hierarchy for SwiftUI's UITabBarController.
        private static func findTabBarController(from viewController: UIViewController?) -> UITabBarController? {
            guard let viewController else { return nil }
            if let tabBarController = viewController as? UITabBarController {
                return tabBarController
            }
            for child in viewController.children {
                if let found = findTabBarController(from: child) {
                    return found
                }
            }
            if let presented = viewController.presentedViewController {
                return findTabBarController(from: presented)
            }
            return nil
        }
    }
}
#endif
