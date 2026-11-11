import EnsembleCore
import SwiftUI

/// Noninteractive Now Playing view for a supplementary external display.
///
/// This wraps the same wide Now Playing layout used by iPad, adapted for TV display:
/// - Panel selection follows `viewModel.currentPage` from the device automatically
/// - Forces dark color scheme (better for TV viewing)
/// - When nothing is playing, the existing `ControlsCard.emptyStateView` handles the idle state
///
/// The view shares the same `NowPlayingViewModel` instance as the main UI so playback,
/// lyrics, queue, and panel selection stay in sync with zero duplicate work.
public struct ExternalDisplayNowPlayingView: View {
    @Bindable var viewModel: NowPlayingViewModel
    @Environment(DependencyContainer.self) private var dependencies
    private var settingsManager: SettingsManager { dependencies.settingsManager }
    // This view is the root of its own scene (a mirrored or supplementary display) and inherits no
    // environment. The Now Playing cards and their menus read both of these; a missing one traps.
    @State private var sourceActionPresenter = MediaSourceActionPresenter()

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            // A TV or mirrored display reports its pixels as points (2560x1440 at 1x), so a layout drawn
            // at its natural size is tiny. Lay the cards out at the size they are designed for and scale
            // that up to fill the display's height or width, whichever is reached first.
            let reference = CGSize(
                width: EnsembleScaffold.NowPlaying.viewportContentMaxWidth,
                height: EnsembleScaffold.NowPlaying.viewportContentMaxHeight
            )
            let scale = max(1, min(geometry.size.width / reference.width, geometry.size.height / reference.height))

            ZStack {
                NowPlayingBackdrop(
                    viewModel: viewModel,
                    consumer: .externalDisplay,
                    activeContentMaxWidth: nil,
                    forceDarkPresentation: true
                )

                NowPlayingWidePanelLayout(
                    viewModel: viewModel,
                    currentPage: $viewModel.currentPage,
                    maxContentWidth: reference.width,
                    maxContentHeight: reference.height,
                    centersContentInAvailableSpace: true
                )
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .ignoresSafeArea()
        .environment(dependencies.navigationCoordinator)
        .environment(sourceActionPresenter)
        .accentColor(settingsManager.accentColor.color)
        .preferredColorScheme(.dark)
    }
}
