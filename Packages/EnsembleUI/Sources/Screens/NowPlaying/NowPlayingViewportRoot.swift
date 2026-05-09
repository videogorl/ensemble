import EnsembleCore
import SwiftUI

/// Dedicated large-screen Now Playing presentation surface used by macOS.
/// This owns the viewport layout while leaving window chrome to the root scene.
struct NowPlayingViewportRoot: View {
    private enum LayoutMode {
        case singlePanel
        case dualPanel
    }

    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.colorScheme) private var colorScheme

    private let dismissAction: () -> Void
    private var auroraActiveContentMaxWidth: CGFloat? {
        return EnsembleScaffold.NowPlaying.auroraActiveContentMaxWidth
    }

    init(
        viewModel: NowPlayingViewModel,
        dismissAction: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.dismissAction = dismissAction
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                let mode = layoutMode(for: geometry)
                VStack(spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                    header(for: geometry, mode: mode)

                    if mode == .dualPanel {
                        HStack(alignment: .top, spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                            ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage, isAlwaysVisible: true)
                                .frame(width: panelWidth(for: geometry))
                                .frame(maxHeight: .infinity, alignment: .topLeading)

                            detailPanel
                                .frame(width: panelWidth(for: geometry))
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    } else {
                        singlePanel
                            .frame(width: singlePanelWidth(for: geometry))
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: contentMaxWidth, maxHeight: contentMaxHeight)
                .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
                .padding(.top, topInset(for: geometry))
                .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
            }
        }
    }

    private var backgroundView: some View {
        let lightOverlayColor: Color = {
            #if os(iOS)
            return Color(uiColor: .systemBackground)
            #elseif os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return .white
            #endif
        }()

        let baseBackgroundColor = colorScheme == .dark ? Color.black : lightOverlayColor

        return ZStack {
            baseBackgroundColor
                .ignoresSafeArea()

            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                preBlurredImage: viewModel.blurredArtworkImage,
                overlayColor: colorScheme == .dark ? .black : lightOverlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            if colorScheme == .dark {
                Color.black.opacity(EnsembleScaffold.NowPlaying.backgroundDarkOverlayOpacity)
                    .allowsHitTesting(false)
            } else {
                lightOverlayColor.opacity(EnsembleScaffold.NowPlaying.backgroundLightOverlayOpacity)
                    .allowsHitTesting(false)
            }

            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    consumer: .nowPlayingViewport,
                    accentColor: settingsManager.accentColor.color,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode,
                    activeContentMaxWidth: auroraActiveContentMaxWidth
                )
                .allowsHitTesting(false)
                .opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
            }
        }
        .ignoresSafeArea()
    }

    private func header(for geometry: GeometryProxy, mode: LayoutMode) -> some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.NowPlaying.sectionTopPadding) {
            Spacer()

            Picker("Panel", selection: panelSelection(for: mode)) {
                Text("Queue").tag(0)
                if mode == .singlePanel {
                    Text("Controls").tag(1)
                }
                Text("Lyrics").tag(2)
                Text("Info").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: mode == .singlePanel
                ? EnsembleScaffold.NowPlaying.viewportSinglePickerWidth
                : EnsembleScaffold.NowPlaying.viewportPickerWidth
            )

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
        .frame(maxWidth: EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth)
        .padding(.leading, leadingSystemChromeInset(for: geometry))
        .padding(.trailing, EnsembleScaffold.NowPlaying.viewportNarrowTrailingPadding)
    }

    private func panelSelection(for mode: LayoutMode) -> Binding<Int> {
        Binding(
            get: {
                if mode == .singlePanel && viewModel.currentPage == 1 { return 1 }
                if viewModel.currentPage == 3 { return 3 }
                if viewModel.currentPage == 2 { return 2 }
                return 0
            },
            set: { newValue in
                viewModel.currentPage = newValue
            }
        )
    }

    @ViewBuilder
    private var detailPanel: some View {
        if viewModel.currentPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else if viewModel.currentPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode,
                showsTransportControls: false
            )
        } else {
            QueueCard(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isAlwaysVisible: true
            )
        }
    }

    @ViewBuilder
    private var singlePanel: some View {
        if viewModel.currentPage == 1 {
            ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else if viewModel.currentPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else if viewModel.currentPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode,
                showsTransportControls: true
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        }
    }

    /// Equal panel width for the two-column layout (controls + detail).
    /// Computed from geometry so both sides are always exactly the same width.
    private func panelWidth(for geometry: GeometryProxy) -> CGFloat {
        let horizontalPadding = EnsembleScaffold.NowPlaying.viewportContentPadding * 2
        let available = min(geometry.size.width - horizontalPadding, contentMaxWidth)
        return max((available - EnsembleScaffold.NowPlaying.viewportInnerSpacing) / 2, 0)
    }

    private func singlePanelWidth(for geometry: GeometryProxy) -> CGFloat {
        min(
            max(geometry.size.width - (EnsembleScaffold.NowPlaying.viewportContentPadding * 2), 0),
            EnsembleScaffold.NowPlaying.viewportSinglePanelMaxWidth
        )
    }

    private func layoutMode(for geometry: GeometryProxy) -> LayoutMode {
        let widthAllowsDual = geometry.size.width >= EnsembleScaffold.NowPlaying.viewportDualPanelMinimumWidth
        let heightAllowsDual = geometry.size.height >= EnsembleScaffold.NowPlaying.viewportDualPanelMinimumHeight
        return widthAllowsDual && heightAllowsDual ? .dualPanel : .singlePanel
    }

    private var contentMaxWidth: CGFloat { EnsembleScaffold.NowPlaying.viewportContentMaxWidth }

    private var contentMaxHeight: CGFloat { EnsembleScaffold.NowPlaying.viewportContentMaxHeight }

    private func topInset(for geometry: GeometryProxy) -> CGFloat {
        return max(
            geometry.safeAreaInsets.top + EnsembleScaffold.NowPlaying.viewportMacTopSafeAreaPadding,
            EnsembleScaffold.NowPlaying.viewportMacMinimumTopInset
        )
    }

    private func leadingSystemChromeInset(for geometry: GeometryProxy) -> CGFloat {
        return max(geometry.safeAreaInsets.leading + trafficLightClearance, trafficLightClearance)
    }

    private var trafficLightClearance: CGFloat {
        return EnsembleScaffold.NowPlaying.viewportMacTrafficLightClearance
    }
}
