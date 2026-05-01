import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Presents a system share sheet with the given items.
/// Uses imperative presentation via the topmost window scene rather than .sheet(item:)
/// because context menus dismiss before callbacks fire, making SwiftUI sheet binding unreliable.
public enum ShareSheetPresenter {

    /// Present a share sheet with the given activity items.
    /// - Parameters:
    ///   - items: Items to share (URLs, strings, etc.)
    ///   - completion: Called after the share sheet is dismissed
    public static func present(items: [Any], completion: (() -> Void)? = nil) {
        #if os(iOS)
        presentIOS(items: items, completion: completion)
        #elseif os(macOS)
        presentMacOS(items: items, completion: completion)
        #endif
    }

    #if os(iOS)
    private static func presentIOS(items: [Any], completion: (() -> Void)?) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

        activityVC.completionWithItemsHandler = { _, _, _, _ in
            completion?()
        }

        // Find the topmost presented view controller
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            completion?()
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // iPad requires a sourceView for popover presentation
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }

        topVC.present(activityVC, animated: true)
    }
    #endif

    #if os(macOS)
    private static func presentMacOS(items: [Any], completion: (() -> Void)?) {
        guard let window = NSApplication.shared.keyWindow,
              let contentView = window.contentView else {
            completion?()
            return
        }

        let picker = NSSharingServicePicker(items: items)
        // Present from center of the window
        let rect = CGRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.midY,
            width: 1, height: 1
        )
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        completion?()
    }
    #endif
}
