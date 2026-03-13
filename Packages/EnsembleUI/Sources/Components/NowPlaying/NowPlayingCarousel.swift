import EnsembleCore
import SwiftUI

/// Horizontal paging carousel managing four cards: Queue, Controls, Lyrics, Info
/// Opens to Controls by default
public struct NowPlayingCarousel: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

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
                LyricsCard(viewModel: viewModel, currentPage: $currentPage, isLowPowerMode: powerStateMonitor.isLowPowerMode)
                    .tag(2)

                // Page 3: Info (far right)
                InfoCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide native page dots
            // Manual paging gesture — TabView's built-in paging doesn't
            // receive swipes that start on Buttons or other interactive
            // elements. This gesture bridges the gap across all cards.
            .simultaneousGesture(cardPagingGesture)
            .onChange(of: currentPage) { newPage in
                handlePageChange(from: previousPage, to: newPage)
                previousPage = newPage
            }

            // Fixed page indicator overlay — lyrics icon reflects availability
            PageIndicator(
                currentPage: $currentPage,
                lyricsAvailable: viewModel.lyricsState.isAvailable
            )
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }

    /// Horizontal drag gesture that manually pages between cards.
    /// minimumDistance: 30 lets taps pass through to buttons and other
    /// interactive elements within the cards.
    private var cardPagingGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                // Only page if the swipe is mostly horizontal
                guard abs(horizontal) > vertical else { return }
                guard abs(horizontal) > 50 else { return }

                withAnimation(.easeInOut(duration: 0.25)) {
                    if horizontal < 0 {
                        currentPage = min(currentPage + 1, 3)
                    } else {
                        currentPage = max(currentPage - 1, 0)
                    }
                }
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
