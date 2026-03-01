import EnsembleCore
import SwiftUI

/// Main sheet container for Now Playing interface
/// Manages presentation, dismissal, blurred background, and embeds carousel
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @Environment(\.colorScheme) private var colorScheme
    
    // Page state (0: Lyrics, 1: Controls, 2: Queue)
    @State private var currentPage: Int = 1 // Start at Controls (center)
    
    // Interactive dismissal
    @State private var dragOffset: CGFloat = 0
    
    private let namespace: Namespace.ID?
    private let animationID: String?
    private let dismissAction: (() -> Void)?
    
    public init(
        viewModel: NowPlayingViewModel,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.namespace = namespace
        self.animationID = animationID
        self.dismissAction = dismissAction
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Blurred artwork background with legibility overlay
                backgroundView
                
                VStack(spacing: 0) {
                    // Dismiss pill
                    dismissPill
                        .padding(.top, 8)
                    
                    // Layout: side-by-side on iPad/Mac, carousel on iPhone
                    if shouldUseSideBySideLayout(geometry: geometry) {
                        sideBySideLayout
                    } else {
                        NowPlayingCarousel(viewModel: viewModel, currentPage: $currentPage)
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        // Track vertical drag for dismissal
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        // Dismiss if dragged down sufficiently
                        if value.translation.height > 150 || value.velocity.height > 800 {
                            handleDismiss()
                        } else {
                            // Snap back
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .offset(y: dragOffset)
            .applyPresentationModifiers()
            .ignoresSafeArea(edges: .bottom)
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            // Base blurred artwork
            BlurredArtworkBackground(image: viewModel.artworkImage)
                .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)
            
            // Legibility overlay (adapts to light/dark mode)
            Color.black.opacity(colorScheme == .dark ? 0.3 : 0.5)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Dismiss Pill
    
    private var dismissPill: some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: 36, height: 5)
    }
    
    // MARK: - iPad/Mac Side-by-Side Layout
    
    private var sideBySideLayout: some View {
        HStack(spacing: 0) {
            // Left: Controls card (fixed, primary focus)
            ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                .frame(maxWidth: 500) // Cap width for readability
            
            // Right: Carousel with Queue and Lyrics
            TabView(selection: $currentPage) {
                LyricsCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(0)
                
                // Placeholder center slot (not shown in side-by-side)
                Color.clear
                    .tag(1)
                
                QueueCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: 500) // Cap width to match controls
        }
    }
    
    private func shouldUseSideBySideLayout(geometry: GeometryProxy) -> Bool {
        // Use side-by-side when horizontal size class is regular (iPad)
        // or on macOS (always side-by-side)
        #if os(macOS)
        return true
        #else
        // iPad in landscape or split view
        return geometry.size.width > 768
        #endif
    }
    
    // MARK: - Helpers
    
    private func handleDismiss() {
        if let dismissAction = dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }
}

// MARK: - iOS 16+ Presentation Modifier Extension

extension View {
    @ViewBuilder
    func applyPresentationModifiers() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
