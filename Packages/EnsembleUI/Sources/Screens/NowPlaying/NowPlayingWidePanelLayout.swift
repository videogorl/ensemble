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
    private let centersContentInAvailableSpace: Bool
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
        self.centersContentInAvailableSpace = centersContentInAvailableSpace
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
                NowPlayingPanelCard(
                    page: .controls,
                    viewModel: viewModel,
                    currentPage: $currentPage,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode,
                    isAlwaysVisible: true
                )
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
            Spacer()

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
                NowPlayingPanelPage.detailPage(for: currentPage).rawValue
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
            showsLyricsTransportControls: false,
            keepsQueueAlwaysVisible: true
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
