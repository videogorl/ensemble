import SwiftUI

/// A 3D carousel view that displays items in a CoverFlow-style layout
/// with perspective rotation and scaling based on distance from center.
/// Tapping an item zooms it in and flips it to reveal details.
struct CoverFlowView<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    let itemView: (Item) -> ItemView
    let detailContent: (Item?) -> AnyView
    @Binding var selectedItem: Item?
    
    // Zoom/Flip State
    @State private var flipAngle: Double = 0
    @State private var zoomedItem: Item? = nil
    @Namespace private var animation
    
    private let perspectiveAngle: Double = 45
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background Carousel Layer
                carouselLayer(geometry: geometry)
                    .blur(radius: zoomedItem != nil ? 15 : 0) // Reduced blur slightly
                    .opacity(zoomedItem != nil ? 0 : 1) // Fade out completely to avoid ghosting behind zoomed card
                    .animation(.easeInOut(duration: 0.3), value: zoomedItem != nil)
                    .allowsHitTesting(zoomedItem == nil)
                
                // Zoomed Card Layer
                if let item = zoomedItem {
                    zoomedCardLayer(item: item, geometry: geometry)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onChange(of: selectedItem?.id) { _ in
            // Sync external selection with internal zoom state
            if let selected = selectedItem, zoomedItem?.id != selected.id {
                // Trigger Zoom AND Flip simultaneously
                print("CoverFlow: Selection triggering simultaneous zoom & flip")
                withAnimation(.easeInOut(duration: 0.6)) {
                    zoomedItem = selected
                    flipAngle = 180
                }
            } else if selectedItem == nil && zoomedItem != nil {
                closeZoom()
            }
        }
    }
    
    // MARK: - Carousel Layer
    
    private func carouselLayer(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        // Increase fraction to make items larger (was 0.55 -> 0.65 -> 0.8)
        let carouselHeightFraction: CGFloat = isLandscape ? 0.8 : 0.85
        let carouselHeight = geometry.size.height * carouselHeightFraction
        
        // Remove 220 cap, allow scaling up to 400 or just based on screen
        // Calculate item size based on Artwork 1:1 + Text space
        // Let's target artwork height = 75% of carousel height
        let artworkSize = carouselHeight * 0.75
        let itemWidth = artworkSize
        let itemHeight = artworkSize + 60 // Add fixed space for text below artwork
        
        let spacing = itemWidth * 0.2
        
        return VStack(spacing: 0) {
            Spacer()
            
            ScrollView(.horizontal, showsIndicators: false) {
                Color.clear.frame(height: 0).allowsHitTesting(false)
                
                ScrollViewReader { proxy in
                    HStack(spacing: spacing) {
                        Color.clear.frame(width: (geometry.size.width - itemWidth) / 2)
                        
                        ForEach(items) { item in
                            GeometryReader { itemGeometry in
                                itemView(item)
                                    .frame(width: itemWidth, height: itemHeight)
                                    .modifier(
                                        CoverFlowItemModifier(
                                            progress: calculateProgress(
                                                itemGeometry: itemGeometry,
                                                parentGeometry: geometry,
                                                itemWidth: itemWidth,
                                                spacing: spacing
                                            ),
                                            angle: perspectiveAngle
                                        )
                                    )
                                    .opacity(zoomedItem?.id == item.id ? 0 : 1) // Hide source item when zoomed
                                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: true)
                                    .onTapGesture {
                                        selectAndZoom(item, proxy: proxy)
                                    }
                            }
                            .frame(width: itemWidth, height: itemHeight)
                        }
                        
                        Color.clear.frame(width: (geometry.size.width - itemWidth) / 2)
                    }
                    .onAppear {
                        if let first = items.first {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(first.id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(height: carouselHeight)
            // .background(Color.red.opacity(0.1)) // Debug frame
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in })
            
            Spacer()
        }
    }
    
    // MARK: - Zoomed Card Layer
    
    private func zoomedCardLayer(item: Item, geometry: GeometryProxy) -> some View {
        // Card size in zoomed state (85% of screen height)
        let zoomedHeight = geometry.size.height * 0.85
        // Width should match the expanded track list card width
        // If we use square initially, the flip transition stretches the width if we aren't careful.
        // Let's use a width that works for both or animate width.
        // Track list card is wide (aspect 1.5). Artwork is square (aspect 1.0).
        // Best approach: Animate width during flip?
        // Or just keep the container wide and center the square artwork?
        let zoomedWidth = zoomedHeight * 1.5 // Target width for the "Back" chart
        
        return ZStack {
            Color.black.opacity(0.01) // Invisible dismiss tap area
                .onTapGesture {
                    closeZoom()
                }
            
            // The Flipping Container
            ZStack {
                // Front (Artwork)
                // Visible when NOT flipped (0-90 deg)
                itemView(item)
                    // We need to force the frame here to match the "Carousel Item" aspect/layout
                    // But simpler: just show the artwork big and square?
                    // Re-using 'itemView' includes text.
                    // matchedGeometry moves the whole 'itemView'.
                    .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: false)
                    .frame(width: zoomedHeight, height: zoomedHeight + 60) // Maintain aspectish
                    .flipOpacity(angle: flipAngle, type: .front) // Use custom modifier
                
                // Back (Details)
                // Visible when flipped (90-180 deg)
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
                .flipOpacity(angle: flipAngle, type: .back) // Use custom modifier
            }
            .rotation3DEffect(
                .degrees(flipAngle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8
            )
            .onTapGesture {
                // Toggle flip on card tap
                withAnimation(.easeInOut(duration: 0.6)) {
                    flipAngle = (flipAngle == 180) ? 0 : 180
                }
            }
        }
        .zIndex(100)
    }

    // MARK: - Helpers
    
    private func selectAndZoom(_ item: Item, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.6)) {
            selectedItem = item
            zoomedItem = item
            // Simultaneous Flip
            flipAngle = 180
            proxy.scrollTo(item.id, anchor: .center)
        }
    }
    
    private func closeZoom() {
        withAnimation(.easeInOut(duration: 0.5)) {
            flipAngle = 0
            zoomedItem = nil
            selectedItem = nil
        }
    }
    
    /// Calculate the progress of an item (-1 = left, 0 = center, 1 = right)
    private func calculateProgress(
        itemGeometry: GeometryProxy,
        parentGeometry: GeometryProxy,
        itemWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let itemCenter = itemGeometry.frame(in: .global).midX
        let parentCenter = parentGeometry.frame(in: .global).midX
        let distance = itemCenter - parentCenter
        let normalizedDistance = distance / (itemWidth + spacing)
        return normalizedDistance
    }
}

/// Modifier that applies 3D rotation and scaling based on distance from center
struct CoverFlowItemModifier: ViewModifier {
    let progress: CGFloat
    let angle: Double
    
    func body(content: Content) -> some View {
        let absProgress = abs(progress)
        
        // Scale down items as they move away from center
        let scale = 1.0 - (absProgress * 0.3)
        
        // Rotate items based on position (left items rotate right, right items rotate left)
        let rotation = progress * angle
        
        // Fade out items far from center
        let opacity = 1.0 - (absProgress * 0.5)
        
        // Z-axis offset for 3D perspective
        let zOffset = absProgress * -100
        
        return content
            .scaleEffect(max(0.7, scale))
            .rotation3DEffect(
                .degrees(rotation),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .opacity(max(0.3, opacity))
            .zIndex(1.0 - Double(absProgress))
            .transformEffect(CGAffineTransform(translationX: 0, y: zOffset * 0.1))
    }
}

// MARK: - Preview

struct CoverFlowView_Previews: PreviewProvider {
    struct PreviewItem: Identifiable {
        let id = UUID()
        let title: String
        let color: Color
    }
    
    static var previews: some View {
        CoverFlowView(
            items: [
                PreviewItem(title: "Album 1", color: .red),
                PreviewItem(title: "Album 2", color: .blue),
                PreviewItem(title: "Album 3", color: .green),
                PreviewItem(title: "Album 4", color: .orange),
                PreviewItem(title: "Album 5", color: .purple),
            ],
            itemView: { item in
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.color)
                    .overlay(
                        Text(item.title)
                            .foregroundColor(.white)
                            .bold()
                    )
            },
            detailContent: { item in
                if let item = item {
                    AnyView(
                        VStack {
                            Text("Selected: \(item.title)")
                                .font(.headline)
                                .padding()
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.1))
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            selectedItem: .constant(nil)
        )
        .background(Color.black)
    }
}
