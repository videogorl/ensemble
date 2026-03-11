import EnsembleCore
import SwiftUI

/// Left card displaying lyrics with time-synced highlighting (karaoke style)
/// Supports timed LRC lyrics with auto-scroll, plain text lyrics, and empty/loading states
public struct LyricsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int

    // Track last scroll target to detect large jumps (seeks) vs natural progression
    @State private var lastScrollIndex: Int?

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

            Spacer(minLength: 0) // Push transport controls to bottom

            // Secondary transport controls + page indicator spacing
            VStack(spacing: 8) {
                transportControlsView
                    .padding(.top, 16)
                Spacer().frame(height: 36) // Reserve space for fixed page indicator
            }
            .padding(.bottom, 20)
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
        .padding(.horizontal, 48)
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
                LazyVStack(spacing: lyrics.isTimed ? 24 : 12) {
                    // Top spacer so first line can scroll to center
                    Spacer()
                        .frame(height: 120)

                    // Intro instrumental indicator (always visible if gap exists)
                    if lyrics.isTimed, viewModel.hasIntroInstrumentalGap {
                        let isIntroActive = viewModel.currentLyricsLineIndex == nil
                            && viewModel.instrumentalProgress != nil
                        let progress = isIntroActive ? (viewModel.instrumentalProgress ?? 0) : 1.0
                        instrumentalIndicator(progress: progress)
                            .id("intro-instrumental")
                            .onTapGesture {
                                viewModel.seek(to: 0)
                                resumeIfPaused()
                            }
                    }

                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        // Each lyric line as its own item in the LazyVStack
                        lyricsLineView(
                            line: line,
                            index: index,
                            isTimed: lyrics.isTimed,
                            isActive: viewModel.currentLyricsLineIndex == index,
                            isPast: isPastLine(index: index)
                        )
                        .onTapGesture {
                            if lyrics.isTimed, let timestamp = line.timestamp {
                                viewModel.seek(to: timestamp)
                                resumeIfPaused()
                            }
                        }
                        .id(index)

                        // Instrumental gap indicator as its own item (same spacing as lyrics)
                        if lyrics.isTimed,
                           viewModel.instrumentalGapAfterIndices.contains(index) {
                            let isActiveGap = viewModel.instrumentalProgress != nil
                                && viewModel.currentLyricsLineIndex == nil
                                && isCurrentGap(afterIndex: index, lyrics: lyrics)
                            let progress = isActiveGap ? (viewModel.instrumentalProgress ?? 0) : (isPastLine(index: index) ? 1.0 : 0.0)
                            instrumentalIndicator(progress: progress)
                                .id("gap-\(index)")
                                .onTapGesture {
                                    let nextIndex = index + 1
                                    if nextIndex < lyrics.lines.count,
                                       let nextTimestamp = lyrics.lines[nextIndex].timestamp {
                                        viewModel.seek(to: nextTimestamp)
                                        resumeIfPaused()
                                    }
                                }
                        }
                    }

                    // Outro instrumental indicator (after last lyric if gap exists)
                    if lyrics.isTimed, viewModel.hasOutroInstrumentalGap {
                        let lastIndex = lyrics.lines.count - 1
                        let isOutroActive = viewModel.instrumentalProgress != nil
                            && viewModel.currentLyricsLineIndex == nil
                            && !viewModel.hasIntroInstrumentalGap  // Not intro
                        let progress = isOutroActive ? (viewModel.instrumentalProgress ?? 0) : (isPastLine(index: lastIndex) ? 1.0 : 0.0)
                        instrumentalIndicator(progress: progress)
                            .id("outro-instrumental")
                    }

                    // Bottom spacer so last line can scroll to center
                    Spacer()
                        .frame(height: 200)
                }
                .padding(.horizontal, 48)
            }
            // Detect user manual scroll and suppress auto-scroll temporarily
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        viewModel.userDidScrollLyrics()
                    }
            )
            // Scroll to active lyric — animate for natural progression, snap for seeks
            .onChange(of: viewModel.lyricsScrollTargetIndex) { newIndex in
                guard let newIndex, lyrics.isTimed else { return }

                let isLargeJump: Bool
                if let last = lastScrollIndex {
                    isLargeJump = abs(newIndex - last) > 2
                } else {
                    isLargeJump = true // First scroll — snap without animation
                }
                lastScrollIndex = newIndex

                if isLargeJump {
                    // Snap immediately for seeks — prevents animation backlog
                    proxy.scrollTo(newIndex, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
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
        let blur = lineBlurRadius(index: index, isTimed: isTimed)
        return Text(line.text)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .opacity(lineOpacity(isTimed: isTimed, isActive: isActive, isPast: isPast))
            .scaleEffect(isActive && isTimed ? 1.05 : 1.0, anchor: .leading)
            .blur(radius: blur)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: isActive)
            .animation(.easeInOut(duration: 0.3), value: blur)
    }

    // MARK: - Instrumental Indicator

    /// Animated ellipsis that fills in during instrumental gaps between lyrics.
    /// Shown at all gap positions — active gaps animate, past gaps are fully filled,
    /// future gaps are dim.
    private func instrumentalIndicator(progress: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let dotThreshold = Double(dotIndex + 1) / 4.0  // 0.25, 0.5, 0.75
                Circle()
                    .fill(Color.primary.opacity(progress >= dotThreshold ? 0.6 : 0.15))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: progress >= dotThreshold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport Controls

    /// Secondary transport controls: previous, play/pause, next
    private var transportControlsView: some View {
        HStack(spacing: 40) {
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .foregroundColor(.primary.opacity(0.7))
            }

            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.primary.opacity(0.9))
            }

            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 0)
    }

    // MARK: - Helpers

    /// Resume playback if currently paused (for tap-to-seek interactions)
    private func resumeIfPaused() {
        if viewModel.playbackState == .paused {
            viewModel.resume()
        }
    }

    /// Determine opacity for a lyrics line
    private func lineOpacity(isTimed: Bool, isActive: Bool, isPast: Bool) -> Double {
        guard isTimed else { return 0.9 } // Plain text: all lines equal
        if isActive { return 1.0 }
        if isPast { return 0.5 }
        return 0.3 // Future lines
    }

    /// Progressive blur based on distance from the active line (which is centered in viewport).
    /// Lines close to the active line are sharp; distant lines blur progressively.
    /// Disabled for plain text lyrics and during user manual scroll.
    private func lineBlurRadius(index: Int, isTimed: Bool) -> CGFloat {
        guard isTimed, !viewModel.isUserScrollingLyrics else { return 0 }

        // Use active line index, fall back to scroll target during instrumental gaps
        let center = viewModel.currentLyricsLineIndex
            ?? viewModel.lyricsScrollTargetIndex
        guard let center else { return 0 }

        let distance = abs(index - center)
        // Lines within 2 of center: no blur. Beyond that: progressive blur up to 5pt.
        guard distance > 2 else { return 0 }
        return min(CGFloat(distance - 2) * 1.5, 5.0)
    }

    /// Whether a line is in the past (before the current active line)
    private func isPastLine(index: Int) -> Bool {
        guard let activeIndex = viewModel.currentLyricsLineIndex else {
            // During instrumental gaps, currentLyricsLineIndex is nil.
            // Use the scroll target as fallback to determine past/future.
            guard let scrollTarget = viewModel.lyricsScrollTargetIndex else { return false }
            return index < scrollTarget
        }
        return index < activeIndex
    }

    /// Whether a gap after the given index is the currently active instrumental gap.
    /// During gaps, currentLyricsLineIndex is nil but the scroll target tracks the
    /// underlying active line index from the binary search.
    private func isCurrentGap(afterIndex index: Int, lyrics: ParsedLyrics) -> Bool {
        guard let scrollTarget = viewModel.lyricsScrollTargetIndex else { return false }
        return scrollTarget == index
    }

    /// Fade mask matching QueueCard style — gradual top and bottom fades
    private var fadeMask: some View {
        VStack(spacing: 0) {
            // Top fade (gradual)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)

            // Middle: full opacity
            Rectangle().fill(Color.black)

            // Bottom fade (gradual)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.7),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
    }
}
