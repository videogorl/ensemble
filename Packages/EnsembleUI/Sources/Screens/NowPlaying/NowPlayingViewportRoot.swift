import EnsembleDesignTokens
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

            readabilityOverlay
                .allowsHitTesting(false)

            if settingsManager.auroraVisualizationEnabled && viewModel.currentTrack?.sourceCapabilities.supportsWaveform != false {
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
    @ObservedObject private var queueProjection: NowPlayingQueueProjection

    private let dismissAction: () -> Void
    private var auroraActiveContentMaxWidth: CGFloat? {
        return EnsembleScaffold.NowPlaying.auroraActiveContentMaxWidth
    }

    init(
        viewModel: NowPlayingViewModel,
        dismissAction: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self._queueProjection = ObservedObject(wrappedValue: viewModel.queueProjection)
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
                        maxContentWidth: contentMaxWidth,
                        maxContentHeight: contentMaxHeight,
                        headerTrailingPadding: EnsembleScaffold.NowPlaying.viewportNarrowTrailingPadding,
                        centersContentInAvailableSpace: true
                    )
                } else {
                    VStack(spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                        header
                        singlePanel
                            .frame(width: singlePanelWidth(for: geometry))
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: contentMaxWidth, maxHeight: contentMaxHeight)
                    .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
                    .padding(.top, max(geometry.safeAreaInsets.top, EnsembleDesign.Spacing.sm))
                    .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.NowPlaying.sectionTopPadding) {
            Spacer()

            NowPlayingPanelSelector(
                selection: panelSelection,
                options: NowPlayingPanelPage.allCases,
                showsHistory: queueProjection.showHistory,
                width: EnsembleScaffold.NowPlaying.viewportSinglePickerWidth
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
        .padding(.trailing, EnsembleScaffold.NowPlaying.viewportNarrowTrailingPadding)
    }

    private var panelSelection: Binding<Int> {
        Binding(
            get: {
                if viewModel.currentPage == 1 { return 1 }
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
        NowPlayingPanelCard(
            page: NowPlayingPanelPage(rawValue: viewModel.currentPage) ?? .queue,
            viewModel: viewModel,
            currentPage: $viewModel.currentPage,
            isLowPowerMode: powerStateMonitor.isLowPowerMode
        )
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
}
