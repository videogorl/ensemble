import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Left card displaying lyrics with time-synced highlighting (karaoke style)
/// Supports timed LRC lyrics with auto-scroll, plain text lyrics, and empty/loading states
public struct LyricsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int

    /// When true, disables progressive blur on lyrics lines to reduce GPU work
    let isLowPowerMode: Bool

    // Track last scroll target to detect large jumps (seeks) vs natural progression
    @State private var lastScrollIndex: Int?

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>, isLowPowerMode: Bool = false) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.isLowPowerMode = isLowPowerMode
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

    /// Whether this card is the active page in the carousel.
    /// TabView's .page style renders ALL children simultaneously — gate expensive
    /// blur/scroll/animation content behind this check to avoid GPU work off-screen.
    private var isVisible: Bool {
        currentPage == 2
    }

    @ViewBuilder
    private var contentView: some View {
        if isVisible {
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
        } else {
            // Lightweight placeholder — keeps layout stable for TabView paging
            // without any blur/scroll/animation GPU cost
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    // Intro dot — always present for timed lyrics, tap to seek to beginning.
                    // Time-synced when there's a real intro gap, otherwise just past/future.
                    if lyrics.isTimed {
                        let introBlur = lineBlurRadius(index: 0, isTimed: true)
                        instrumentalIndicator(progress: introProgress)
                            .blur(radius: introBlur)
                            .animation(.easeInOut(duration: 0.3), value: introBlur)
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
                                // LRC timestamps mark when to START DISPLAYING a line,
                                // which is slightly before the vocals begin. Add a small
                                // offset so tap-to-seek lands on the actual vocal start
                                // rather than the tail of the previous line.
                                viewModel.seek(to: timestamp + 0.35)
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
                            let gapBlur = lineBlurRadius(index: index, isTimed: true)
                            instrumentalIndicator(progress: progress)
                                .blur(radius: gapBlur)
                                .animation(.easeInOut(duration: 0.3), value: gapBlur)
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

                    // Outro dot — always present for timed lyrics, tap to seek to end.
                    // Time-synced when there's a real outro gap, otherwise just past/future.
                    if lyrics.isTimed {
                        let lastIndex = lyrics.lines.count - 1
                        let outroBlur = lineBlurRadius(index: lastIndex + 1, isTimed: true)
                        instrumentalIndicator(progress: outroProgress(lastIndex: lastIndex))
                            .blur(radius: outroBlur)
                            .animation(.easeInOut(duration: 0.3), value: outroBlur)
                            .id("outro-instrumental")
                            .onTapGesture {
                                // Seek near track end (last 5 seconds)
                                let endTime = max(viewModel.duration - 5, 0)
                                viewModel.seek(to: endTime)
                                resumeIfPaused()
                            }
                    }

                    // Bottom spacer so last line can scroll to center
                    Spacer()
                        .frame(height: 200)
                }
                .padding(.horizontal, 48)
            }
            // Detect vertical scrolls to suppress auto-scroll temporarily.
            // Uses a UIKit gesture recognizer that only activates for vertical pans,
            // allowing horizontal swipes to pass through to the parent TabView.
            #if canImport(UIKit)
            .background(
                VerticalDragDetector {
                    viewModel.userDidScrollLyrics()
                }
            )
            #endif
            // Restore scroll position when view appears (e.g., swiping back from another card).
            // The isVisible gate replaces the ScrollView with Color.clear when off-screen,
            // so scroll position is lost. Snap to the current lyrics position on re-creation.
            .onAppear {
                guard lyrics.isTimed else { return }
                let scrollTarget: AnyHashable
                if let index = viewModel.lyricsScrollTargetIndex {
                    scrollTarget = index
                } else {
                    scrollTarget = "intro-instrumental"
                }
                lastScrollIndex = viewModel.lyricsScrollTargetIndex
                // Defer to next frame so the LazyVStack has laid out its content
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
            // Scroll to active lyric — animate for natural progression, snap for seeks.
            // nil target means "before first lyric" — scroll to top (index 0 or intro).
            .onChange(of: viewModel.lyricsScrollTargetIndex) { newIndex in
                guard lyrics.isTimed else { return }

                // Determine scroll destination: active line, or intro dot if before lyrics
                let scrollTarget: AnyHashable
                if let newIndex {
                    scrollTarget = newIndex
                } else {
                    scrollTarget = "intro-instrumental" // Always present for timed lyrics
                }

                let isLargeJump: Bool
                if let newIndex, let last = lastScrollIndex {
                    isLargeJump = abs(newIndex - last) > 2
                } else {
                    isLargeJump = true // First scroll or nil target — snap without animation
                }
                lastScrollIndex = newIndex

                if isLargeJump {
                    // Snap immediately for seeks — prevents animation backlog
                    proxy.scrollTo(scrollTarget, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(scrollTarget, anchor: .center)
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
        let opacity = lineOpacity(isTimed: isTimed, isActive: isActive, isPast: isPast)
        // Use Equatable wrapper so SwiftUI skips re-rendering lines whose params
        // haven't changed — reduces N re-renders per tick to ~2 (old + new active line)
        return EquatableView(content: LyricsLineView(
            text: line.text,
            isActive: isActive,
            isTimed: isTimed,
            opacity: opacity,
            blur: blur
        ))
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

    /// Intro dot progress: time-synced if there's a real intro gap, otherwise just past/future
    private var introProgress: Double {
        if viewModel.hasIntroInstrumentalGap {
            let isIntroActive = viewModel.lyricsScrollTargetIndex == nil
                && viewModel.instrumentalProgress != nil
            if isIntroActive {
                return viewModel.instrumentalProgress ?? 0
            }
        }
        // Filled once any lyric line has been reached
        let hasStarted = viewModel.currentLyricsLineIndex != nil
            || viewModel.lyricsScrollTargetIndex != nil
        return hasStarted ? 1.0 : 0.0
    }

    /// Outro dot progress: time-synced if there's a real outro gap, otherwise just past/future
    private func outroProgress(lastIndex: Int) -> Double {
        if viewModel.hasOutroInstrumentalGap {
            let isOutroActive = viewModel.instrumentalProgress != nil
                && viewModel.currentLyricsLineIndex == nil
                && viewModel.lyricsScrollTargetIndex == lastIndex
            if isOutroActive {
                return viewModel.instrumentalProgress ?? 0
            }
        }
        return isPastLine(index: lastIndex) ? 1.0 : 0.0
    }

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
    /// Disabled for plain text lyrics and in Low Power Mode.
    private func lineBlurRadius(index: Int, isTimed: Bool) -> CGFloat {
        // No blur for plain text, Low Power Mode, or when user is manually scrolling
        guard isTimed, !isLowPowerMode, !viewModel.isUserScrollingLyrics else { return 0 }

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

#if canImport(UIKit)
// MARK: - Vertical Drag Detector

/// Detects vertical scroll gestures by attaching a UIPanGestureRecognizer directly to the
/// ancestor UIScrollView. Uses a hidden probe view in `.background` — when it appears in
/// the window, it walks up the view hierarchy to find the ScrollView's underlying
/// UIScrollView and adds a vertical-only pan gesture. This approach lets horizontal swipes
/// pass through to the parent TabView for card navigation, while still detecting vertical
/// scrolling for auto-scroll suppression.
private struct VerticalDragDetector: UIViewRepresentable {
    let onVerticalDrag: () -> Void

    func makeUIView(context: Context) -> DragDetectorProbeView {
        let view = DragDetectorProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isHidden = true
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: DragDetectorProbeView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onVerticalDrag: onVerticalDrag)
    }

    // Hidden probe view that finds the ancestor UIScrollView on window attachment
    class DragDetectorProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Defer to let the view hierarchy settle
            DispatchQueue.main.async { [weak self] in
                self?.coordinator?.attachIfNeeded(from: self)
            }
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onVerticalDrag: () -> Void
        private var verticalDetector: UIPanGestureRecognizer?

        init(onVerticalDrag: @escaping () -> Void) {
            self.onVerticalDrag = onVerticalDrag
        }

        func attachIfNeeded(from view: UIView?) {
            guard verticalDetector == nil, let view else { return }

            // Walk up to find the lyrics UIScrollView, then continue to find
            // the TabView's paging UIScrollView above it.
            var lyricsScrollView: UIScrollView?
            var pagingScrollView: UIScrollView?
            var current: UIView? = view
            while let v = current {
                if let sv = v as? UIScrollView {
                    if lyricsScrollView == nil {
                        // First UIScrollView found = lyrics vertical scroll
                        lyricsScrollView = sv
                    } else if sv.isPagingEnabled {
                        // Paging UIScrollView = TabView's horizontal page container
                        pagingScrollView = sv
                        break
                    }
                }
                current = v.superview
            }

            guard let lyricsScrollView else { return }

            // Vertical drag detector — fires callback for auto-scroll suppression.
            // Only recognizes vertical pans so it doesn't interfere with page swiping.
            let vertical = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleVerticalPan(_:))
            )
            vertical.delegate = self
            vertical.name = "lyrics-vertical-detector"
            lyricsScrollView.addGestureRecognizer(vertical)
            verticalDetector = vertical

            // Make the TabView's paging pan wait for our vertical detector to fail.
            // Vertical swipe → detector recognizes → TabView pan blocked → lyrics scroll works.
            // Horizontal swipe → detector fails → TabView pan starts → page swipe works.
            if let pagingScrollView {
                pagingScrollView.panGestureRecognizer.require(toFail: vertical)
            }
        }

        @objc func handleVerticalPan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                onVerticalDrag()
            }
        }

        // Only begin for predominantly vertical pans — lets horizontal swipes
        // fall through to the TabView page gesture.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x)
        }

        // Allow simultaneous recognition with the ScrollView's built-in pan
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }
}
#endif

// MARK: - Equatable Lyrics Line

private struct LyricsLineView: View, Equatable {
    let text: String
    let isActive: Bool
    let isTimed: Bool
    let opacity: Double
    let blur: CGFloat

    var body: some View {
        Text(text)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .opacity(opacity)
            .scaleEffect(isActive && isTimed ? 1.05 : 1.0, anchor: .leading)
            .blur(radius: blur)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: isActive)
            .animation(.easeInOut(duration: 0.3), value: blur)
    }
}
