import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Pure layout inputs for the StageFlow carousel.
struct StageFlowLayoutMetrics: Equatable {
    let centerSpacing: CGFloat
    let wingSpacing: CGFloat
    let centerScale: CGFloat
    let siblingScale: CGFloat
    let wingScale: CGFloat
    let siblingRotation: Double
    let wingRotation: Double

    static let `default` = StageFlowLayoutMetrics(
        centerSpacing: 188,
        wingSpacing: 82,
        centerScale: 1.16,
        siblingScale: 0.92,
        wingScale: 0.78,
        siblingRotation: 52,
        wingRotation: 64
    )
}

private enum StageFlowChromeMetrics {
    static let footerSpacing = EnsembleDesign.Spacing.chipVertical
    static let footerBottomPadding = EnsembleDesign.Spacing.xl
    static let footerHorizontalPadding = EnsembleDesign.Spacing.xxl
    static let detailPanelSeamOverlap = EnsembleDesign.Spacing.md
    static let detailPanelCornerRadius: CGFloat = 24
    static let detailPanelStrokeOpacity = 0.08
    static let detailPanelStrokeWidth: CGFloat = 1
    static let detailPanelShadowOpacity = 0.26
    static let detailPanelShadowRadius: CGFloat = 18
    static let detailPanelShadowX = -EnsembleDesign.Spacing.chipVertical
    static let detailPanelShadowY = EnsembleDesign.Spacing.sm
    static let detailPanelZIndex: Double = 150
    static let closeButtonFontSize = EnsembleDesign.Spacing.md
    static let closeButtonForegroundOpacity = 0.8
    static let closeButtonDimension = EnsembleDesign.Spacing.xxxl
    static let closeButtonBackgroundOpacity = 0.36
    static let closeButtonStrokeOpacity = 0.15
    static let closeButtonInset = EnsembleDesign.Spacing.sheetRowVertical
    static let transportLoadingScale = 0.9
    static let transportIconSize: CGFloat = 18
    static let transportButtonDimension: CGFloat = 48
    static let transportFillOpacity = 0.16
    static let transportStrokeOpacity = 0.18
    static let transportTrailingPadding = EnsembleDesign.Spacing.lg
    static let transportBottomPadding = EnsembleDesign.Spacing.sheetOuterVertical
    static let transportZIndex: Double = 200
}

/// Resolved transform values for a single StageFlow item.
struct StageFlowItemLayout: Equatable {
    let xOffset: CGFloat
    let scale: CGFloat
    let rotation: Double
    let zIndex: Double
}

/// Pure layout and snapping rules for StageFlow.
enum StageFlowLayoutModel {
    static func snappedIndex(for proposedIndex: Double, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let upperBound = Double(itemCount - 1)
        let clamped = min(max(proposedIndex, 0), upperBound)
        return Int(clamped.rounded())
    }

    static func layout(for relativeIndex: Double, metrics: StageFlowLayoutMetrics) -> StageFlowItemLayout {
        let signedDistance = relativeIndex
        let absoluteDistance = abs(relativeIndex)
        let direction = signedDistance == 0 ? 0 : (signedDistance > 0 ? 1.0 : -1.0)

        let xOffset: CGFloat = {
            switch absoluteDistance {
            case ..<1:
                return CGFloat(direction) * metrics.centerSpacing * CGFloat(absoluteDistance)
            default:
                let wingDepth = absoluteDistance - 1
                return CGFloat(direction) * (metrics.centerSpacing + metrics.wingSpacing * CGFloat(wingDepth))
            }
        }()

        let scale: CGFloat
        let rotationMagnitude: Double

        switch absoluteDistance {
        case ..<1:
            scale = interpolate(metrics.centerScale, metrics.siblingScale, progress: absoluteDistance)
            rotationMagnitude = interpolate(0, metrics.siblingRotation, progress: absoluteDistance)
        case ..<2:
            let progress = absoluteDistance - 1
            scale = interpolate(metrics.siblingScale, metrics.wingScale, progress: progress)
            rotationMagnitude = interpolate(metrics.siblingRotation, metrics.wingRotation, progress: progress)
        default:
            scale = metrics.wingScale
            rotationMagnitude = metrics.wingRotation
        }

        return StageFlowItemLayout(
            xOffset: xOffset,
            scale: scale,
            rotation: -direction * rotationMagnitude,
            zIndex: absoluteDistance < 0.001 ? 200 : 100 - absoluteDistance
        )
    }

    private static func interpolate(_ start: CGFloat, _ end: CGFloat, progress: Double) -> CGFloat {
        start + (end - start) * CGFloat(progress)
    }

    private static func interpolate(_ start: Double, _ end: Double, progress: Double) -> Double {
        start + (end - start) * progress
    }
}

/// A 3D stage-style carousel with one permanently centered item and a trailing detail panel.
struct StageFlowView<Item: Identifiable, ItemView: View, DetailView: View>: View {
    let items: [Item]
    let nowPlayingVM: NowPlayingViewModel
    let itemView: (Item) -> ItemView
    let detailView: (Item) -> DetailView
    let titleContent: (Item) -> String
    let subtitleContent: (Item) -> String?
    let resolvePlaybackTracks: (Item) async -> [Track]
    @Binding var selectedItem: Item?

    @State private var isPanelPresented = false
    @State private var isPlaying = false
    @State private var isTransportLoading = false
    @State private var hasPlaybackContext = false
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    private let layoutMetrics = StageFlowLayoutMetrics.default

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                stageBackground

                stageLayer

                footerLayer

                if isPanelPresented {
                    panelDismissLayer()
                }

                if let centeredItem = centeredItem, isPanelPresented {
                    detailPanel(for: centeredItem, in: geometry)
                }

                transportButton
            }
        }
        .onAppear {
            syncSelectionWithItems(closePanel: true)
            updatePlaybackContext(currentTrack: nowPlayingVM.currentTrack, queueCount: nowPlayingVM.queue.count)
            updateTransportState(
                currentTrack: nowPlayingVM.currentTrack,
                playbackState: nowPlayingVM.playbackState
            )
        }
        .onChange(of: items.map(\.id)) { _ in
            syncSelectionWithItems(closePanel: true)
        }
        .onChange(of: selectedItem?.id) { _ in
            isPanelPresented = false
        }
        .onReceive(nowPlayingVM.$playbackState) { playbackState in
            updateTransportState(
                currentTrack: nowPlayingVM.currentTrack,
                playbackState: playbackState
            )
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            updatePlaybackContext(currentTrack: track, queueCount: nowPlayingVM.queue.count)
            updateTransportState(
                currentTrack: track,
                playbackState: nowPlayingVM.playbackState
            )
        }
        .onReceive(nowPlayingVM.$queue) { queue in
            updatePlaybackContext(currentTrack: nowPlayingVM.currentTrack, queueCount: queue.count)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var stageBackground: some View {
        Color.black
            .ignoresSafeArea()

        if settingsManager.auroraVisualizationEnabled && nowPlayingVM.currentTrack?.sourceCapabilities.supportsWaveform != false {
            AuroraVisualizationView(
                playbackService: DependencyContainer.shared.playbackService,
                consumer: .stageFlow,
                accentColor: settingsManager.accentColor.color,
                isPaused: false,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var stageLayer: some View {
        #if os(iOS)
        StageFlowCarousel(
            items: items,
            selectedID: selectedItem?.id,
            hidesSelectedItem: isPanelPresented,
            itemView: { itemView($0).id($0.id) },
            title: titleContent,
            onSelection: { selectedItem = $0 },
            onActivate: { item in
                selectedItem = item
                withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.88)) {
                    isPanelPresented.toggle()
                }
            }
        )
        .allowsHitTesting(!isPanelPresented)
        #endif
    }

    @ViewBuilder
    private var footerLayer: some View {
        if let liveCenteredItem = centeredItem {
            VStack(spacing: StageFlowChromeMetrics.footerSpacing) {
                Spacer()
                Text(titleContent(liveCenteredItem))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let subtitle = subtitleContent(liveCenteredItem), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.bottom, StageFlowChromeMetrics.footerBottomPadding)
            .padding(.horizontal, StageFlowChromeMetrics.footerHorizontalPadding)
            .allowsHitTesting(false)
        }
    }

    private func detailPanel(for item: Item, in geometry: GeometryProxy) -> some View {
        let trackPanelWidth = detailPanelWidth(for: geometry)
        let centeredItemSize = centeredItemSize(for: geometry)
        let seamOverlap = StageFlowChromeMetrics.detailPanelSeamOverlap
        let combinedPanelWidth = centeredItemSize + trackPanelWidth - seamOverlap
        let panelCenterX = geometry.size.width * 0.5

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: StageFlowChromeMetrics.detailPanelCornerRadius, style: .continuous)
                .fill(stagePanelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StageFlowChromeMetrics.detailPanelCornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(StageFlowChromeMetrics.detailPanelStrokeOpacity),
                            lineWidth: StageFlowChromeMetrics.detailPanelStrokeWidth
                        )
                )
                .shadow(
                    color: .black.opacity(StageFlowChromeMetrics.detailPanelShadowOpacity),
                    radius: StageFlowChromeMetrics.detailPanelShadowRadius,
                    x: StageFlowChromeMetrics.detailPanelShadowX,
                    y: StageFlowChromeMetrics.detailPanelShadowY
                )

            HStack(spacing: EnsembleDesign.Spacing.none) {
                itemView(item)
                    .frame(width: centeredItemSize, height: centeredItemSize)

                VStack(spacing: EnsembleDesign.Spacing.none) {
                    detailView(item)
                }
                .frame(width: trackPanelWidth)
                .frame(height: centeredItemSize)
                .padding(.leading, -seamOverlap)
            }
            .clipShape(RoundedRectangle(cornerRadius: StageFlowChromeMetrics.detailPanelCornerRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    closePanel()
                } label: {
                    Image(systemName: EnsembleDesign.Icon.close)
                        .font(.system(size: StageFlowChromeMetrics.closeButtonFontSize, weight: .semibold))
                        .foregroundColor(.primary.opacity(StageFlowChromeMetrics.closeButtonForegroundOpacity))
                        .frame(
                            width: StageFlowChromeMetrics.closeButtonDimension,
                            height: StageFlowChromeMetrics.closeButtonDimension
                        )
                        .background(
                            Circle()
                                .fill(Color.white.opacity(StageFlowChromeMetrics.closeButtonBackgroundOpacity))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    Color.primary.opacity(StageFlowChromeMetrics.closeButtonStrokeOpacity),
                                    lineWidth: StageFlowChromeMetrics.detailPanelStrokeWidth
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, StageFlowChromeMetrics.closeButtonInset)
                .padding(.trailing, StageFlowChromeMetrics.closeButtonInset)
            }
        }
        .frame(width: combinedPanelWidth, height: centeredItemSize)
        .position(x: panelCenterX, y: detailSurfaceCenterY(for: geometry))
        .zIndex(StageFlowChromeMetrics.detailPanelZIndex)
        .allowsHitTesting(true)
    }

    private func panelDismissLayer() -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                closePanel()
            }
            .zIndex(50)
    }

    private var transportButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    handleTransportTap()
                } label: {
                    ZStack {
                        if isTransportLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(StageFlowChromeMetrics.transportLoadingScale)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: StageFlowChromeMetrics.transportIconSize, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(
                        width: StageFlowChromeMetrics.transportButtonDimension,
                        height: StageFlowChromeMetrics.transportButtonDimension
                    )
                    .background(
                        Circle()
                            .fill(Color.white.opacity(StageFlowChromeMetrics.transportFillOpacity))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                Color.white.opacity(StageFlowChromeMetrics.transportStrokeOpacity),
                                lineWidth: StageFlowChromeMetrics.detailPanelStrokeWidth
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, StageFlowChromeMetrics.transportTrailingPadding)
                .padding(.bottom, StageFlowChromeMetrics.transportBottomPadding)
            }
        }
        .zIndex(StageFlowChromeMetrics.transportZIndex)
    }

    private var centeredItem: Item? {
        selectedItem.flatMap { selected in items.first { $0.id == selected.id } } ?? items.first
    }

    private var stagePanelBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.gray
        #endif
    }

    private func baseItemSize(for geometry: GeometryProxy) -> CGFloat {
        max(0, min(geometry.size.height * 0.62, geometry.size.width * 0.34) - 7)
    }

    private func centeredItemSize(for geometry: GeometryProxy) -> CGFloat {
        baseItemSize(for: geometry) * layoutMetrics.centerScale
    }

    private func detailPanelWidth(for geometry: GeometryProxy) -> CGFloat {
        min(max(geometry.size.width * 0.42, 300), 380)
    }

    private func stageCenterY(for geometry: GeometryProxy) -> CGFloat {
        geometry.size.height * 0.45
    }

    private func detailSurfaceCenterY(for geometry: GeometryProxy) -> CGFloat {
        stageCenterY(for: geometry)
    }

    /// Mirrors the main transport control: show a spinner while loading/buffering.
    private func updateTransportState(currentTrack: Track?, playbackState: PlaybackState) {
        guard currentTrack != nil else {
            isPlaying = false
            isTransportLoading = false
            return
        }

        switch playbackState {
        case .loading, .buffering:
            isPlaying = false
            isTransportLoading = true
        case .playing:
            isPlaying = true
            isTransportLoading = false
        case .stopped, .paused, .failed:
            isPlaying = false
            isTransportLoading = false
        }
    }

    private func handleTransportTap() {
        guard let centeredItem else {
            if hasPlaybackContext {
                nowPlayingVM.togglePlayPause()
            }
            return
        }

        if hasPlaybackContext {
            nowPlayingVM.togglePlayPause()
            return
        }

        Task {
            let tracks = await resolvePlaybackTracks(centeredItem)
            guard !tracks.isEmpty else { return }
            nowPlayingVM.play(tracks: tracks, startingAt: 0)
        }
    }

    private func syncSelectionWithItems(closePanel: Bool) {
        selectedItem = centeredItem
        if closePanel { isPanelPresented = false }
    }

    private func closePanel() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.9)) {
            isPanelPresented = false
        }
    }

    private func updatePlaybackContext(currentTrack: Track?, queueCount: Int) {
        hasPlaybackContext = currentTrack != nil || queueCount > 0
    }

}
