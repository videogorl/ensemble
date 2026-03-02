import EnsembleCore
import SwiftUI

/// Horizontal paging carousel managing three cards: Queue, Controls, Lyrics
/// Opens to Controls (center) by default
public struct NowPlayingCarousel: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    
    // Track previous page for haptic feedback
    @State private var previousPage: Int = 1
    
    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                // Page 0: Queue (swipe left from center)
                QueueCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(0)
                
                // Page 1: Controls (center, default)
                ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(1)
                
                // Page 2: Lyrics (swipe right from center)
                LyricsCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide native page dots
            .onChange(of: currentPage) { newPage in
                handlePageChange(from: previousPage, to: newPage)
                previousPage = newPage
            }
            
            // Fixed page indicator overlay
            PageIndicator(currentPage: $currentPage)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
    }
    
    // MARK: - Helpers
    
    private func handlePageChange(from oldPage: Int, to newPage: Int) {
        // Fire haptic feedback on page change
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}
