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
        case .controls: return "play.fill"
        case .lyrics: return lyricsAvailable ? "quote.bubble.fill" : "quote.bubble"
        case .info: return "info.circle"
        }
    }
}

public struct PageIndicator: View {
    @Binding var currentPage: Int
    let lyricsAvailable: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(currentPage: Binding<Int>, lyricsAvailable: Bool = false) {
        self._currentPage = currentPage
        self.lyricsAvailable = lyricsAvailable
    }

    public var body: some View {
        HStack(spacing: 16) {
            ForEach(NowPlayingPage.allCases, id: \.rawValue) { page in
                pageIndicatorItem(for: page, isCurrent: page.rawValue == currentPage)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentPage = page.rawValue
                        }
                    }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func pageIndicatorItem(for page: NowPlayingPage, isCurrent: Bool) -> some View {
        Group {
            if isCurrent {
                // Active page: filled circle
                Circle()
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
            } else {
                // Inactive pages: icon with transparency
                Image(systemName: page.icon(lyricsAvailable: lyricsAvailable))
                    .font(.system(size: 12))
                    .foregroundColor(Color.primary.opacity(0.4))
            }
        }
        .frame(width: 20, height: 20) // Consistent hit area
        .contentShape(Rectangle()) // Expand tap area
    }
}
