import EnsembleCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dedicated large-screen Now Playing presentation surface used by macOS and iPadOS.
/// This owns the viewport layout and hosts the narrow macOS toolbar suppression bridge
/// needed to keep split-view chrome out of the presentation.
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
        #if os(iOS)
        return nil
        #else
        return EnsembleScaffold.NowPlaying.auroraActiveContentMaxWidth
        #endif
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

                #if os(macOS)
                MacNowPlayingChromeCoordinatorBridge()
                    .frame(
                        width: EnsembleScaffold.NowPlaying.ToolbarSuppression.hostDimension,
                        height: EnsembleScaffold.NowPlaying.ToolbarSuppression.hostDimension
                    )
                #endif

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
        #if os(macOS)
        return max(
            geometry.safeAreaInsets.top + EnsembleScaffold.NowPlaying.viewportMacTopSafeAreaPadding,
            EnsembleScaffold.NowPlaying.viewportMacMinimumTopInset
        )
        #else
        if #available(iOS 26.0, *) {
            return max(
                geometry.safeAreaInsets.top + EnsembleScaffold.NowPlaying.viewportModernTopSafeAreaPadding,
                EnsembleScaffold.NowPlaying.viewportModernMinimumTopInset
            )
        }
        return max(
            geometry.safeAreaInsets.top + EnsembleScaffold.NowPlaying.viewportLegacyTopSafeAreaPadding,
            EnsembleScaffold.NowPlaying.viewportLegacyMinimumTopInset
        )
        #endif
    }

    private func leadingSystemChromeInset(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        return max(geometry.safeAreaInsets.leading + trafficLightClearance, trafficLightClearance)
        #else
        if #available(iOS 26.0, *) {
            return max(geometry.safeAreaInsets.leading + trafficLightClearance, trafficLightClearance)
        }
        return EnsembleScaffold.NowPlaying.viewportLegacyChromeInset
        #endif
    }

    private var trafficLightClearance: CGFloat {
        #if os(macOS)
        return EnsembleScaffold.NowPlaying.viewportMacTrafficLightClearance
        #else
        if #available(iOS 26.0, *) {
            return EnsembleScaffold.NowPlaying.viewportModernTrafficLightClearance
        }
        return EnsembleScaffold.NowPlaying.viewportLegacyChromeInset
        #endif
    }
}

#if os(macOS)
/// Coordinates host window chrome while viewport Now Playing is active.
/// Stores and restores toolbar item visibility plus resize constraints owned
/// by the surrounding split-view shell.
private struct MacNowPlayingChromeCoordinatorBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.apply(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var previousHiddenStates: [(item: NSToolbarItem, hidden: Bool)] = []
        private var previousViewHiddenStates: [(item: NSToolbarItem, hidden: Bool)] = []
        private var previousContentMinSize: NSSize?
        private var previousContentMaxSize: NSSize?

        func apply(to window: NSWindow?) {
            guard let window else { return }

            if self.window !== window {
                restore()
                self.window = window
            }

            applyResizeConstraints(to: window)

            guard let toolbar = window.toolbar else { return }

            for item in toolbar.items {
                guard shouldHideToolbarItem(item) else {
                    continue
                }

                if #available(macOS 15.0, *) {
                    guard !previousHiddenStates.contains(where: { $0.item === item }) else {
                        continue
                    }
                    let previousHidden = item.isHidden
                    item.isHidden = true
                    previousHiddenStates.append((item, previousHidden))
                } else {
                    guard !previousViewHiddenStates.contains(where: { $0.item === item }) else {
                        continue
                    }
                    if let view = item.view {
                        let previousHidden = view.isHidden
                        view.isHidden = true
                        previousViewHiddenStates.append((item, previousHidden))
                    }
                }
            }
        }

        private func applyResizeConstraints(to window: NSWindow) {
            if previousContentMinSize == nil {
                previousContentMinSize = window.contentMinSize
                previousContentMaxSize = window.contentMaxSize
            }

            let nowPlayingMinSize = NSSize(
                width: EnsembleScaffold.NowPlaying.viewportMacMinimumWindowWidth,
                height: EnsembleScaffold.NowPlaying.viewportMacMinimumWindowHeight
            )
            if window.contentMinSize != nowPlayingMinSize {
                window.contentMinSize = nowPlayingMinSize
            }
        }

        private func shouldHideToolbarItem(_ item: NSToolbarItem) -> Bool {
            let identifier = item.itemIdentifier

            switch identifier {
            case .flexibleSpace, .space:
                return false
            default:
                return true
            }
        }

        func restore() {
            if let previousContentMinSize {
                window?.contentMinSize = previousContentMinSize
            }
            if let previousContentMaxSize {
                window?.contentMaxSize = previousContentMaxSize
            }
            previousContentMinSize = nil
            previousContentMaxSize = nil

            if #available(macOS 15.0, *) {
                for entry in previousHiddenStates {
                    entry.item.isHidden = entry.hidden
                }
                previousHiddenStates.removeAll()
            } else {
                for entry in previousViewHiddenStates {
                    entry.item.view?.isHidden = entry.hidden
                }
                previousViewHiddenStates.removeAll()
            }
            window = nil
        }
    }

    final class WindowObservationView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.apply(to: window)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.apply(to: window)
        }

        override func layout() {
            super.layout()
            coordinator?.apply(to: window)
        }
    }
}
#endif
