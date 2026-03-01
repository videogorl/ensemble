import EnsembleCore
import SwiftUI

/// Horizontal paging carousel managing three cards: Lyrics, Controls, Queue
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
        TabView(selection: $currentPage) {
            // Page 0: Lyrics (swipe left from center)
            LyricsCard(viewModel: viewModel, currentPage: $currentPage)
                .tag(0)
            
            // Page 1: Controls (center, default)
            ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                .tag(1)
            
            // Page 2: Queue (swipe right from center)
            QueueCard(viewModel: viewModel, currentPage: $currentPage)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never)) // Hide native page dots
        .onChange(of: currentPage) { newPage in
            handlePageChange(from: previousPage, to: newPage)
            previousPage = newPage
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
