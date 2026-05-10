import EnsembleCore
import SwiftUI

/// Shared artwork/aurora backdrop for large Now Playing surfaces.
struct NowPlayingBackdrop: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let consumer: VisualizationConsumer
    let activeContentMaxWidth: CGFloat?
    let forceDarkPresentation: Bool

    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            baseBackgroundColor
                .ignoresSafeArea()

            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                preBlurredImage: viewModel.blurredArtworkImage,
                overlayColor: overlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            readabilityOverlay
                .allowsHitTesting(false)

            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    consumer: consumer,
                    accentColor: settingsManager.accentColor.color,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode,
                    activeContentMaxWidth: activeContentMaxWidth
                )
                .allowsHitTesting(false)
                .opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
            }
        }
        .ignoresSafeArea()
    }

    private var usesDarkPresentation: Bool {
        forceDarkPresentation || colorScheme == .dark
    }

    private var baseBackgroundColor: Color {
        usesDarkPresentation ? .black : platformBackgroundColor
    }

    private var overlayColor: Color {
        usesDarkPresentation ? .black : platformBackgroundColor
    }

    @ViewBuilder
    private var readabilityOverlay: some View {
        if usesDarkPresentation {
            Color.black.opacity(EnsembleScaffold.NowPlaying.backgroundDarkOverlayOpacity)
        } else {
            platformBackgroundColor.opacity(EnsembleScaffold.NowPlaying.backgroundLightOverlayOpacity)
        }
    }

    private var platformBackgroundColor: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return .white
        #endif
    }
}

/// Dedicated large-screen Now Playing presentation surface used by macOS.
/// This owns the viewport layout while leaving window chrome to the root scene.
struct NowPlayingViewportRoot: View {
    private enum LayoutMode {
        case singlePanel
        case dualPanel
    }

    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

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
                NowPlayingBackdrop(
                    viewModel: viewModel,
                    consumer: .nowPlayingViewport,
                    activeContentMaxWidth: auroraActiveContentMaxWidth,
                    forceDarkPresentation: false
                )

                let mode = layoutMode(for: geometry)
                if mode == .dualPanel {
                    NowPlayingWidePanelLayout(
                        viewModel: viewModel,
                        currentPage: $viewModel.currentPage,
                        dismissAction: dismissAction,
                        topPadding: topInset(for: geometry),
                        maxContentWidth: contentMaxWidth,
                        maxContentHeight: contentMaxHeight,
                        headerLeadingPadding: leadingSystemChromeInset(for: geometry),
                        headerTrailingPadding: EnsembleScaffold.NowPlaying.viewportNarrowTrailingPadding,
                        showsTrackHeader: false,
                        keepsQueueAlwaysVisible: true,
                        showsLyricsTransportControls: false
                    )
                } else {
                    VStack(spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                        header(for: geometry, mode: mode)
                        singlePanel
                            .frame(width: singlePanelWidth(for: geometry))
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: contentMaxWidth, maxHeight: contentMaxHeight)
                    .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
                    .padding(.top, topInset(for: geometry))
                    .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
                }
            }
        }
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
    private var singlePanel: some View {
        if viewModel.currentPage == 1 {
            ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else {
            NowPlayingDetailPanel(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        }
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
