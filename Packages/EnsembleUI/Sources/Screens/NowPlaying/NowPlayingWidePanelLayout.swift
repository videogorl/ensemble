import EnsembleCore
import SwiftUI

/// Shared iPad-style Now Playing layout with controls on the left and a selected detail panel on the right.
struct NowPlayingWidePanelLayout: View {
    let viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    private let dismissAction: (() -> Void)?
    private let topPadding: CGFloat?
    private let maxContentWidth: CGFloat
    private let maxContentHeight: CGFloat?
    private let headerLeadingPadding: CGFloat
    private let headerTrailingPadding: CGFloat
    private let showsTrackHeader: Bool
    private let keepsQueueAlwaysVisible: Bool
    private let showsLyricsTransportControls: Bool
    private let centersContentInAvailableSpace: Bool
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        dismissAction: (() -> Void)? = nil,
        topPadding: CGFloat? = nil,
        maxContentWidth: CGFloat = EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth,
        maxContentHeight: CGFloat? = nil,
        headerLeadingPadding: CGFloat = 0,
        headerTrailingPadding: CGFloat = 0,
        showsTrackHeader: Bool = true,
        keepsQueueAlwaysVisible: Bool = false,
        showsLyricsTransportControls: Bool = true,
        centersContentInAvailableSpace: Bool = false
    ) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.dismissAction = dismissAction
        self.topPadding = topPadding
        self.maxContentWidth = maxContentWidth
        self.maxContentHeight = maxContentHeight
        self.headerLeadingPadding = headerLeadingPadding
        self.headerTrailingPadding = headerTrailingPadding
        self.showsTrackHeader = showsTrackHeader
        self.keepsQueueAlwaysVisible = keepsQueueAlwaysVisible
        self.showsLyricsTransportControls = showsLyricsTransportControls
        self.centersContentInAvailableSpace = centersContentInAvailableSpace
        self._playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
    }

    var body: some View {
        GeometryReader { geometry in
            if centersContentInAvailableSpace {
                content(for: geometry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                content(for: geometry)
            }
        }
    }

    private func content(for geometry: GeometryProxy) -> some View {
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
        .frame(maxWidth: maxContentWidth, maxHeight: maxContentHeight)
        .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
        .padding(.top, topPadding ?? max(geometry.safeAreaInsets.top, EnsembleDesign.Spacing.sm))
        .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.NowPlaying.sectionTopPadding) {
            if showsTrackHeader {
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
            } else {
                Spacer()
            }

            Picker("Panel", selection: panelSelection) {
                Text("Queue").tag(NowPlayingPanelPage.queue.rawValue)
                Text("Lyrics").tag(NowPlayingPanelPage.lyrics.rawValue)
                Text("Info").tag(NowPlayingPanelPage.info.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: EnsembleScaffold.NowPlaying.viewportPickerWidth)

            if let dismissAction {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: EnsembleDesign.Icon.closeCircle)
                        .font(.system(size: EnsembleDesign.Spacing.xl))
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: maxContentWidth)
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, headerTrailingPadding)
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

    private var detailPanel: some View {
        NowPlayingDetailPanel(
            viewModel: viewModel,
            currentPage: $currentPage,
            isLowPowerMode: powerStateMonitor.isLowPowerMode,
            showsLyricsTransportControls: showsLyricsTransportControls,
            keepsQueueAlwaysVisible: keepsQueueAlwaysVisible
        )
    }

    private func panelWidth(for geometry: GeometryProxy) -> CGFloat {
        let available = min(
            geometry.size.width - (EnsembleScaffold.NowPlaying.viewportContentPadding * 2),
            maxContentWidth
        )
        return max((available - EnsembleScaffold.NowPlaying.viewportInnerSpacing) / 2, 0)
    }
}
