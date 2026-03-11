import EnsembleCore
import SwiftUI

/// Left card displaying lyrics with time-synced highlighting (karaoke style)
/// Supports timed LRC lyrics with auto-scroll, plain text lyrics, and empty/loading states
public struct LyricsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Scrollable content area with fade masks
            contentView
                .padding(.bottom, 60) // Space for fixed page indicator
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.lyricsState {
        case .loading:
            loadingView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(fadeMask)

        case .notAvailable:
            notAvailableView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(fadeMask)

        case .available(let lyrics):
            lyricsScrollView(lyrics: lyrics)
                .mask(fadeMask)
        }
    }

    // MARK: - Loading State

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
        }
    }

    // MARK: - Not Available State

    private var notAvailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 48))
                .foregroundColor(.primary.opacity(0.3))

            Text("No Lyrics Available")
                .font(.headline)
                .foregroundColor(.primary.opacity(0.6))
        }
    }

    // MARK: - Lyrics Scroll View

    private func lyricsScrollView(lyrics: ParsedLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: lyrics.isTimed ? 16 : 10) {
                    // Top spacer so first line can scroll to center
                    Spacer()
                        .frame(height: 120)

                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        VStack(spacing: 8) {
                            lyricsLineView(
                                line: line,
                                index: index,
                                isTimed: lyrics.isTimed,
                                isActive: viewModel.currentLyricsLineIndex == index,
                                isPast: isPastLine(index: index)
                            )
                            .onTapGesture {
                                // Tap-to-seek for timed lyrics
                                if lyrics.isTimed, let timestamp = line.timestamp {
                                    viewModel.seek(to: timestamp)
                                }
                            }

                            // Instrumental gap indicator after the active line
                            if lyrics.isTimed,
                               viewModel.currentLyricsLineIndex == index,
                               let progress = viewModel.instrumentalProgress {
                                instrumentalIndicator(progress: progress)
                                    .transition(.opacity)
                            }
                        }
                        .id(index)
                    }

                    // Bottom spacer so last line can scroll to center
                    Spacer()
                        .frame(height: 200)
                }
                .padding(.horizontal, 40)
            }
            // Scroll to the look-ahead target (500ms before line becomes active)
            .onChange(of: viewModel.lyricsScrollTargetIndex) { newIndex in
                guard let newIndex, lyrics.isTimed else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Line View

    private func lyricsLineView(
        line: LyricsLine,
        index: Int,
        isTimed: Bool,
        isActive: Bool,
        isPast: Bool
    ) -> some View {
        Text(line.text)
            .font(.title3)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundColor(.primary)
            .opacity(lineOpacity(isTimed: isTimed, isActive: isActive, isPast: isPast))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    // MARK: - Instrumental Indicator

    /// Animated ellipsis that fills in during instrumental gaps between lyrics
    private func instrumentalIndicator(progress: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let dotThreshold = Double(dotIndex + 1) / 4.0  // 0.25, 0.5, 0.75
                Circle()
                    .fill(Color.primary.opacity(progress >= dotThreshold ? 0.6 : 0.15))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.3), value: progress >= dotThreshold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    /// Determine opacity for a lyrics line
    private func lineOpacity(isTimed: Bool, isActive: Bool, isPast: Bool) -> Double {
        guard isTimed else { return 0.9 } // Plain text: all lines equal
        if isActive { return 1.0 }
        if isPast { return 0.5 }
        return 0.3 // Future lines
    }

    /// Whether a line is in the past (before the current active line)
    private func isPastLine(index: Int) -> Bool {
        guard let activeIndex = viewModel.currentLyricsLineIndex else { return false }
        return index < activeIndex
    }

    /// Fade mask for top and bottom edges of the scroll area
    private var fadeMask: some View {
        VStack(spacing: 0) {
            // Top fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 30)

            // Middle: full opacity
            Rectangle().fill(Color.black)

            // Bottom fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
        }
    }
}
