import EnsembleCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

private struct LibraryItemInfoPresentationModifier: ViewModifier {
    @Binding var request: LibraryItemInfoRequest?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onChange(of: request) { newRequest in
                guard let newRequest else { return }
                MacLibraryItemInfoWindowPresenter.shared.present(newRequest)
                request = nil
            }
        #else
        content
            .sheet(item: $request) { request in
                LibraryItemInfoView(request: request)
                    .nativeSheetNavigationContainer()
            }
        #endif
    }
}

public extension View {
    /// Presents the library Get Info panel using the platform-native surface.
    func libraryItemInfoPresentation(request: Binding<LibraryItemInfoRequest?>) -> some View {
        modifier(LibraryItemInfoPresentationModifier(request: request))
    }
}

#if os(macOS)
@MainActor
private final class MacLibraryItemInfoWindowPresenter {
    static let shared = MacLibraryItemInfoWindowPresenter()

    private var window: NSWindow?

    func present(_ request: LibraryItemInfoRequest) {
        let rootView = MacAuxiliaryWindowScaffold(
            configuration: EnsembleScaffold.AuxiliaryWindow.Configuration(
                minHeight: 460,
                idealHeight: 560
            )
        ) {
            LibraryItemInfoView(request: request)
        }
        .environment(\.dependencies, DependencyContainer.shared)
        .accentColor(DependencyContainer.shared.settingsManager.accentColor.color)

        if let window {
            window.contentViewController = NSHostingController(rootView: rootView)
            window.title = "Get Info"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Get Info"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 420, height: 560))
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }
}
#endif
