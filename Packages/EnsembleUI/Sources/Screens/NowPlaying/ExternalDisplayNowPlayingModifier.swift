import EnsembleCore
import SwiftUI

/// Offers the root scene's shared Now Playing model to supplementary displays.
@MainActor
struct ExternalDisplayNowPlayingModifier: ViewModifier {
    let viewModel: NowPlayingViewModel
    @Environment(\.dependencies) private var dependencies

    #if os(iOS)
    // Each main window owns a model. Keep the timing flag until its last
    // presented accessory disappears, including during window handoffs.
    private static var presentedModels: Set<ObjectIdentifier> = []
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            content.sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalDisplayNowPlayingView(viewModel: viewModel)
                        .environment(\.dependencies, dependencies)
                        .onAppear { updatePresentation(isPresented: true) }
                        .onDisappear { updatePresentation(isPresented: false) }
                }
                .onAvailabilityChange { isAvailable in
                    // Scene removal does not always deliver content.onDisappear.
                    if !isAvailable {
                        updatePresentation(isPresented: false)
                    }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    private func updatePresentation(isPresented: Bool) {
        let modelID = ObjectIdentifier(viewModel)
        if isPresented {
            guard Self.presentedModels.insert(modelID).inserted else { return }
        } else {
            guard Self.presentedModels.remove(modelID) != nil else { return }
        }
        dependencies.playbackService.isScreenMirroringActive = !Self.presentedModels.isEmpty
        EnsembleLogger.debug(
            "[ExternalDisplay] SwiftUI accessory presented=\(isPresented)"
                + " | activePresentations=\(Self.presentedModels.count)"
        )
    }
    #endif
}
