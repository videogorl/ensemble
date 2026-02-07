import SwiftUI

/// A 3D carousel view that displays items in a CoverFlow-style layout
/// with perspective rotation and scaling based on distance from center.
/// Tapping an item zooms it in and flips it to reveal details.
struct CoverFlowView<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    let itemView: (Item) -> ItemView
    let detailContent: (Item?) -> AnyView
    @Binding var selectedItem: Item?
    
    // Scroll & Drag State
    @State private var offset: CGFloat = 0
    @State private var lastOffset: CGFloat = 0 // Tracks offset before current drag
    @GestureState private var dragOffset: CGFloat = 0
    
    // Zoom/Flip State
    @State private var flipAngle: Double = 0
    @State private var zoomedItem: Item? = nil
    @Namespace private var animation
    
    // Configuration
    private let rotationMax: Double = 55
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background Carousel Layer
                carouselLayer(geometry: geometry)
                    .blur(radius: zoomedItem != nil ? 15 : 0)
                    .opacity(zoomedItem != nil ? 0 : 1)
                    .allowsHitTesting(zoomedItem == nil)
                
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
        let itemSize = carouselHeight * 0.70
        let itemWidth = itemSize
        let itemHeight = itemSize + 60 // Fixed space for text
        
        // Spacing: Classic iPod style has tight stacking (~30-40% of width)
        let spacing = itemWidth * 0.45
        
        // Current virtual scroll position (including active drag)
        let currentScrollOffset = offset + dragOffset
        
        // Calculate current index for Z-index optimization
        let centerIndex = -currentScrollOffset / spacing
        
        return ZStack {
            // Background touch area for gesture
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.width
                        }
                        .onEnded { value in
                            handleDragEnd(value: value, spacing: spacing)
                        }
                )
            
            // Render visible items
            // We use a simplified ZStack with manual offsets + Z-Index
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // Optimization: window rendering (render only items close to center)
                // Expanding window to 20 to be safe
                if abs(Double(index) - centerIndex) < 20 {
                    // Position calculation
                    let itemPosition = (CGFloat(index) * spacing) + currentScrollOffset
                    let progress = itemPosition / spacing
                    
                    ZStack {
                        itemView(item)
                            .frame(width: itemWidth, height: itemHeight)
                    }
                    .frame(width: itemWidth, height: itemHeight)
                    .modifier(
                        CoverFlowRotationModifier(
                            progress: progress,
                            rotationMax: rotationMax
                        )
                    )
                    // STABILITY: Opacity handles visibility for zoom logic, keep view in hierarchy
                    .opacity(zoomedItem?.id == item.id ? 0 : 1)
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: true)
                    .offset(x: itemPosition) // Manual placement
                    .zIndex(zIndex(for: progress)) // Ensure center items are on top
                    .onTapGesture {
                        if round(centerIndex) == Double(index) {
                            selectAndZoom(item)
                        } else {
                            // Tap neighbor to scroll to it
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                                offset = CGFloat(-index) * spacing
                                lastOffset = offset
                                selectedItem = item
                            }
                        }
                    }
                }
            }
        }
        .frame(height: carouselHeight)
        .position(x: geometry.size.width / 2, y: geometry.size.height / 2) // Center the track
        .onAppear {
            // Layout initialization
            scrollToSelection(spacing: spacing)
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
                // Front (Artwork)
                itemView(item)
                    // .matchedGeometryEffect with isSource: false makes this view fly from carousel position
                    // BUT we only want it to animate the position transition, not lock it
                    // Using simple matchedGeometryEffect works but requires careful implementation
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: false)
                    .frame(width: zoomedHeight, height: zoomedHeight + 60)
                    .modifier(FlipOpacity(angle: flipAngle, type: .front))
                
                // Back (Details)
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
    
    private func handleDragEnd(value: DragGesture.Value, spacing: CGFloat) {
        // momentum prediction logic
        let predictedEndOffset = offset + value.translation.width + (value.predictedEndTranslation.width * 0.5)
        let exactIndex = -predictedEndOffset / spacing
        
        // Clamp to valid indices
        let clampedIndex = max(0, min(Double(items.count - 1), round(exactIndex)))
        
        // Snap
        let targetOffset = CGFloat(-clampedIndex) * spacing
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            offset = targetOffset
            lastOffset = offset
        }
        
        // Update selection if we snapped to a new item
        let index = Int(clampedIndex)
        if index >= 0 && index < items.count {
            selectedItem = items[index]
        }
    }
    
    private func handleExternalSelectionChange() {
        if let selected = selectedItem, zoomedItem?.id != selected.id {
            // Trigger Zoom AND Flip simultaneously if not already zoomed
            withAnimation(.easeInOut(duration: 0.6)) {
                zoomedItem = selected
                flipAngle = 180
            }
        } else if selectedItem == nil && zoomedItem != nil {
            closeZoom()
        }
    }
    
    private func scrollToSelection(spacing: CGFloat) {
        if let selected = selectedItem, let index = items.firstIndex(where: { $0.id == selected.id }) {
            offset = CGFloat(-index) * spacing
            lastOffset = offset
        }
    }
    
    private func selectAndZoom(_ item: Item) {
        withAnimation(.easeInOut(duration: 0.6)) {
            selectedItem = item
            zoomedItem = item
            flipAngle = 180
        }
    }
    
    private func closeZoom() {
        withAnimation(.easeInOut(duration: 0.5)) {
            flipAngle = 0
            zoomedItem = nil
            selectedItem = nil
        }
    }
    
    private func zIndex(for progress: CGFloat) -> Double {
        // Items closer to center (progress 0) should be on top
        // ZIndex = -|distance|
        return -abs(Double(progress))
    }
}

// MARK: - Rotation Modifier

struct CoverFlowRotationModifier: ViewModifier {
    let progress: CGFloat
    let rotationMax: Double
    
    func body(content: Content) -> some View {
        // Rotation Logic based on Store Shelf style
        // Center (0): 0 degrees
        // Transition: Steep clamp around 0.5 distance
        
        let direction = max(-1, min(1, progress * 2.5))
        
        // If direction is negative (left), we want POSITIVE rotation (+55).
        // If direction is positive (right), we want NEGATIVE rotation (-55).
        let rotationAngle = -rotationMax * Double(direction)
        
        // Optional: Push neighbors back in Z space
        
        return content
            .rotation3DEffect(
                .degrees(rotationAngle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
    }
}
