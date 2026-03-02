import EnsembleCore
import SwiftUI

/// Main sheet container for Now Playing interface
/// Uses native .sheet presentation with carousel layout
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @Environment(\.colorScheme) private var colorScheme
    
    // Page state (0: Queue, 1: Controls, 2: Lyrics)
    @State private var currentPage: Int = 1 // Start at Controls (center)
    
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
                    // Dismiss pill (tappable to close sheet)
                    dismissPill
                        .padding(.top, 28)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle()) // Expand tap area
                        .onTapGesture {
                            if let dismissAction = dismissAction {
                                dismissAction()
                            } else {
                                dismiss()
                            }
                        }
                    
                    // Layout: side-by-side on iPad/Mac, carousel on iPhone
                    if shouldUseSideBySideLayout(geometry: geometry) {
                        sideBySideLayout
                    } else {
                        NowPlayingCarousel(viewModel: viewModel, currentPage: $currentPage)
                    }
                }
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            // Base blurred artwork
            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                overlayColor: colorScheme == .dark ? .black : Color(uiColor: .systemBackground)
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)
            
            // Legibility overlay (adapts to light/dark mode)
            if colorScheme == .dark {
                Color.black.opacity(0.3)
                    .allowsHitTesting(false)
            } else {
                Color(uiColor: .systemBackground).opacity(0.5)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Dismiss Pill
    
    private var dismissPill: some View {
        Capsule()
            .fill(Color.primary.opacity(0.3))
            .frame(width: 36, height: 5)
    }
    
    // MARK: - iPad/Mac Side-by-Side Layout
    
    private var sideBySideLayout: some View {
        HStack(spacing: 0) {
            // Left: Controls card (fixed, primary focus)
            ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                .frame(maxWidth: 500) // Cap width for readability
            
            // Right: Carousel with Queue and Lyrics
            ZStack(alignment: .bottom) {
                TabView(selection: $currentPage) {
                    QueueCard(viewModel: viewModel, currentPage: $currentPage)
                        .tag(0)
                    
                    // Placeholder center slot (not shown in side-by-side)
                    Color.clear
                        .tag(1)
                    
                    LyricsCard(viewModel: viewModel, currentPage: $currentPage)
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: 500) // Cap width to match controls
                
                // Fixed page indicator for side-by-side carousel
                PageIndicator(currentPage: $currentPage)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
            }
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
}
