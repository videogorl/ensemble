import EnsembleCore
import SwiftUI

/// Main sheet container for iPhone-style Now Playing presentation.
/// Large-screen viewport presentation lives in `NowPlayingViewportRoot`.
public struct NowPlayingSheetView: View {
    let viewModel: NowPlayingViewModel
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var artworkProjection: NowPlayingArtworkProjection
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var dismissDragOffset: CGFloat = 0
    @State private var currentPage: Int

    private let namespace: Namespace.ID?
    private let animationID: String?
    private let dismissAction: (() -> Void)?
    private let dismissThreshold: CGFloat = EnsembleScaffold.NowPlaying.dismissDragThreshold
    private var auroraActiveContentMaxWidth: CGFloat? {
        #if os(iOS)
        return nil
        #else
        return EnsembleScaffold.NowPlaying.auroraActiveContentMaxWidth
        #endif
    }

    public init(
        viewModel: NowPlayingViewModel,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self._playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
        self._artworkProjection = ObservedObject(wrappedValue: viewModel.artworkProjection)
        self._currentPage = State(initialValue: viewModel.currentPage)
        self.namespace = namespace
        self.animationID = animationID
        self.dismissAction = dismissAction
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                VStack(spacing: EnsembleDesign.Spacing.none) {
                    dismissPill
                        .padding(.top, EnsembleScaffold.NowPlaying.dismissPillTopPadding)
                        .padding(.bottom, EnsembleDesign.Spacing.sm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleDismiss()
                        }
                        .gesture(dismissDragGesture)

                    if usesWideNowPlayingLayout(for: geometry.size) {
                        wideLayout(for: geometry)
                    } else {
                        NowPlayingCarousel(viewModel: viewModel, currentPage: currentPageBinding)
                    }
                }
            }
        }
        .onAppear {
            currentPage = viewModel.currentPage
        }
        .offset(y: dismissDragOffset)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: dismissDragOffset)
    }

    private var currentPageBinding: Binding<Int> {
        Binding(
            get: { currentPage },
            set: { newValue in
                currentPage = newValue
                viewModel.currentPage = newValue
            }
        )
    }

    private var backgroundView: some View {
        // Adaptive overlay: light mode uses system background tint, dark mode uses black
        let lightOverlayColor: Color = {
            #if os(iOS)
            return Color(uiColor: .systemBackground)
            #elseif os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return .white
            #endif
        }()

        return ZStack {
            BlurredArtworkBackground(
                image: artworkProjection.artworkImage,
                preBlurredImage: artworkProjection.blurredArtworkImage,
                overlayColor: colorScheme == .dark ? .black : lightOverlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: artworkProjection.artworkImage)

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
                    consumer: .nowPlayingSheet,
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

    private var dismissPill: some View {
        Capsule()
            .fill(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.dismissPillOpacity))
            .frame(
                width: EnsembleScaffold.NowPlaying.dismissPillWidth,
                height: EnsembleScaffold.NowPlaying.dismissPillHeight
            )
    }

    private func usesWideNowPlayingLayout(for size: CGSize) -> Bool {
        let minimumWideWidth = (EnsembleScaffold.NowPlaying.viewportContentPadding * 2)
            + EnsembleScaffold.NowPlaying.viewportInnerSpacing
            + (EnsembleScaffold.NowPlaying.viewportMinimumPanelWidth * 2)
        return size.width >= minimumWideWidth
            && size.width > size.height * EnsembleScaffold.NowPlaying.viewportWideAspectMultiplier
    }

    @ViewBuilder
    private func wideLayout(for geometry: GeometryProxy) -> some View {
        VStack(spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
            wideHeader

            HStack(alignment: .top, spacing: EnsembleScaffold.NowPlaying.viewportInnerSpacing) {
                ControlsCard(viewModel: viewModel, currentPage: currentPageBinding, isAlwaysVisible: true)
                    .frame(width: panelWidth(for: geometry))
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                wideDetailPanel
                    .frame(width: panelWidth(for: geometry))
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, EnsembleScaffold.NowPlaying.viewportContentPadding)
        .padding(.top, max(geometry.safeAreaInsets.top, EnsembleDesign.Spacing.sm))
        .padding(.bottom, EnsembleScaffold.NowPlaying.viewportContentPadding)
    }

    private var wideHeader: some View {
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

            Picker("Panel", selection: widePanelSelection) {
                Text("Queue").tag(0)
                Text("Lyrics").tag(2)
                Text("Info").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: EnsembleScaffold.NowPlaying.viewportPickerWidth)
        }
        .frame(maxWidth: EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth)
    }

    private var widePanelSelection: Binding<Int> {
        Binding(
            get: {
                if currentPage == 3 { return 3 }
                if currentPage == 2 { return 2 }
                return 0
            },
            set: { newValue in
                currentPageBinding.wrappedValue = newValue
            }
        )
    }

    @ViewBuilder
    private var wideDetailPanel: some View {
        if currentPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: currentPageBinding)
        } else if currentPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: currentPageBinding,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: currentPageBinding)
        }
    }

    private func panelWidth(for geometry: GeometryProxy) -> CGFloat {
        let available = min(
            geometry.size.width - (EnsembleScaffold.NowPlaying.viewportContentPadding * 2),
            EnsembleScaffold.NowPlaying.viewportHeaderMaxWidth
        )
        return max((available - EnsembleScaffold.NowPlaying.viewportInnerSpacing) / 2, 0)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.translation.height > 0 else {
                    dismissDragOffset = 0
                    return
                }

                // Keep dismissal responsive without letting the view lag too far behind the finger.
                dismissDragOffset = value.translation.height * 0.72
            }
            .onEnded { value in
                if value.translation.height > dismissThreshold || value.predictedEndTranslation.height > dismissThreshold {
                    handleDismiss()
                } else {
                    dismissDragOffset = 0
                }
            }
    }

    private func handleDismiss() {
        dismissDragOffset = 0
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }
}
