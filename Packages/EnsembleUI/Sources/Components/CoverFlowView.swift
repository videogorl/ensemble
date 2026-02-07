import SwiftUI
import NukeUI

struct CoverFlowView<Item, Content: View, DetailContent: View>: View where Item: Identifiable & Equatable {
    let items: [Item]
    let itemView: (Item) -> Content
    let detailContent: (Item?) -> DetailContent
    let titleContent: (Item) -> String?
    let subtitleContent: (Item) -> String?
    @Binding var selectedItem: Item?
    
    // Config
    private let spacing: CGFloat = -40
    private let angle: Double = 60
    private let centerGap: CGFloat = 80
    
    @State private var scrollIndex: Double = 0
    @State private var dragOffset: Double = 0
    @State private var isFlipped = false
    @Namespace private var nspace
    
    // Haptics
    #if os(iOS)
    private let feedback = UISelectionFeedbackGenerator()
    #endif
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cardWidth = width * 0.55
            let height = geo.size.height
            
            // Vertical stack to include Title/Subtitle below
            ZStack {
                // Background Tap to dismiss
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedItem != nil {
                            closeZoom()
                        }
                    }
                
                VStack(spacing: 20) {
                    Spacer()
                    
                    // CAROUSEL AREA
                    ZStack {
                        carouselLayer(width: width, cardWidth: cardWidth, height: height * 0.6)
                            .zIndex(1)
                        
                        // Zoomed Layer (Overlay)
                        if let sItem = selectedItem {
                            zoomedCardLayer(item: sItem, width: width, height: height, cardWidth: cardWidth)
                                .zIndex(100)
                                .transition(.opacity)
                        }
                    }
                    .frame(height: height * 0.6)
                    
                    // TITLES (Hidden when zoomed)
                    if selectedItem == nil {
                        VStack(spacing: 4) {
                            let currentIndex = Int(round(scrollIndex))
                            if items.indices.contains(currentIndex) {
                                let item = items[currentIndex]
                                
                                Text(titleContent(item) ?? " ")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                                
                                Text(subtitleContent(item) ?? " ")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(" ") 
                                Text(" ")
                            }
                        }
                        .padding(.bottom, 40)
                        .transition(.opacity)
                    }
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Carousel Layer
    private func carouselLayer(width: CGFloat, cardWidth: CGFloat, height: CGFloat) -> some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let relativeIndex = Double(index) - (scrollIndex + dragOffset)
                let zIndex = -abs(relativeIndex)
                
                // Don't render if far off screen
                if abs(relativeIndex) < 5 {
                    let properties = calculateCardProperties(
                        relativeIndex: relativeIndex,
                        cardWidth: cardWidth,
                        containerWidth: width
                    )
                    
                    itemView(item)
                        .frame(width: cardWidth, height: cardWidth)
                        .rotation3DEffect(
                            .degrees(properties.angle),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: properties.anchor,
                            perspective: 0.5
                        )
                        .offset(x: properties.xOffset)
                        .scaleEffect(properties.scale)
                        .zIndex(zIndex)
                        .opacity(selectedItem == item ? 0 : 1)
                        .matchedGeometryEffect(id: item.id, in: nspace, isSource: true)
                        .onTapGesture {
                            handleTap(at: index, item: item)
                        }
                }
            }
        }
        .frame(width: width, height: height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if selectedItem != nil { closeZoom() }
                    
                    let horizontalDivisor = cardWidth * 0.7
                    dragOffset = -value.translation.width / horizontalDivisor
                }
                .onEnded { value in
                    let horizontalDivisor = cardWidth * 0.7
                    let sensitivity: CGFloat = 0.2
                    let velocity = (-value.predictedEndTranslation.width / horizontalDivisor) * sensitivity
                    
                    let currentRaw = scrollIndex + dragOffset
                    var nextIndex = (currentRaw + velocity).rounded()
                    nextIndex = max(0, min(Double(items.count - 1), nextIndex))
                    
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        scrollIndex = nextIndex
                        dragOffset = 0
                    }
                    
                    if abs(nextIndex - scrollIndex) > 0.1 {
                        #if os(iOS)
                        feedback.selectionChanged()
                        #endif
                    }
                }
        )
    }
    
    // MARK: - Zoomed Card Layer
    private func zoomedCardLayer(item: Item, width: CGFloat, height: CGFloat, cardWidth: CGFloat) -> some View {
        let expandedWidth = width * 0.85
        // Removed unused expandedHeight
        
        return ZStack {
            
            ZStack {
                // BACK (Details)
                if isFlipped {
                    backCardView(item: item, width: expandedWidth, height: expandedWidth) 
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                
                // FRONT (Artwork)
                if !isFlipped {
                    itemView(item)
                        .frame(width: expandedWidth, height: expandedWidth)
                        .matchedGeometryEffect(id: item.id, in: nspace, isSource: false)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                isFlipped.toggle()
                            }
                        }
                }
            }
            .rotation3DEffect(
                .degrees(isFlipped ? 180 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.identity)
    }
    
    private func backCardView(item: Item, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Material.regular)
            
            VStack(spacing: 0) {
                ScrollView {
                    detailContent(item) 
                        .padding()
                }
            }
        }
        .frame(width: width, height: height * 1.5) 
        .frame(maxHeight: 500) 
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.spring()) {
                    isFlipped = false
                }
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }
    
    // MARK: - Logic
    
    private func handleTap(at index: Int, item: Item) {
        if index == Int(scrollIndex) || abs(Double(index) - scrollIndex) < 0.5 {
            // Tap center -> Zoom
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                selectedItem = item
                isFlipped = false
            }
        } else {
            // Tap side -> Scroll to
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                scrollIndex = Double(index)
                selectedItem = nil
                isFlipped = false
            }
        }
    }
    
    private func closeZoom() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            selectedItem = nil
            isFlipped = false
        }
    }
    
    private struct CardProperties {
        let xOffset: CGFloat
        let scale: CGFloat
        let angle: Double
        let anchor: UnitPoint
    }
    
    private func calculateCardProperties(relativeIndex: Double, cardWidth: CGFloat, containerWidth: CGFloat) -> CardProperties {
        let sign = relativeIndex >= 0 ? 1.0 : -1.0
        let absRel = abs(relativeIndex)
        
        // Angle
        var continuousAngle = 0.0
        if absRel < 1 {
            continuousAngle = -relativeIndex * angle
        } else {
            continuousAngle = sign * -angle
        }
        
        // Offset
        let stackSpacing: CGFloat = 40
        let firstStepSize = (cardWidth * 0.5) + (centerGap * 0.5)
        
        var continuousOffset: CGFloat = 0
        if absRel <= 1 {
            continuousOffset = relativeIndex * firstStepSize
        } else {
            let baseParams = sign * firstStepSize
            let stackParams = sign * (absRel - 1) * stackSpacing
            continuousOffset = baseParams + stackParams
        }
        
        // Anchor
        let anchorX = relativeIndex > 0 ? 0.0 : 1.0
        
        return CardProperties(
            xOffset: continuousOffset,
            scale: 1.0,
            angle: continuousAngle,
            anchor: UnitPoint(x: anchorX, y: 0.5)
        )
    }
}
