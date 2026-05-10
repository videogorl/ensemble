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
    let siblingOpacity: Double
    let wingOpacity: Double
    let siblingRotation: Double
    let wingRotation: Double

    static let `default` = StageFlowLayoutMetrics(
        centerSpacing: 188,
        wingSpacing: 82,
        centerScale: 1.16,
        siblingScale: 0.92,
        wingScale: 0.78,
        siblingOpacity: 0.94,
        wingOpacity: 0.68,
        siblingRotation: 52,
        wingRotation: 64
    )
}

private enum StageFlowChromeMetrics {
    static let reflectionBlurRadius: CGFloat = 1.2
    static let reflectionYOffset = EnsembleDesign.Spacing.chipVertical
    static let reflectionTopPadding = -EnsembleDesign.Spacing.xs
    static let reflectionHeightRatio: CGFloat = 0.48
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
    let opacity: Double
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

    static func projectedReleaseIndex(
        baseIndex: Double,
        dragDelta: Double,
        predictedTotalDelta: Double
    ) -> Double {
        let releasedIndex = baseIndex + dragDelta
        let residualMomentum = predictedTotalDelta - dragDelta
        let momentumProjection = residualMomentum * momentumProjectionFactor(for: abs(residualMomentum))
        return releasedIndex + momentumProjection
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
        let opacity: Double
        let rotationMagnitude: Double

        switch absoluteDistance {
        case ..<1:
            scale = interpolate(metrics.centerScale, metrics.siblingScale, progress: absoluteDistance)
            opacity = interpolate(1.0, metrics.siblingOpacity, progress: absoluteDistance)
            rotationMagnitude = interpolate(0, metrics.siblingRotation, progress: absoluteDistance)
        case ..<2:
            let progress = absoluteDistance - 1
            scale = interpolate(metrics.siblingScale, metrics.wingScale, progress: progress)
            opacity = interpolate(metrics.siblingOpacity, metrics.wingOpacity, progress: progress)
            rotationMagnitude = interpolate(metrics.siblingRotation, metrics.wingRotation, progress: progress)
        default:
            scale = metrics.wingScale
            opacity = metrics.wingOpacity
            rotationMagnitude = metrics.wingRotation
        }

        return StageFlowItemLayout(
            xOffset: xOffset,
            scale: scale,
            opacity: opacity,
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

    private static func momentumProjectionFactor(for residualMomentum: Double) -> Double {
        switch residualMomentum {
        case ..<0.2:
            return 0
        case ..<0.6:
            return 0.35
        case ..<1.2:
            return 0.72
        default:
            return 0.98
        }
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

    @State private var scrollIndex: Double = 0
    @State private var dragIndexDelta: Double = 0
    @State private var releaseVisualIntensity: Double = 0
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

                stageLayer(in: geometry)

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
            handleExternalSelectionChange()
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

        if settingsManager.auroraVisualizationEnabled {
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

    private func stageLayer(in geometry: GeometryProxy) -> some View {
        let baseItemSize = baseItemSize(for: geometry)
        let currentIndex = scrollIndex + dragIndexDelta
        let centerX = stageCenterX(for: geometry)
        let centeredIndex = StageFlowLayoutModel.snappedIndex(for: scrollIndex, itemCount: items.count)
        let dragVisualIntensity = max(min(abs(dragIndexDelta), 3), releaseVisualIntensity)
        let stageDragGesture = DragGesture()
            .onChanged { value in
                releaseVisualIntensity = 0
                dragIndexDelta = -Double(value.translation.width / dragSensitivity(for: baseItemSize))
            }
            .onEnded { value in
                handleDragEnded(value, itemSize: baseItemSize)
            }

        return ZStack {
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(false)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if !(isPanelPresented && index == centeredIndex) {
                    let relativeIndex = Double(index) - currentIndex

                    if abs(relativeIndex) < visibleStageDepth(for: dragVisualIntensity) {
                        let itemLayout = StageFlowLayoutModel.layout(for: relativeIndex, metrics: layoutMetrics)
                        stageCard(
                            for: item,
                            itemSize: baseItemSize,
                            layout: itemLayout,
                            dragVisualIntensity: dragVisualIntensity
                        )
                        #if os(iOS)
                            .accessibilityIdentifier("stageflow.item.\(index)")
                        #endif

                        stageTapTarget(
                            for: item,
                            at: index,
                            relativeIndex: relativeIndex,
                            baseItemSize: baseItemSize,
                            layout: itemLayout
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .position(x: centerX, y: stageCenterY(for: geometry))
        .contentShape(Rectangle())
        .allowsHitTesting(!isPanelPresented)
        .highPriorityGesture(stageDragGesture)
    }

    private func stageCard(
        for item: Item,
        itemSize: CGFloat,
        layout: StageFlowItemLayout,
        dragVisualIntensity: Double
    ) -> some View {
        let reflectionHeight = stageReflectionHeight(for: itemSize)

        return VStack(spacing: EnsembleDesign.Spacing.none) {
            itemView(item)
                .frame(width: itemSize, height: itemSize)

            reflectedStageItem(for: item, itemSize: itemSize)
        }
        // Rasterize the composed artwork + reflection once, then transform that
        // layer during drags so fast swipes don't look like the whole stage fades.
        .compositingGroup()
        .scaleEffect(layout.scale)
        .opacity(displayOpacity(for: layout.opacity, dragVisualIntensity: dragVisualIntensity))
        .rotation3DEffect(
            .degrees(layout.rotation),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.58
        )
        .offset(
            x: layout.xOffset,
            y: reflectionHeight * 0.5
        )
        .zIndex(layout.zIndex)
        .allowsHitTesting(false)
    }

    /// Keep the wings more present during fast swipes so motion reads as artwork
    /// flying by instead of a stack of dim fading cards.
    private func displayOpacity(for baseOpacity: Double, dragVisualIntensity: Double) -> Double {
        let minimumOpacity = 0.72 + (dragVisualIntensity * 0.08)
        return min(1, max(baseOpacity, minimumOpacity))
    }

    private func visibleStageDepth(for dragVisualIntensity: Double) -> Double {
        10 + dragVisualIntensity * 2
    }

    private func reflectedStageItem(for item: Item, itemSize: CGFloat) -> some View {
        let reflectionHeight = stageReflectionHeight(for: itemSize)

        return itemView(item)
            .frame(width: itemSize, height: itemSize)
            .scaleEffect(x: 1, y: -1, anchor: .center)
            .opacity(0.28)
            .mask(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.62),
                        Color.white.opacity(0.22),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: itemSize, height: reflectionHeight)
                .frame(maxHeight: .infinity, alignment: .top)
            )
            .blur(radius: StageFlowChromeMetrics.reflectionBlurRadius)
            .offset(y: StageFlowChromeMetrics.reflectionYOffset)
            .padding(.top, StageFlowChromeMetrics.reflectionTopPadding)
            .frame(width: itemSize, height: reflectionHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
    }

    private func stageReflectionHeight(for itemSize: CGFloat) -> CGFloat {
        itemSize * StageFlowChromeMetrics.reflectionHeightRatio
    }

    @ViewBuilder
    private var footerLayer: some View {
        if let liveCenteredItem {
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

    private var liveCenteredItem: Item? {
        guard !items.isEmpty else { return nil }
        let centeredIndex = StageFlowLayoutModel.snappedIndex(
            for: scrollIndex + dragIndexDelta,
            itemCount: items.count
        )
        return items[centeredIndex]
    }

    private var centeredItem: Item? {
        guard !items.isEmpty else { return nil }
        let centeredIndex = StageFlowLayoutModel.snappedIndex(for: scrollIndex, itemCount: items.count)
        return items[centeredIndex]
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

    private func dragSensitivity(for itemSize: CGFloat) -> CGFloat {
        max(itemSize * 0.78, 1)
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

    private var detailPanelTrailingInset: CGFloat {
        14
    }

    private func stageCenterX(for geometry: GeometryProxy) -> CGFloat {
        geometry.size.width * 0.5
    }

    private func stageCenterY(for geometry: GeometryProxy) -> CGFloat {
        geometry.size.height * 0.45
    }

    private func detailSurfaceCenterY(for geometry: GeometryProxy) -> CGFloat {
        stageCenterY(for: geometry)
    }

    private func stageTapTarget(
        for item: Item,
        at index: Int,
        relativeIndex: Double,
        baseItemSize: CGFloat,
        layout: StageFlowItemLayout
    ) -> some View {
        Color.clear
            .frame(
                width: stageTapTargetWidth(for: relativeIndex, baseItemSize: baseItemSize),
                height: baseItemSize * 0.98
            )
            .contentShape(Rectangle())
            .offset(x: layout.xOffset, y: 0)
            .zIndex(layout.zIndex + 0.2)
            // Use a simultaneous tap recognizer so horizontal drags still belong
            // to the stage gesture instead of being swallowed by the tap target.
            .simultaneousGesture(
                TapGesture().onEnded {
                    handleTap(on: item, at: index)
                }
            )
    }

    private func stageTapTargetWidth(for relativeIndex: Double, baseItemSize: CGFloat) -> CGFloat {
        switch abs(relativeIndex) {
        case ..<0.5:
            return baseItemSize * 0.84
        case ..<1.5:
            return baseItemSize * 0.42
        default:
            return baseItemSize * 0.26
        }
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

    private func handleDragEnded(_ value: DragGesture.Value, itemSize: CGFloat) {
        let releasedIndex = scrollIndex + dragIndexDelta
        let predictedTotalDelta = -Double(value.predictedEndTranslation.width / dragSensitivity(for: itemSize))
        let projectedIndex = StageFlowLayoutModel.projectedReleaseIndex(
            baseIndex: scrollIndex,
            dragDelta: dragIndexDelta,
            predictedTotalDelta: predictedTotalDelta
        )
        let targetIndex = StageFlowLayoutModel.snappedIndex(
            for: projectedIndex,
            itemCount: items.count
        )
        let carriedVisualIntensity = min(abs(dragIndexDelta), 3)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollIndex = releasedIndex
            dragIndexDelta = 0
            releaseVisualIntensity = carriedVisualIntensity
        }

        snap(to: targetIndex, closePanel: true)
    }

    private func handleTap(on item: Item, at index: Int) {
        let centeredIndex = StageFlowLayoutModel.snappedIndex(for: scrollIndex, itemCount: items.count)
        guard centeredIndex == index else {
            snap(to: index, closePanel: true)
            return
        }

        selectedItem = item
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.88)) {
            isPanelPresented.toggle()
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
        guard !items.isEmpty else {
            selectedItem = nil
            scrollIndex = 0
            dragIndexDelta = 0
            if closePanel {
                isPanelPresented = false
            }
            return
        }

        if let selectedItem,
           let existingIndex = items.firstIndex(where: { $0.id == selectedItem.id }) {
            scrollIndex = Double(existingIndex)
            dragIndexDelta = 0
            if closePanel {
                isPanelPresented = false
            }
            return
        }

        let nearestIndex = StageFlowLayoutModel.snappedIndex(for: scrollIndex, itemCount: items.count)
        scrollIndex = Double(nearestIndex)
        dragIndexDelta = 0
        selectedItem = items[nearestIndex]
        if closePanel {
            isPanelPresented = false
        }
    }

    private func handleExternalSelectionChange() {
        guard !items.isEmpty else { return }

        guard let selectedItem else {
            syncSelectionWithItems(closePanel: true)
            return
        }

        guard let targetIndex = items.firstIndex(where: { $0.id == selectedItem.id }) else {
            syncSelectionWithItems(closePanel: true)
            return
        }

        snap(to: targetIndex, closePanel: true, animate: false)
    }

    private func snap(to index: Int, closePanel: Bool, animate: Bool = true) {
        guard items.indices.contains(index) else { return }

        let update = {
            scrollIndex = Double(index)
            selectedItem = items[index]
            releaseVisualIntensity = 0
            if closePanel {
                isPanelPresented = false
            }
        }

        let targetIndex = Double(index)
        let correctionDistance = abs(scrollIndex - targetIndex)

        if animate, correctionDistance > 0.001 {
            withAnimation(snapAnimation(for: correctionDistance)) {
                update()
            }
        } else {
            update()
        }
    }

    private func closePanel() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.9)) {
            isPanelPresented = false
        }
    }

    private func updatePlaybackContext(currentTrack: Track?, queueCount: Int) {
        hasPlaybackContext = currentTrack != nil || queueCount > 0
    }

    /// Applies a short residual correction after release instead of a second inertial flourish.
    private func snapAnimation(for correctionDistance: Double) -> Animation {
        let duration = min(max(0.08 + (correctionDistance * 0.045), 0.11), 0.18)
        return .easeOut(duration: duration)
    }
}
