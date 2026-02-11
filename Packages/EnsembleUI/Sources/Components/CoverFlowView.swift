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
    
    // Scroll & Drag State
    // offset now represents the "Virtual Index" (Float), not pixels.
    @State private var scrollIndex: Double = 0
    @State private var lastScrollIndex: Double = 0
    @GestureState private var dragIndexDelta: Double = 0
    
    // Zoom/Flip State
    @State private var flipAngle: Double = 0
    @State private var zoomedItem: Item? = nil
    @Namespace private var animation

    // Press feedback state
    @State private var pressedItemId: Item.ID? = nil
    
    // Configuration
    private let rotationMax: Double = 65
    
    var body: some View {
        GeometryReader { geometry in
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
                }
                
                // Zoomed Card Layer
                if let item = zoomedItem {
                   zoomedCardLayer(item: item, geometry: geometry)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onChange(of: selectedItem?.id) { _ in
            handleExternalSelectionChange()
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
        let wingSpacing = itemWidth * 0.39 // Even tighter stacking
        let centerGap = itemWidth * 0.30   // Much closer to center
        
        // Configuration
        let rotationMax: Double = 60 // Slightly reduced angle
        let currentIndex = scrollIndex + dragIndexDelta
        
        return ZStack {
            // Background touch area for gesture
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragIndexDelta) { value, state, _ in
                            // Sensitivity: one full swipe across 40% of screen width = ~2.5 items
                            let sensitivity = 1.0 / (geometry.size.width * 0.4)
                            state = -value.translation.width * sensitivity
                        }
                        .onEnded { value in
                            handleDragEnd(value: value, geometry: geometry)
                        }
                )
            
            // Render visible items
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let i = Double(index)
                let relativeIndex = i - currentIndex
                
                // Optimization: render only items reasonably close
                if abs(relativeIndex) < 20 {
                    
                    // Non-Linear Position Logic
                    // Base: i * wingSpacing
                    // Shift: + Gap if i > 0, - Gap if i < 0
                    // Smooth transition using clamp
                    
                    let linearX = relativeIndex * wingSpacing
                    let gapShift = clamp(relativeIndex, -1, 1) * centerGap
                    let finalX = linearX + gapShift
                    
                    // Scale Logic: Center item is 33% bigger, plus press feedback
                    let baseScale = 1.0 + (0.33 * max(0, 1 - abs(relativeIndex)))
                    let pressScale: CGFloat = pressedItemId == item.id ? 0.95 : 1.0
                    let scale = baseScale * pressScale

                    ZStack {
                        itemView(item)
                            .frame(width: itemWidth, height: itemHeight)
                    }
                    .frame(width: itemWidth, height: itemHeight)
                    .scaleEffect(scale)
                    .animation(.easeInOut(duration: 0.1), value: pressedItemId)
                    .modifier(
                        CoverFlowRotationModifier(
                            progress: relativeIndex,
                            rotationMax: rotationMax
                        )
                    )
                    .opacity(zoomedItem?.id == item.id ? 0 : 1)
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: true)
                    .offset(x: finalX)
                    .zIndex(zIndex(for: relativeIndex))
                    .contentShape(Rectangle())
                    // Press feedback gesture
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if pressedItemId != item.id {
                                    pressedItemId = item.id
                                }
                            }
                            .onEnded { _ in
                                pressedItemId = nil
                            }
                    )
                    .onTapGesture {
                        tapItem(item, at: i, currentIndex: currentIndex)
                    }
                }
            }
        }
        .frame(height: carouselHeight)
        .position(x: geometry.size.width / 2, y: geometry.size.height / 2) // Center the track
        .onAppear {
            scrollToSelection()
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
    
    private func handleDragEnd(value: DragGesture.Value, geometry: GeometryProxy) {
        // Sensitivity matches the updating closure: 40% of screen width = 1 item
        let sensitivity = 1.0 / (geometry.size.width * 0.4)

        let dragDelta = -value.translation.width * sensitivity
        // Less dampening (0.3) preserves more natural momentum
        let predictedDelta = -value.predictedEndTranslation.width * sensitivity * 0.3

        let targetIndex = scrollIndex + dragDelta + predictedDelta

        // Clamp to valid indices
        let clampedIndex = max(0, min(Double(items.count - 1), round(targetIndex)))

        // Softer spring for smoother deceleration
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            scrollIndex = clampedIndex
            lastScrollIndex = scrollIndex
        }

        // Update selection if we snapped to a new item
        let index = Int(clampedIndex)
        if index >= 0 && index < items.count {
            selectedItem = items[index]
        }
    }
    
    private func handleExternalSelectionChange() {
        if let selected = selectedItem, zoomedItem?.id != selected.id {
           if zoomedItem != nil {
               closeZoom()
           }
        } else if selectedItem == nil && zoomedItem != nil {
            closeZoom()
        }

        // Scroll to selection if triggered externally (e.g. search)
        // Only scroll if significantly different from current position to avoid interrupting swipes
        if let selected = selectedItem,
           let index = items.firstIndex(where: { $0.id == selected.id }) {
            let targetIndex = Double(index)
            if abs(scrollIndex - targetIndex) > 0.5 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    scrollIndex = targetIndex
                    lastScrollIndex = scrollIndex
                }
            }
        }
    }
    
    private func scrollToSelection() {
        if let selected = selectedItem, let index = items.firstIndex(where: { $0.id == selected.id }) {
            scrollIndex = Double(index)
            lastScrollIndex = scrollIndex
        }
    }
    
    /// Handle tap on any carousel item
    /// - If already centered: zoom immediately
    /// - If not centered: scroll to it, then zoom after animation completes
    private func tapItem(_ item: Item, at itemIndex: Double, currentIndex: Double) {
        let isCentered = round(currentIndex) == itemIndex

        if isCentered {
            // Already centered, zoom directly
            selectAndZoom(item)
        } else {
            // Scroll to item first
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                scrollIndex = itemIndex
                lastScrollIndex = scrollIndex
                selectedItem = item
            }
            // Zoom after scroll animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                selectAndZoom(item)
            }
        }
    }

    private func selectAndZoom(_ item: Item) {
        withAnimation(.easeInOut(duration: 0.6)) {
            selectedItem = item
            zoomedItem = item
            flipAngle = 180
        }
    }
    
    /// Close zoom and preserve scroll position on the selected item
    private func closeZoom() {
        if let selected = selectedItem,
           let index = items.firstIndex(where: { $0.id == selected.id }) {
            // Ensure carousel stays on the selected item
            withAnimation(.easeInOut(duration: 0.5)) {
                flipAngle = 0
                zoomedItem = nil
                scrollIndex = Double(index)
                lastScrollIndex = scrollIndex
            }
        } else {
            withAnimation(.easeInOut(duration: 0.5)) {
                flipAngle = 0
                zoomedItem = nil
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
