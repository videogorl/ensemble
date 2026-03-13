import EnsembleCore
import SwiftUI

/// Horizontal paging carousel managing four cards: Queue, Controls, Lyrics, Info
/// Opens to Controls by default.
/// Uses a manual HStack + drag offset instead of TabView so that cards
/// follow the finger during swipes (responsive paging). TabView's built-in
/// page style doesn't receive swipes through Buttons or other interactive
/// elements, so this approach also fixes that.
public struct NowPlayingCarousel: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    // Track previous page for haptic feedback
    @State private var previousPage: Int = 1

    // Drag state for responsive paging
    @State private var dragOffset: CGFloat = 0
    // Locks gesture direction after initial movement to avoid mid-gesture switching
    @State private var isHorizontalDrag: Bool?

    private let pageCount = 4

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }

    public var body: some View {
        GeometryReader { geometry in
            let pageWidth = geometry.size.width

            ZStack(alignment: .bottom) {
                // Card strip — leading-aligned so page 0 starts at x=0.
                // Each card is exactly pageWidth, so offsetting by
                // -currentPage * pageWidth slides the correct card into view.
                HStack(spacing: 0) {
                    // Page 0: Queue (swipe left from center)
                    QueueCard(viewModel: viewModel, currentPage: $currentPage)
                        .frame(width: pageWidth)

                    // Page 1: Controls (center, default)
                    ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                        .frame(width: pageWidth)

                    // Page 2: Lyrics (swipe right from center)
                    LyricsCard(viewModel: viewModel, currentPage: $currentPage, isLowPowerMode: powerStateMonitor.isLowPowerMode)
                        .frame(width: pageWidth)

                    // Page 3: Info (far right)
                    InfoCard(viewModel: viewModel, currentPage: $currentPage)
                        .frame(width: pageWidth)
                }
                .offset(x: -CGFloat(currentPage) * pageWidth + dragOffset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .simultaneousGesture(pagingGesture(pageWidth: pageWidth))

                // Fixed page indicator overlay — lyrics icon reflects availability
                PageIndicator(
                    currentPage: animatedPageBinding,
                    lyricsAvailable: viewModel.lyricsState.isAvailable
                )
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
        }
        .onChange(of: currentPage) { newPage in
            handlePageChange(from: previousPage, to: newPage)
            previousPage = newPage
        }
    }

    // MARK: - Paging Gesture

    /// Drag gesture that drives responsive card paging. Cards follow the
    /// finger during the drag and snap to the nearest page on release.
    /// Uses direction locking: once movement exceeds 10pt, the axis is
    /// locked so vertical scrolls within cards aren't hijacked.
    private func pagingGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let h = value.translation.width
                let v = value.translation.height

                // Lock direction after small initial movement
                if isHorizontalDrag == nil && (abs(h) > 10 || abs(v) > 10) {
                    isHorizontalDrag = abs(h) > abs(v)
                }

                guard isHorizontalDrag == true else { return }

                // Rubber-band at edges
                var drag = h
                if (currentPage == 0 && h > 0) || (currentPage == pageCount - 1 && h < 0) {
                    drag = h * 0.3
                }
                dragOffset = drag
            }
            .onEnded { value in
                let wasHorizontal = isHorizontalDrag == true
                isHorizontalDrag = nil

                guard wasHorizontal else {
                    dragOffset = 0
                    return
                }

                // Use predicted translation for momentum-based snapping
                let predicted = value.predictedEndTranslation.width
                let threshold = pageWidth * 0.3

                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    if predicted < -threshold && currentPage < pageCount - 1 {
                        currentPage += 1
                    } else if predicted > threshold && currentPage > 0 {
                        currentPage -= 1
                    }
                    dragOffset = 0
                }
            }
    }

    /// Wraps the currentPage binding so PageIndicator taps animate smoothly
    private var animatedPageBinding: Binding<Int> {
        Binding(
            get: { currentPage },
            set: { newPage in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    currentPage = newPage
                }
            }
        )
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
