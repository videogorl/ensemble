import EnsembleCore
import SwiftUI

/// Non-interactive Now Playing view shown on an external display via AirPlay screen mirroring.
///
/// This wraps the same wide Now Playing layout used by iPad, adapted for TV display:
/// - Panel selection follows `viewModel.currentPage` from the device automatically
/// - Forces dark color scheme (better for TV viewing)
/// - When nothing is playing, the existing `ControlsCard.emptyStateView` handles the idle state
///
/// The view shares the same `NowPlayingViewModel` instance as the main UI so playback,
/// lyrics, queue, and panel selection stay in sync with zero duplicate work.
public struct ExternalDisplayNowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            NowPlayingBackdrop(
                viewModel: viewModel,
                consumer: .externalDisplay,
                activeContentMaxWidth: EnsembleScaffold.NowPlaying.viewportContentMaxWidth,
                forceDarkPresentation: true
            )

            NowPlayingWidePanelLayout(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                centersContentInAvailableSpace: true
            )
        }
        .accentColor(settingsManager.accentColor.color)
        .preferredColorScheme(.dark)
    }
}
