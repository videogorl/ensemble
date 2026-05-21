import EnsembleCore
import SwiftUI

/// Left card displaying lyrics with time-synced highlighting (karaoke style)
/// Supports timed LRC lyrics with auto-scroll, plain text lyrics, and empty/loading states
public struct LyricsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int

    /// When true, disables progressive blur on lyrics lines to reduce GPU work
    let isLowPowerMode: Bool
    private let showsTransportControls: Bool

    // Track last scroll target to detect large jumps (seeks) vs natural progression
    @State private var lastScrollIndex: Int?

    // Decoupled from @Published via CurrentValueSubject — these update every ~0.5s
    // during lyrics sync but only LyricsCard needs them, not all 4 NP cards.
    @State private var currentLyricsLineIndex: Int?
    @State private var lyricsScrollTargetIndex: Int?
    @State private var instrumentalProgress: Double?
    @State private var isUserDrivenLyricsScrollActive = false
    @State private var lyricsScrollPhaseResetToken = 0
    @State private var lyricsRecenterRequestToken = 0

    public init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        isLowPowerMode: Bool = false,
        showsTransportControls: Bool = true
    ) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.isLowPowerMode = isLowPowerMode
        self.showsTransportControls = showsTransportControls
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Pinned header
            headerView
                .padding(.top, EnsembleScaffold.NowPlaying.headerTopPadding)
                .padding(.bottom, EnsembleScaffold.NowPlaying.headerBottomPadding)

            // Scrollable content area with fade masks
            contentView

            Spacer(minLength: 0) // Push transport controls to bottom

            if showsTransportControls {
                // Secondary transport controls + page indicator spacing
                VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                    transportControlsView
                        .padding(.top, EnsembleScaffold.NowPlaying.secondaryControlsTopPadding)
                    Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
                }
                .padding(.bottom, EnsembleScaffold.NowPlaying.secondaryControlsBottomPadding)
            }
        }
        .onAppear {
            syncLyricsSnapshot()
        }
        .onChange(of: currentPage) { newPage in
            guard NowPlayingPanelPage.lyrics.shouldRenderContent(currentPage: newPage) else {
                isUserDrivenLyricsScrollActive = false
                return
            }
            syncLyricsSnapshot()
        }
        .task(id: lyricsScrollPhaseResetToken) {
            guard isUserDrivenLyricsScrollActive else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            isUserDrivenLyricsScrollActive = false
            lyricsRecenterRequestToken &+= 1
        }
        .onReceive(viewModel.currentLyricsLineIndexPublisher) { index in
            guard NowPlayingPanelPage.lyrics.isActive(currentPage: currentPage) else { return }
            if index != currentLyricsLineIndex { currentLyricsLineIndex = index }
        }
        .onReceive(viewModel.lyricsScrollTargetIndexPublisher) { index in
            guard NowPlayingPanelPage.lyrics.isActive(currentPage: currentPage) else { return }
            if index != lyricsScrollTargetIndex { lyricsScrollTargetIndex = index }
        }
        .onReceive(viewModel.instrumentalProgressPublisher) { progress in
            guard NowPlayingPanelPage.lyrics.isActive(currentPage: currentPage) else { return }
            if progress != instrumentalProgress { instrumentalProgress = progress }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            Spacer()

            if viewModel.hasChordLyrics {
                Button {
                    viewModel.toggleChordMode()
                } label: {
                    Image(systemName: EnsembleDesign.Icon.chords)
                        .font(EnsembleDesign.Typography.detailSubtitle)
                        .foregroundColor(viewModel.isChordModeEnabled
                            ? EnsembleDesign.Color.accent
                            : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
                }
                .accessibilityLabel(viewModel.isChordModeEnabled
                    ? "Disable chord mode"
                    : "Enable chord mode")
            }

            // Instrumental mode toggle (A13+ / iOS 16+ only)
            if viewModel.isInstrumentalModeSupported {
                Button {
                    viewModel.toggleInstrumentalMode()
                } label: {
                    Image(systemName: viewModel.isInstrumentalModeActive
                        ? EnsembleDesign.Icon.instrumentalOn
                        : EnsembleDesign.Icon.instrumentalOff)
                        .font(EnsembleDesign.Typography.detailSubtitle)
                        .foregroundColor(viewModel.isInstrumentalModeActive
                            ? EnsembleDesign.Color.accent
                            : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
                }
                .accessibilityLabel(viewModel.isInstrumentalModeActive
                    ? "Disable instrumental mode"
                    : "Enable instrumental mode")
            }
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
        .frame(minHeight: EnsembleScaffold.NowPlaying.headerMinHeight)
    }

    // MARK: - Content

    private var shouldRenderContent: Bool {
        NowPlayingPanelPage.lyrics.shouldRenderContent(currentPage: currentPage)
    }

    @ViewBuilder
    private var contentView: some View {
        if shouldRenderContent {
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
            // Lightweight placeholder for pages more than one swipe away.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading State

    private var loadingView: some View {
        VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ProgressView()
                .scaleEffect(1.2)
        }
    }

    // MARK: - Not Available State

    private var notAvailableView: some View {
        VStack(spacing: EnsembleScaffold.NowPlaying.emptyTextSpacing) {
            Image(systemName: EnsembleDesign.Icon.lyricsUnavailable)
                .font(.system(size: EnsembleScaffold.NowPlaying.emptyIconSize))
                .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.lyricFutureOpacity))

            Text("No Lyrics Available")
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.lyricIndicatorFilledOpacity))

            Button {
                viewModel.retryLyrics()
            } label: {
                Label("Retry", systemImage: EnsembleDesign.Icon.retry)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Lyrics Scroll View

    private func lyricsScrollView(lyrics: ParsedLyrics) -> some View {
        ScrollViewReader { proxy in
            observedLyricsScrollView {
                let lineSpacing: CGFloat = viewModel.isDisplayingChordLyrics
                    ? 16
                    : (lyrics.isTimed
                        ? EnsembleScaffold.NowPlaying.lyricTimedLineSpacing
                        : EnsembleScaffold.NowPlaying.lyricPlainLineSpacing)
                LazyVStack(spacing: lineSpacing) {
                    // Top spacer so first line can scroll to center
                    Spacer()
                        .frame(height: EnsembleScaffold.NowPlaying.lyricTopSpacerHeight)

                    // Intro dot — always present for timed lyrics, tap to seek to beginning.
                    // Time-synced when there's a real intro gap, otherwise just past/future.
                    if lyrics.isTimed, !viewModel.isDisplayingChordLyrics {
                        let introBlur = lineBlurRadius(index: 0, isTimed: true)
                        instrumentalIndicator(progress: introProgress)
                            .blur(radius: introBlur)
                            .animation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration), value: introBlur)
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
                            isActive: currentLyricsLineIndex == index,
                            isNextActive: isNextChordLine(index: index),
                            isPast: isPastLine(index: index)
                        )
                        .onTapGesture {
                            if lyrics.isTimed, let timestamp = line.timestamp {
                                // LRC timestamps mark when to START DISPLAYING a line,
                                // which is slightly before the vocals begin. Add a small
                                // offset so tap-to-seek lands on the actual vocal start
                                // rather than the tail of the previous line.
                                viewModel.seek(to: timestamp + 0.5)
                                resumeIfPaused()
                            }
                        }
                        .id(index)

                        // Instrumental gap indicator as its own item (same spacing as lyrics)
                        if lyrics.isTimed,
                           !viewModel.isDisplayingChordLyrics,
                           viewModel.instrumentalGapAfterIndices.contains(index) {
                            let isActiveGap = instrumentalProgress != nil
                                && currentLyricsLineIndex == nil
                                && isCurrentGap(afterIndex: index, lyrics: lyrics)
                            let progress = isActiveGap ? (instrumentalProgress ?? 0) : (isPastLine(index: index) ? 1.0 : 0.0)
                            let gapBlur = lineBlurRadius(index: index, isTimed: true)
                            instrumentalIndicator(progress: progress)
                                .blur(radius: gapBlur)
                                .animation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration), value: gapBlur)
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
                    if lyrics.isTimed, !viewModel.isDisplayingChordLyrics {
                        let lastIndex = lyrics.lines.count - 1
                        let outroBlur = lineBlurRadius(index: lastIndex + 1, isTimed: true)
                        instrumentalIndicator(progress: outroProgress(lastIndex: lastIndex))
                            .blur(radius: outroBlur)
                            .animation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration), value: outroBlur)
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
                        .frame(height: EnsembleScaffold.NowPlaying.lyricBottomSpacerHeight)
                }
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            }
            // Restore scroll position when the scroll view is recreated after
            // moving more than one page away from Lyrics.
            .onAppear {
                guard lyrics.isTimed else { return }
                let scrollTarget: AnyHashable
                if let index = lyricsScrollTargetIndex {
                    scrollTarget = index
                } else {
                    scrollTarget = viewModel.isDisplayingChordLyrics ? 0 : "intro-instrumental"
                }
                lastScrollIndex = lyricsScrollTargetIndex
                proxy.scrollTo(scrollTarget, anchor: .center)
            }
            // Scroll to active lyric — animate for natural progression, snap for seeks.
            // nil target means "before first lyric" — scroll to top (index 0 or intro).
            .onChange(of: lyricsScrollTargetIndex) { newIndex in
                guard lyrics.isTimed else { return }

                // Determine scroll destination: active line, or intro dot if before lyrics
                let scrollTarget: AnyHashable
                if let newIndex {
                    scrollTarget = newIndex
                } else {
                    scrollTarget = viewModel.isDisplayingChordLyrics ? 0 : "intro-instrumental"
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
                    withAnimation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration)) {
                        proxy.scrollTo(scrollTarget, anchor: .center)
                    }
                }
            }
            .onChange(of: lyricsRecenterRequestToken) { _ in
                guard lyrics.isTimed else { return }
                let scrollTarget: AnyHashable
                if let index = lyricsScrollTargetIndex {
                    scrollTarget = index
                } else {
                    scrollTarget = viewModel.isDisplayingChordLyrics ? 0 : "intro-instrumental"
                }
                withAnimation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration)) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
        }
    }

    private func syncLyricsSnapshot() {
        if viewModel.currentLyricsLineIndex != currentLyricsLineIndex {
            currentLyricsLineIndex = viewModel.currentLyricsLineIndex
        }
        if viewModel.lyricsScrollTargetIndex != lyricsScrollTargetIndex {
            lyricsScrollTargetIndex = viewModel.lyricsScrollTargetIndex
        }
        if viewModel.instrumentalProgress != instrumentalProgress {
            instrumentalProgress = viewModel.instrumentalProgress
        }
    }

    @ViewBuilder
    private func observedLyricsScrollView<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scrollView = ScrollView(showsIndicators: false) {
            content()
        }

        if #available(iOS 18.0, macOS 15.0, *) {
            scrollView
                .onScrollPhaseChange { _, newPhase in
                    handleLyricsScrollPhaseChange(newPhase)
                }
        } else {
            scrollView
        }
    }

    @available(iOS 18.0, macOS 15.0, *)
    private func handleLyricsScrollPhaseChange(_ phase: ScrollPhase) {
        let isUserDrivenScroll = phase == .tracking
            || phase == .interacting
            || phase == .decelerating
        handleLyricsScrollPhaseChange(isUserDrivenScroll: isUserDrivenScroll)
    }

    private func handleLyricsScrollPhaseChange(isUserDrivenScroll: Bool) {
        guard NowPlayingPanelPage.lyrics.isActive(currentPage: currentPage) else { return }

        if isUserDrivenScroll {
            isUserDrivenLyricsScrollActive = true
            lyricsScrollPhaseResetToken &+= 1
        }
    }

    // MARK: - Line View

    @ViewBuilder
    private func lyricsLineView(
        line: LyricsLine,
        index: Int,
        isTimed: Bool,
        isActive: Bool,
        isNextActive: Bool,
        isPast: Bool
    ) -> some View {
        let blur = lineBlurRadius(index: index, isTimed: isTimed)
        let opacity = lineOpacity(isTimed: isTimed, isActive: isActive, isNextActive: isNextActive, isPast: isPast)
        if viewModel.isDisplayingChordLyrics {
            ChordLyricsLineView(
                line: line,
                isActive: isActive,
                isNextActive: isNextActive,
                isTimed: isTimed,
                opacity: opacity
            )
        } else {
            // Use Equatable wrapper so SwiftUI skips re-rendering lines whose params
            // haven't changed — reduces N re-renders per tick to ~2 (old + new active line)
            EquatableView(content: LyricsLineView(
                text: line.text,
                isActive: isActive,
                isTimed: isTimed,
                opacity: opacity,
                blur: blur
            ))
        }
    }

    // MARK: - Instrumental Indicator

    /// Animated ellipsis that fills in during instrumental gaps between lyrics.
    /// Shown at all gap positions — active gaps animate, past gaps are fully filled,
    /// future gaps are dim.
    private func instrumentalIndicator(progress: Double) -> some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.lyricIndicatorSpacing) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let dotThreshold = Double(dotIndex + 1) / 4.0  // 0.25, 0.5, 0.75
                Circle()
                    .fill(EnsembleDesign.Color.primaryText.opacity(progress >= dotThreshold
                        ? EnsembleScaffold.NowPlaying.lyricIndicatorFilledOpacity
                        : EnsembleScaffold.NowPlaying.lyricIndicatorEmptyOpacity
                    ))
                    .frame(
                        width: EnsembleScaffold.NowPlaying.lyricIndicatorDotSize,
                        height: EnsembleScaffold.NowPlaying.lyricIndicatorDotSize
                    )
                    .animation(.easeInOut(duration: EnsembleDesign.Animation.quickDuration), value: progress >= dotThreshold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport Controls

    /// Secondary transport controls: previous, play/pause, next
    private var transportControlsView: some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.transportControlsSpacing) {
            Button(action: viewModel.previous) {
                Image(systemName: EnsembleDesign.Icon.previous)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }

            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.playbackState == .playing ? EnsembleDesign.Icon.pause : EnsembleDesign.Icon.play)
                    .font(EnsembleDesign.Typography.utilityIcon)
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.activeControlOpacity))
            }

            Button(action: viewModel.next) {
                Image(systemName: EnsembleDesign.Icon.forward)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
        }
        .chromelessMediaControlButton()
        .ensembleStandardShadow()
    }

    // MARK: - Helpers

    /// Intro dot progress: time-synced if there's a real intro gap, otherwise just past/future
    private var introProgress: Double {
        if viewModel.hasIntroInstrumentalGap {
            let isIntroActive = lyricsScrollTargetIndex == nil
                && instrumentalProgress != nil
            if isIntroActive {
                return instrumentalProgress ?? 0
            }
        }
        // Filled once any lyric line has been reached
        let hasStarted = currentLyricsLineIndex != nil
            || lyricsScrollTargetIndex != nil
        return hasStarted ? 1.0 : 0.0
    }

    /// Outro dot progress: time-synced if there's a real outro gap, otherwise just past/future
    private func outroProgress(lastIndex: Int) -> Double {
        if viewModel.hasOutroInstrumentalGap {
            let isOutroActive = instrumentalProgress != nil
                && currentLyricsLineIndex == nil
                && lyricsScrollTargetIndex == lastIndex
            if isOutroActive {
                return instrumentalProgress ?? 0
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
    private func lineOpacity(isTimed: Bool, isActive: Bool, isNextActive: Bool = false, isPast: Bool) -> Double {
        guard isTimed else { return EnsembleScaffold.NowPlaying.lyricPlainOpacity }
        if isActive { return 1.0 }
        if isNextActive { return 0.78 }
        if isPast { return EnsembleScaffold.NowPlaying.lyricPastOpacity }
        return EnsembleScaffold.NowPlaying.lyricFutureOpacity
    }

    private func isNextChordLine(index: Int) -> Bool {
        guard viewModel.isDisplayingChordLyrics,
              let currentLyricsLineIndex,
              index == currentLyricsLineIndex + 1 else {
            return false
        }
        return true
    }

    /// Progressive blur based on distance from the active line (which is centered in viewport).
    /// Lines close to the active line are sharp; distant lines blur progressively.
    /// Disabled when native scroll-phase observation is unavailable so user scrolling stays readable.
    private func lineBlurRadius(index: Int, isTimed: Bool) -> CGFloat {
        guard isTimed, supportsProgressiveLyricsBlur, !isLowPowerMode, !isUserDrivenLyricsScrollActive else { return 0 }

        // Use active line index, fall back to scroll target during instrumental gaps
        let center = currentLyricsLineIndex
            ?? lyricsScrollTargetIndex
        guard let center else { return 0 }

        let distance = abs(index - center)
        guard distance > EnsembleScaffold.NowPlaying.lyricBlurStartDistance else { return 0 }
        return min(
            CGFloat(distance - EnsembleScaffold.NowPlaying.lyricBlurStartDistance) * EnsembleScaffold.NowPlaying.lyricBlurStep,
            EnsembleScaffold.NowPlaying.lyricMaxBlur
        )
    }

    private var supportsProgressiveLyricsBlur: Bool {
        if #available(iOS 18.0, macOS 15.0, *) {
            return true
        }
        return false
    }

    /// Whether a line is in the past (before the current active line)
    private func isPastLine(index: Int) -> Bool {
        guard let activeIndex = currentLyricsLineIndex else {
            // During instrumental gaps, currentLyricsLineIndex is nil.
            // Use the scroll target as fallback to determine past/future.
            guard let scrollTarget = lyricsScrollTargetIndex else { return false }
            return index < scrollTarget
        }
        return index < activeIndex
    }

    /// Whether a gap after the given index is the currently active instrumental gap.
    /// During gaps, currentLyricsLineIndex is nil but the scroll target tracks the
    /// underlying active line index from the binary search.
    private func isCurrentGap(afterIndex index: Int, lyrics: ParsedLyrics) -> Bool {
        guard let scrollTarget = lyricsScrollTargetIndex else { return false }
        return scrollTarget == index
    }

    /// Fade mask matching QueueCard style — gradual top and bottom fades
    private var fadeMask: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Top fade (gradual)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.topOpaqueLocation)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.topHeight)

            // Middle: full opacity
            Rectangle().fill(Color.black)

            // Bottom fade (gradual)
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.bottomOpaqueLocation),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.bottomHeight)
        }
    }
}

// MARK: - Equatable Lyrics Line

private struct ChordLyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let isNextActive: Bool
    let isTimed: Bool
    let opacity: Double

    private let characterWidth: CGFloat = 8.3
    private let chordFontSize: CGFloat = 13
    private let lyricFontSize: CGFloat = 13
    private let chordOnlyPlaceholder = "🎵🎵🎵"

    var body: some View {
        GeometryReader { geometry in
            let maxColumns = max(8, Int(geometry.size.width / characterWidth))
            let rows = ChordLineSegments.rows(for: line, maxColumns: maxColumns)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if row.hasVisibleChords {
                        Text(row.chords)
                            .font(.system(size: chordFontSize, weight: .semibold, design: .monospaced))
                            .foregroundColor(EnsembleDesign.Color.accent)
                            .lineLimit(1)
                    }
                    if row.hasVisibleLyric {
                        Text(row.lyric)
                            .font(.system(size: lyricFontSize, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    } else if row.hasVisibleChords {
                        Text(chordOnlyPlaceholder)
                            .font(.system(size: lyricFontSize, weight: .medium, design: .default))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundColor(EnsembleDesign.Color.primaryText)
            .opacity(opacity)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: EnsembleDesign.Animation.quickDuration), value: isActive)
            .animation(.easeInOut(duration: EnsembleDesign.Animation.quickDuration), value: isNextActive)
        }
        .frame(minHeight: ChordLineSegments.estimatedHeight(for: line))
    }
}

enum ChordLineSegments {
    struct Row: Equatable {
        let chords: String
        let lyric: String

        var hasVisibleChords: Bool {
            !chords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var hasVisibleLyric: Bool {
            !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func rows(for line: LyricsLine, maxColumns: Int) -> [Row] {
        let chordLine = chordDisplayLine(for: line.chords)
        let lyricLines = line.text.components(separatedBy: "\n")
        var resultRows: [Row] = []
        for (index, lyric) in lyricLines.enumerated() {
            resultRows.append(contentsOf: rows(
                chordLine: index == 0 ? chordLine : "",
                lyric: lyric,
                maxColumns: maxColumns
            ))
        }
        return resultRows
    }

    static func estimatedHeight(for line: LyricsLine) -> CGFloat {
        let chordLength = line.chords.map { max(0, $0.offsetFromLyricStart) + $0.symbol.count }.max() ?? 0
        let lyricLines = line.text.components(separatedBy: "\n")
        let estimatedRows = lyricLines.enumerated().reduce(0) { partialResult, element in
            let (index, lyric) = element
            let maxLength = index == 0 ? max(chordLength, lyric.count) : lyric.count
            return partialResult + max(1, Int(ceil(Double(maxLength) / 36.0)))
        }
        let rowHeight: CGFloat = line.text.isEmpty && line.chords.isEmpty ? 16 : 34
        return CGFloat(max(1, estimatedRows)) * rowHeight
    }

    private static func rows(chordLine: String, lyric: String, maxColumns: Int) -> [Row] {
        let width = max(1, maxColumns)
        let maxLength = max(chordLine.count, lyric.count)
        guard maxLength > 0 else { return [] }

        var rows: [Row] = []
        var start = 0
        while start < maxLength {
            let length = preferredSegmentLength(chordLine: chordLine, lyric: lyric, start: start, maxColumns: width)
            rows.append(Row(
                chords: slice(chordLine, start: start, length: length).trimmingTrailingWhitespace(),
                lyric: slice(lyric, start: start, length: length).trimmingTrailingWhitespace()
            ))
            start += max(1, length)
        }
        return rows
    }

    private static func preferredSegmentLength(
        chordLine: String,
        lyric: String,
        start: Int,
        maxColumns: Int
    ) -> Int {
        let remaining = max(chordLine.count, lyric.count) - start
        guard remaining > maxColumns else { return remaining }

        if hasVisibleContent(in: lyric, start: start),
           let lyricBreak = lastLyricBreakPreservingChords(chordLine: chordLine, lyric: lyric, start: start, maxColumns: maxColumns) {
            return max(1, lyricBreak - start)
        }

        if let chordBreak = lastWhitespaceBreak(in: chordLine, start: start, maxColumns: maxColumns),
           isLyricSafeBoundary(in: lyric, boundary: chordBreak) {
            return max(1, chordBreak - start)
        }

        if hasVisibleContent(in: lyric, start: start),
           let lyricBreak = lastWhitespaceBreak(in: lyric, start: start, maxColumns: maxColumns) {
            return max(1, lyricBreak - start)
        }

        return maxColumns
    }

    private static func hasVisibleContent(in value: String, start: Int) -> Bool {
        guard start < value.count else { return false }
        let characters = Array(value)
        return characters[start...].contains { !$0.isWhitespace }
    }

    private static func lastLyricBreakPreservingChords(
        chordLine: String,
        lyric: String,
        start: Int,
        maxColumns: Int
    ) -> Int? {
        guard start < lyric.count else { return nil }
        let characters = Array(lyric)
        let end = min(characters.count, start + maxColumns)
        guard end > start else { return nil }
        let minimumBreak = start + max(8, maxColumns / 2)

        for index in stride(from: end - 1, through: start, by: -1) {
            guard index >= minimumBreak,
                  characters[index].isWhitespace,
                  isChordSafeBoundary(in: chordLine, boundary: index + 1) else {
                continue
            }
            return index + 1
        }

        let extendedEnd = min(characters.count, start + maxColumns + 8)
        guard extendedEnd > end else { return nil }
        for index in end..<extendedEnd {
            guard characters[index].isWhitespace,
                  isChordSafeBoundary(in: chordLine, boundary: index + 1) else {
                continue
            }
            return index + 1
        }
        return nil
    }

    private static func isChordSafeBoundary(in value: String, boundary: Int) -> Bool {
        guard boundary > 0, boundary < value.count else { return true }
        let characters = Array(value)
        return characters[boundary - 1].isWhitespace || characters[boundary].isWhitespace
    }

    private static func isLyricSafeBoundary(in value: String, boundary: Int) -> Bool {
        guard boundary > 0, boundary < value.count else { return true }
        let characters = Array(value)
        return characters[boundary - 1].isWhitespace || characters[boundary].isWhitespace
    }

    private static func lastWhitespaceBreak(in value: String, start: Int, maxColumns: Int) -> Int? {
        guard start < value.count else { return nil }
        let characters = Array(value)
        let end = min(characters.count, start + maxColumns)
        guard end > start else { return nil }
        let minimumBreak = start + max(8, maxColumns / 2)

        for index in stride(from: end - 1, through: start, by: -1) {
            guard index >= minimumBreak, characters[index].isWhitespace else { continue }
            return index + 1
        }
        return nil
    }

    private static func chordDisplayLine(for chords: [ParsedChord]) -> String {
        guard !chords.isEmpty else { return "" }
        let maxColumn = chords.map { max(0, $0.offsetFromLyricStart) + $0.symbol.count }.max() ?? 0
        var characters = Array(repeating: Character(" "), count: maxColumn)

        for chord in chords.sorted(by: { $0.offsetFromLyricStart < $1.offsetFromLyricStart }) {
            let start = max(0, chord.offsetFromLyricStart)
            let symbolCharacters = Array(chord.symbol)
            if characters.count < start + symbolCharacters.count {
                characters.append(contentsOf: Array(repeating: Character(" "), count: start + symbolCharacters.count - characters.count))
            }
            for (offset, character) in symbolCharacters.enumerated() {
                characters[start + offset] = character
            }
        }

        return String(characters)
    }

    private static func slice(_ value: String, start: Int, length: Int) -> String {
        guard start < value.count else { return "" }
        let characters = Array(value)
        let end = min(characters.count, start + length)
        return String(characters[start..<end])
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        guard let lastNonWhitespace = lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[...lastNonWhitespace])
    }
}

private struct LyricsLineView: View, Equatable {
    let text: String
    let isActive: Bool
    let isTimed: Bool
    let opacity: Double
    let blur: CGFloat

    var body: some View {
        Text(text)
            .font(EnsembleDesign.Typography.detailSubtitle)
            .fontWeight(.medium)
            .foregroundColor(EnsembleDesign.Color.primaryText)
            .opacity(opacity)
            .scaleEffect(isActive && isTimed ? EnsembleScaffold.NowPlaying.lyricActiveScale : 1.0, anchor: .leading)
            .blur(radius: blur)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: EnsembleDesign.Animation.quickDuration), value: isActive)
            .animation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration), value: blur)
    }
}
