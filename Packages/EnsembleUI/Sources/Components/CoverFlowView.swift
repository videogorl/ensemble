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
    @State private var isFlipped = false
    @State private var zoomedItem: Item? = nil
    @Namespace private var animation
    
    private let perspectiveAngle: Double = 45
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background Carousel Layer
                carouselLayer(geometry: geometry)
                    .blur(radius: zoomedItem != nil ? 20 : 0)
                    .opacity(zoomedItem != nil ? 0.3 : 1)
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
                print("CoverFlow: Selection changed externally, triggering zoom")
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    zoomedItem = selected
                    // Small delay for flip to allow zoom to start
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                         withAnimation(.easeInOut(duration: 0.6)) {
                             isFlipped = true
                         }
                    }
                }
            } else if selectedItem == nil && zoomedItem != nil {
                closeZoom()
            }
        }
    }
    
    // MARK: - Carousel Layer
    
    private func carouselLayer(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let carouselHeightFraction: CGFloat = isLandscape ? 0.55 : 0.6
        let carouselHeight = geometry.size.height * carouselHeightFraction
        
        let itemHeight = max(120, min(carouselHeight * 0.85, 220))
        let itemWidth = itemHeight
        let spacing = itemHeight * 0.15
        
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
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in })
            
            Spacer()
        }
    }
    
    // MARK: - Zoomed Card Layer
    
    private func zoomedCardLayer(item: Item, geometry: GeometryProxy) -> some View {
        // Card size in zoomed state (85% of screen height)
        let zoomedHeight = geometry.size.height * 0.85
        let zoomedWidth = zoomedHeight // Keep centered aspect ratio for front, expand for back if needed
        
        return ZStack {
            Color.black.opacity(0.01) // Invisible dismiss tap area
                .onTapGesture {
                    closeZoom()
                }
            
            ZStack {
                // Front (Artwork)
                if !isFlipped {
                    itemView(item)
                        .matchedGeometryEffect(id: item.id, in: animation, properties: .position, isSource: false)
                        .frame(width: zoomedWidth, height: zoomedHeight)
                        .transition(.identity)
                }
                
                // Back (Details)
                if isFlipped {
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
                    // Widen the card for track list
                    .frame(width: zoomedWidth * 1.5, height: zoomedHeight)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
            }
            .rotation3DEffect(
                .degrees(isFlipped ? 180 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8
            )
            .onTapGesture {
                // Toggle flip on card tap
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    isFlipped.toggle()
                }
            }
        }
        .zIndex(100)
    }

    // MARK: - Helpers
    
    private func selectAndZoom(_ item: Item, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            selectedItem = item
            zoomedItem = item
            proxy.scrollTo(item.id, anchor: .center)
        }
        
        // Auto-flip after zoom completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                if zoomedItem?.id == item.id {
                    isFlipped = true
                }
            }
        }
    }
    
    private func closeZoom() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            isFlipped = false
        }
        
        // Wait for flip back before zooming out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                zoomedItem = nil
                selectedItem = nil
            }
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
