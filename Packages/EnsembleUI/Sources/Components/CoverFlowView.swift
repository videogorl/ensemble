import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A 3D carousel view that displays items in a CoverFlow-style layout
/// with perspective rotation and scaling based on distance from center.
/// Tapping an item zooms it in and flips it to reveal details.
struct CoverFlowView<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    let itemView: (Item) -> ItemView
    let detailContent: (Item?) -> AnyView
    let titleContent: (Item) -> String
    let subtitleContent: (Item) -> String?
    @Binding var selectedItem: Item?

    /// Binding to track whether a card is currently flipped (showing detail).
    /// Parent views can use this to coordinate navigation on orientation change.
    var isShowingDetail: Binding<Bool>?

    /// When true on appear, automatically open (zoom+flip) the selected item.
    /// Used when returning from detail view via landscape rotation.
    var autoOpenSelectedItem: Binding<Bool>?

    // Scroll & Drag State
    @State private var scrollIndex: Double = 0

    // Drag tracking for progressive sensitivity
    @State private var dragStartIndex: Double = 0
    @State private var isDragging: Bool = false

    // Zoom/Flip State
    @State private var flipAngle: Double = 0
    @State private var zoomedItem: Item? = nil
    @Namespace private var animation

    // Configuration
    private let rotationMax: Double = 65

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                // Background Carousel Layer
                carouselLayer(geometry: geometry)
                    .blur(radius: zoomedItem != nil ? 15 : 0)
                    .opacity(zoomedItem != nil ? 0 : 1)
                    .allowsHitTesting(zoomedItem == nil)

                // Static Footer Text Layer (Only visible when not zoomed)
                if zoomedItem == nil, let selected = selectedItem {
                    VStack(spacing: 4) {
                        Spacer()
                        Text(titleContent(selected))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)

                        if let subtitle = subtitleContent(selected) {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 20)
                    .padding(.horizontal)
                    .transition(.opacity)
                    .allowsHitTesting(false) // Let taps pass through to the carousel
                }

                // Zoomed Card Layer
                if let item = zoomedItem {
                   zoomedCardLayer(item: item, geometry: geometry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            // Check if we should auto-open the selected item (coming from detail view rotation)
            if autoOpenSelectedItem?.wrappedValue == true, let item = selectedItem {
                // Reset the flag
                autoOpenSelectedItem?.wrappedValue = false
                // Auto-open after a brief delay to let the view settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    selectAndZoom(item)
                }
            } else {
                // Reset isShowingDetail on appear - important when returning from detail view
                // to ensure we don't navigate again on next rotation
                syncIsShowingDetail()
            }
        }
        .onChange(of: selectedItem?.id) { _ in
            handleExternalSelectionChange()
        }
        // Sync zoomed state to parent binding
        .onChange(of: zoomedItem?.id) { _ in
            syncIsShowingDetail()
        }
        .onChange(of: flipAngle) { _ in
            syncIsShowingDetail()
        }
    }

    // MARK: - Carousel Layer

    private func carouselLayer(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let carouselHeight = geometry.size.height * (isLandscape ? 0.8 : 0.85)

        // Item Sizing
        let baseItemSize = carouselHeight * 0.60
        let itemWidth = baseItemSize
        let itemHeight = baseItemSize

        // Spacing Constants
        let wingSpacing = itemWidth * 0.39
        let centerGap = itemWidth * 0.30

        // Configuration
        let rotationMax: Double = 60

        // Current display index
        let currentIndex = scrollIndex

        return ZStack {
            // Render visible items
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let i = Double(index)
                let relativeIndex = i - currentIndex

                // Optimization: render only items reasonably close
                if abs(relativeIndex) < 15 {
                    // Non-Linear Position Logic
                    let linearX = relativeIndex * wingSpacing
                    let gapShift = clamp(relativeIndex, -1, 1) * centerGap
                    let finalX = linearX + gapShift

                    // Scale Logic: Center item is 33% bigger
                    let baseScale = 1.0 + (0.33 * max(0, 1 - abs(relativeIndex)))
                    
                    Button {
                        tapItem(item, at: i, currentIndex: currentIndex)
                    } label: {
                        itemView(item)
                            .frame(width: itemWidth, height: itemHeight)
                    }
                    .buttonStyle(CarouselButtonStyle())
                    .scaleEffect(baseScale)
                    .modifier(
                        CoverFlowRotationModifier(
                            progress: relativeIndex,
                            rotationMax: rotationMax
                        )
                    )
                    .opacity(zoomedItem?.id == item.id ? 0 : 1)
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: true)
                    .offset(x: finalX)
                    .zIndex(100 - abs(relativeIndex) + (Double(index) * 0.0001))
                    .transition(.identity)
                }
            }
        }
        .frame(width: geometry.size.width, height: carouselHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(carouselDragGesture(geometry: geometry))
        .onAppear {
            scrollToSelection()
        }
    }

    // MARK: - Gestures

    private func carouselDragGesture(geometry: GeometryProxy) -> some Gesture {
        // Much higher sensitivity: ~28% of screen width = 1 item
        let sensitivity = 1.0 / (geometry.size.width * 0.28)

        return DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartIndex = scrollIndex
                }
                
                // Live update with interactive spring for buttery tracking
                withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.88, blendDuration: 0)) {
                    scrollIndex = dragStartIndex + (-value.translation.width * sensitivity)
                }
            }
            .onEnded { value in
                isDragging = false
                
                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let velocity = predicted - translation
                
                // Extreme inertia (1.7 weight) for that "infinite glide" feel
                let targetIndex = dragStartIndex + (-(translation + (velocity * 1.7)) * sensitivity)
                
                // Snap to nearest item
                let clampedIndex = max(0, min(Double(items.count - 1), round(targetIndex)))

                // Very fast spring (0.25 response) for immediate locking
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    scrollIndex = clampedIndex
                    
                    // Update selection to the center item
                    let index = Int(clampedIndex)
                    if index >= 0 && index < items.count {
                        selectedItem = items[index]
                    }
                }
            }
    }

    // MARK: - Zoomed Card Layer

    private func zoomedCardLayer(item: Item, geometry: GeometryProxy) -> some View {
        let zoomedHeight = geometry.size.height * 0.85
        let zoomedWidth = zoomedHeight * 1.5

        return ZStack {
            Color.black.opacity(0.01)
                .onTapGesture { closeZoom() }

            ZStack {
                itemView(item)
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: false)
                    .frame(width: zoomedHeight, height: zoomedHeight + 60)
                    .modifier(FlipOpacity(angle: flipAngle, type: .front))

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .shadow(radius: 20)

                    VStack(alignment: .leading) {
                        HStack {
                            Spacer()
                            Button(action: { closeZoom() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }

                        detailContent(item)
                            .padding(.horizontal)
                            .padding(.bottom)
                    }
                }
                .frame(width: zoomedWidth, height: zoomedHeight)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .modifier(FlipOpacity(angle: flipAngle, type: .back))
            }
            .rotation3DEffect(
                .degrees(flipAngle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8
            )
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.6)) {
                    flipAngle = (flipAngle == 180) ? 0 : 180
                }
            }
        }
        .zIndex(100)
    }

    // MARK: - Logic Helpers

    private func handleExternalSelectionChange() {
        if let selected = selectedItem, zoomedItem?.id != selected.id {
           if zoomedItem != nil {
               closeZoom()
           }
        } else if selectedItem == nil && zoomedItem != nil {
            closeZoom()
        }

        // Scroll to selection if triggered externally (e.g. search)
        if let selected = selectedItem,
           let index = items.firstIndex(where: { $0.id == selected.id }) {
            let targetIndex = Double(index)
            if abs(scrollIndex - targetIndex) > 0.5 {
                // Duration proportional to distance, capped
                let distance = abs(scrollIndex - targetIndex)
                let duration = min(0.4, 0.15 + distance * 0.025)
                withAnimation(.easeOut(duration: duration)) {
                    scrollIndex = targetIndex
                }
            }
        }
    }

    /// Sync the isShowingDetail binding with internal zoomed state
    private func syncIsShowingDetail() {
        let isShowing = zoomedItem != nil && flipAngle >= 90
        isShowingDetail?.wrappedValue = isShowing
    }

    private func scrollToSelection() {
        if let selected = selectedItem, let index = items.firstIndex(where: { $0.id == selected.id }) {
            scrollIndex = Double(index)
        }
    }

    /// Handle tap on any carousel item
    /// - Tap any item: scroll to it and then zoom
    private func tapItem(_ item: Item, at itemIndex: Double, currentIndex: Double) {
        let isCentered = abs(round(currentIndex) - itemIndex) < 0.1

        if isCentered {
            // Already centered, zoom directly
            selectAndZoom(item)
        } else {
            // Scroll to item first, but DO NOT auto-zoom.
            // User can tap again to open if desired.
            let distance = abs(scrollIndex - itemIndex)
            let duration = min(0.3, 0.12 + distance * 0.03)

            withAnimation(.easeOut(duration: duration)) {
                scrollIndex = itemIndex
                selectedItem = item
            }
        }
    }

    /// Zoom to item with proper flip animation
    /// First shows the card front, then animates flip to back
    private func selectAndZoom(_ item: Item) {
        // Ensure flip starts from front
        flipAngle = 0

        // Show the zoomed card
        withAnimation(.easeOut(duration: 0.3)) {
            selectedItem = item
            zoomedItem = item
        }

        // After zoom-in completes, flip to show back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.5)) {
                flipAngle = 180
            }
        }
    }

    /// Close zoom and preserve scroll position on the selected item
    private func closeZoom() {
        // First flip back to front
        withAnimation(.easeInOut(duration: 0.4)) {
            flipAngle = 0
        }

        // Then dismiss the zoomed card
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let selected = selectedItem,
               let index = items.firstIndex(where: { $0.id == selected.id }) {
                withAnimation(.easeOut(duration: 0.3)) {
                    zoomedItem = nil
                    scrollIndex = Double(index)
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    zoomedItem = nil
                }
            }
        }
    }

    private func zIndex(for relativeIndex: Double) -> Double {
        return -abs(relativeIndex)
    }

    private func clamp(_ value: Double, _ min: Double, _ max: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

// MARK: - Button Style

struct CarouselButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}

// MARK: - Rotation Modifier

struct CoverFlowRotationModifier: ViewModifier {
    let progress: Double // relativeIndex
    let rotationMax: Double

    func body(content: Content) -> some View {
        // Rotation Logic
        // Transition: Scaled by 1.25 so it starts rotating as soon as it's within 0.8 distance
        let direction = max(-1, min(1, progress * 1.25))
        let rotationAngle = -rotationMax * direction

        return content
            .rotation3DEffect(
                .degrees(rotationAngle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
    }
}
