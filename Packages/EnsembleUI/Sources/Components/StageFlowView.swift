import EnsembleCore
import SwiftUI

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
        centerSpacing: 176,
        wingSpacing: 82,
        centerScale: 1.16,
        siblingScale: 0.92,
        wingScale: 0.78,
        siblingOpacity: 0.94,
        wingOpacity: 0.68,
        siblingRotation: 58,
        wingRotation: 72
    )
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
            zIndex: 100 - absoluteDistance
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

    @State private var scrollIndex: Double = 0
    @State private var dragIndexDelta: Double = 0
    @State private var isPanelPresented = false
    @State private var isPlaying = false
    @State private var hasPlaybackContext = false

    private let layoutMetrics = StageFlowLayoutMetrics.default

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                stageLayer(in: geometry)

                footerLayer

                if let centeredItem = centeredItem, isPanelPresented {
                    detailPanel(for: centeredItem, in: geometry)
                }

                transportButton
            }
        }
        .onAppear {
            syncSelectionWithItems(closePanel: true)
            updatePlaybackContext(currentTrack: nowPlayingVM.currentTrack, queueCount: nowPlayingVM.queue.count)
            isPlaying = nowPlayingVM.isPlaying
        }
        .onChange(of: items.map(\.id)) { _ in
            syncSelectionWithItems(closePanel: true)
        }
        .onChange(of: selectedItem?.id) { _ in
            handleExternalSelectionChange()
        }
        .onReceive(nowPlayingVM.$playbackState) { _ in
            isPlaying = nowPlayingVM.isPlaying
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            updatePlaybackContext(currentTrack: track, queueCount: nowPlayingVM.queue.count)
        }
        .onReceive(nowPlayingVM.$queue) { queue in
            updatePlaybackContext(currentTrack: nowPlayingVM.currentTrack, queueCount: queue.count)
        }
    }

    private func stageLayer(in geometry: GeometryProxy) -> some View {
        let baseItemSize = min(geometry.size.height * 0.62, geometry.size.width * 0.34)
        let currentIndex = scrollIndex + dragIndexDelta
        let panelWidth = detailPanelWidth(for: geometry)
        let centerX = geometry.size.width * (isPanelPresented ? 0.36 : 0.5)

        return ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragIndexDelta = -Double(value.translation.width / dragSensitivity(for: baseItemSize))
                        }
                        .onEnded { value in
                            handleDragEnded(value, itemSize: baseItemSize)
                        }
                )

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let relativeIndex = Double(index) - currentIndex

                if abs(relativeIndex) < 10 {
                    let itemLayout = StageFlowLayoutModel.layout(for: relativeIndex, metrics: layoutMetrics)
                    itemView(item)
                        .frame(width: baseItemSize, height: baseItemSize)
                        .scaleEffect(itemLayout.scale)
                        .opacity(itemLayout.opacity)
                        .rotation3DEffect(
                            .degrees(itemLayout.rotation),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.58
                        )
                        .offset(
                            x: itemLayout.xOffset - (isPanelPresented ? panelWidth * 0.18 : 0),
                            y: isPanelPresented ? -6 : 0
                        )
                        .zIndex(itemLayout.zIndex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleTap(on: item, at: index)
                        }
                    #if os(iOS)
                        .accessibilityIdentifier("stageflow.item.\(index)")
                    #endif
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .position(x: centerX, y: geometry.size.height * 0.44)
        .animation(.easeInOut(duration: 0.22), value: isPanelPresented)
    }

    @ViewBuilder
    private var footerLayer: some View {
        if let centeredItem {
            VStack(spacing: 6) {
                Spacer()
                Text(titleContent(centeredItem))
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let subtitle = subtitleContent(centeredItem), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.bottom, 28)
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
        }
    }

    private func detailPanel(for item: Item, in geometry: GeometryProxy) -> some View {
        let panelWidth = detailPanelWidth(for: geometry)

        return ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    closePanel()
                }

            HStack {
                Spacer()
                VStack(spacing: 0) {
                    detailView(item)
                }
                .frame(width: panelWidth)
                .frame(maxHeight: geometry.size.height * 0.88)
                .background(stagePanelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.32), radius: 22, x: -10, y: 10)
                .padding(.trailing, 24)
                .padding(.vertical, 24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .zIndex(150)
        .animation(.interactiveSpring(response: 0.38, dampingFraction: 0.86), value: isPanelPresented)
    }

    private var transportButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    handleTransportTap()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 62, height: 62)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.16))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
        }
        .zIndex(200)
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

    private func detailPanelWidth(for geometry: GeometryProxy) -> CGFloat {
        min(max(geometry.size.width * 0.42, 300), 380)
    }

    private func handleDragEnded(_ value: DragGesture.Value, itemSize: CGFloat) {
        let releasedIndex = scrollIndex + dragIndexDelta
        let predictedDelta = -Double(value.predictedEndTranslation.width / dragSensitivity(for: itemSize)) * 0.08
        let targetIndex = StageFlowLayoutModel.snappedIndex(
            for: releasedIndex + predictedDelta,
            itemCount: items.count
        )

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollIndex = releasedIndex
            dragIndexDelta = 0
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
