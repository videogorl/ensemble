import EnsembleCore
import SwiftUI

/// Shared iPad-style Now Playing layout with controls on the left and a selected detail panel on the right.
struct NowPlayingWidePanelLayout: View {
    let viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self._playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                header

                HStack(alignment: .top, spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                    ControlsCard(viewModel: viewModel, currentPage: $currentPage, isAlwaysVisible: true)
                        .frame(width: panelWidth(for: geometry))
                        .frame(maxHeight: .infinity, alignment: .topLeading)

                    detailPanel
                        .frame(width: panelWidth(for: geometry))
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
            .padding(.top, max(geometry.safeAreaInsets.top, EnsembleDesign.Spacing.sm))
            .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.NowPlaying.sectionTopPadding) {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                Text(playbackProjection.currentTrack?.title ?? "Now Playing")
                    .font(EnsembleDesign.Typography.detailSubtitle.weight(.semibold))
                    .lineLimit(1)

                if let artist = playbackProjection.currentTrack?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Picker("Panel", selection: panelSelection) {
                Text("Queue").tag(NowPlayingPanelPage.queue.rawValue)
                Text("Lyrics").tag(NowPlayingPanelPage.lyrics.rawValue)
                Text("Info").tag(NowPlayingPanelPage.info.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: EnsembleScaffold.NowPlaying.viewportPickerWidth)
        }
        .frame(maxWidth: EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth)
    }

    private var panelSelection: Binding<Int> {
        Binding(
            get: {
                if currentPage == NowPlayingPanelPage.info.rawValue {
                    return NowPlayingPanelPage.info.rawValue
                }
                if currentPage == NowPlayingPanelPage.lyrics.rawValue {
                    return NowPlayingPanelPage.lyrics.rawValue
                }
                return NowPlayingPanelPage.queue.rawValue
            },
            set: { newValue in
                currentPage = newValue
            }
        )
    }

    @ViewBuilder
    private var detailPanel: some View {
        if currentPage == NowPlayingPanelPage.info.rawValue {
            InfoCard(viewModel: viewModel, currentPage: $currentPage)
        } else if currentPage == NowPlayingPanelPage.lyrics.rawValue {
            LyricsCard(
                viewModel: viewModel,
                currentPage: $currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: $currentPage)
        }
    }

    private func panelWidth(for geometry: GeometryProxy) -> CGFloat {
        let available = min(
            geometry.size.width - (EnsembleScaffold.NowPlaying.viewportContentPadding * 2),
            EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth
        )
        return max((available - EnsembleScaffold.NowPlaying.viewportInnerSpacing) / 2, 0)
    }
}
