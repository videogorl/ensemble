import SwiftUI

/// A 3D carousel view that displays items in a CoverFlow-style layout
/// with perspective rotation and scaling based on distance from center.
/// Includes an inline content area below for displaying details of the selected item.
struct CoverFlowView<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    let itemView: (Item) -> ItemView
    let detailContent: (Item?) -> AnyView
    @Binding var selectedItem: Item?
    
    private let perspectiveAngle: Double = 45
    
    @State private var scrollOffset: CGFloat = 0
    @Namespace private var animation
    
    var body: some View {
        GeometryReader { geometry in
            // Calculate responsive sizes based on available space
            let isLandscape = geometry.size.width > geometry.size.height
            let carouselHeightFraction: CGFloat = isLandscape ? 0.55 : 0.6
            let carouselHeight = geometry.size.height * carouselHeightFraction
            
            // Item size scales with available carousel height
            let itemHeight = max(120, min(carouselHeight * 0.85, 220))
            let itemWidth = itemHeight
            let spacing = itemHeight * 0.15
            
            VStack(spacing: 0) {
                // CoverFlow carousel
                ScrollView(.horizontal, showsIndicators: false) {
                    // Disable vertical scrolling bounce
                    Color.clear
                        .frame(height: 0)
                        .allowsHitTesting(false)
                    ScrollViewReader { proxy in
                        HStack(spacing: spacing) {
                            // Leading spacer to center first item
                            Color.clear
                                .frame(width: (geometry.size.width - itemWidth) / 2)
                            
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                                selectedItem = (selectedItem?.id == item.id) ? nil : item
                                                proxy.scrollTo(item.id, anchor: .center)
                                            }
                                        }
                                        .id(item.id)
                                }
                                .frame(width: itemWidth, height: itemHeight)
                            }
                            
                            // Trailing spacer to center last item
                            Color.clear
                                .frame(width: (geometry.size.width - itemWidth) / 2)
                        }
                        .onAppear {
                            // Scroll to first item on appear
                            if let firstItem = items.first {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    proxy.scrollTo(firstItem.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .frame(height: carouselHeight)
                .simultaneousGesture(
                    // Prevent vertical scrolling from affecting carousel
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in }
                )
                
                // Detail content area (inline track list)
                if selectedItem != nil {
                    detailContent(selectedItem)
                        .frame(maxHeight: geometry.size.height * 0.4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer()
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
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
