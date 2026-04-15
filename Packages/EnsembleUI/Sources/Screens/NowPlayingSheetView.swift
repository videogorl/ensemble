import EnsembleCore
import SwiftUI

/// Main sheet container for iPhone-style Now Playing presentation.
/// Large-screen viewport presentation lives in `NowPlayingViewportRoot`.
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var dismissDragOffset: CGFloat = 0

    private let namespace: Namespace.ID?
    private let animationID: String?
    private let dismissAction: (() -> Void)?
    private let dismissThreshold: CGFloat = 120

    public init(
        viewModel: NowPlayingViewModel,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.namespace = namespace
        self.animationID = animationID
        self.dismissAction = dismissAction
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                VStack(spacing: 0) {
                    dismissPill
                        .padding(.top, 28)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleDismiss()
                        }
                        .gesture(dismissDragGesture)

                    if usesWideNowPlayingLayout(for: geometry.size) {
                        wideLayout(for: geometry)
                    } else {
                        NowPlayingCarousel(viewModel: viewModel, currentPage: $viewModel.currentPage)
                    }
                }
            }
        }
        .offset(y: dismissDragOffset)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: dismissDragOffset)
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
                image: viewModel.artworkImage,
                preBlurredImage: viewModel.blurredArtworkImage,
                overlayColor: colorScheme == .dark ? .black : lightOverlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            if colorScheme == .dark {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
            } else {
                lightOverlayColor.opacity(0.7)
                    .allowsHitTesting(false)
            }

            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    accentColor: settingsManager.accentColor.color,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode
                )
                .allowsHitTesting(false)
                .opacity(0.7)
            }
        }
        .ignoresSafeArea()
    }

    private var dismissPill: some View {
        Capsule()
            .fill(Color.primary.opacity(0.3))
            .frame(width: 36, height: 5)
    }

    private func usesWideNowPlayingLayout(for size: CGSize) -> Bool {
        let minimumPanelWidth: CGFloat = 320
        let minimumWideWidth = (24 * 2) + 20 + (minimumPanelWidth * 2)
        return size.width >= minimumWideWidth && size.width > size.height * 0.82
    }

    @ViewBuilder
    private func wideLayout(for geometry: GeometryProxy) -> some View {
        VStack(spacing: 20) {
            wideHeader

            HStack(alignment: .top, spacing: 20) {
                ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
                    .frame(width: panelWidth(for: geometry))
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                wideDetailPanel
                    .frame(width: panelWidth(for: geometry))
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, max(geometry.safeAreaInsets.top, 8))
        .padding(.bottom, 24)
    }

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.currentTrack?.title ?? "Now Playing")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let artist = viewModel.currentTrack?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
            .frame(width: 300)
        }
        .frame(maxWidth: 1120)
    }

    private var widePanelSelection: Binding<Int> {
        Binding(
            get: {
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
    private var wideDetailPanel: some View {
        if viewModel.currentPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else if viewModel.currentPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        }
    }

    private func panelWidth(for geometry: GeometryProxy) -> CGFloat {
        let available = min(geometry.size.width - 48, 1120)
        return max((available - 20) / 2, 0)
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
