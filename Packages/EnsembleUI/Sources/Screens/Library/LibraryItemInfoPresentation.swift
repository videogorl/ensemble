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
                LibraryItemInfoSourcePicker(request: request)
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

private struct LibraryItemInfoSourcePicker: View {
    let request: LibraryItemInfoRequest
    @State private var selectedSourceID: String?
    @Environment(\.dependencies) private var deps

    var body: some View {
        if case .playlist(let primary, let sources) = request, sources.count > 1 {
            let selected = sources.first { $0.sourceScopedID == selectedSourceID } ?? primary
            VStack(spacing: 0) {
                Picker("Source", selection: Binding(
                    get: { selected.sourceScopedID },
                    set: { selectedSourceID = $0 }
                )) {
                    ForEach(sources, id: \.sourceScopedID) { playlist in
                        Text(sourceName(playlist)).tag(playlist.sourceScopedID)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .accessibilityIdentifier("info.sources")
                LibraryItemInfoView(request: .playlist(selected))
                    .id(selected.sourceScopedID)
            }
        } else {
            LibraryItemInfoView(request: request)
        }
    }

    private func sourceName(_ playlist: Playlist) -> String {
        guard let source = deps.accountManager.sourcePresentation(for: playlist.sourceCompositeKey) else {
            return "Unknown source"
        }
        return DemoModeRedaction.serverName(source.serverName, isEnabled: deps.settingsManager.demoModeEnabled)
            + " · " + source.libraryName
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
            LibraryItemInfoSourcePicker(request: request)
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
