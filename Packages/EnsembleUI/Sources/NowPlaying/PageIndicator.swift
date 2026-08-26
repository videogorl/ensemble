import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Visual indicator showing current card/page in the carousel
/// Active page: filled dot; Inactive pages: icon with transparency
/// Follows system color scheme (not accent color)
public enum NowPlayingPage: Int, CaseIterable {
    case queue = 0
    case controls = 1
    case lyrics = 2
    case info = 3

    /// Icon name for the page — lyrics icon varies based on availability
    func icon(lyricsAvailable: Bool) -> String {
        switch self {
        case .queue: return "list.bullet"
        case .controls: return EnsembleDesign.Icon.play
        case .lyrics: return lyricsAvailable ? EnsembleDesign.Icon.lyrics : "quote.bubble"
        case .info: return EnsembleDesign.Icon.info
        }
    }
}

public struct PageIndicator: View {
    @Binding var currentPage: Int
    let lyricsAvailable: Bool

    public init(currentPage: Binding<Int>, lyricsAvailable: Bool = false) {
        self._currentPage = currentPage
        self.lyricsAvailable = lyricsAvailable
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowHorizontalPadding) {
            ForEach(NowPlayingPage.allCases, id: \.rawValue) { page in
                pageIndicatorItem(for: page, isCurrent: page.rawValue == currentPage)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: EnsembleDesign.Animation.standardDuration)) {
                            currentPage = page.rawValue
                        }
                    }
            }
        }
        .padding(.vertical, EnsembleScaffold.NowPlaying.PageIndicator.verticalPadding)
    }

    // MARK: - Helpers

    private func pageIndicatorItem(for page: NowPlayingPage, isCurrent: Bool) -> some View {
        Group {
            if isCurrent {
                // Active page: filled circle
                Circle()
                    .fill(EnsembleDesign.Color.primaryText)
                    .frame(
                        width: EnsembleScaffold.NowPlaying.PageIndicator.activeDotSize,
                        height: EnsembleScaffold.NowPlaying.PageIndicator.activeDotSize
                    )
            } else {
                // Inactive pages: icon with transparency
                Image(systemName: page.icon(lyricsAvailable: lyricsAvailable))
                    .font(.system(size: EnsembleScaffold.NowPlaying.PageIndicator.inactiveIconSize))
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.PageIndicator.inactiveOpacity))
            }
        }
        .frame(
            width: EnsembleScaffold.NowPlaying.PageIndicator.itemSize,
            height: EnsembleScaffold.NowPlaying.PageIndicator.itemSize
        )
        .contentShape(Rectangle()) // Expand tap area
    }
}
