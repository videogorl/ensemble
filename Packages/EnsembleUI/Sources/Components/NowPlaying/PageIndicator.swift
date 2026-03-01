import SwiftUI

/// Visual indicator showing current card/page in the carousel
/// Active page: filled dot; Inactive pages: icon with transparency
/// Follows system color scheme (not accent color), not tappable
public enum NowPlayingPage: Int, CaseIterable {
    case queue = 0
    case controls = 1
    case lyrics = 2
    
    var icon: String {
        switch self {
        case .queue: return "list.bullet"
        case .controls: return "play.fill"
        case .lyrics: return "text.quote"
        }
    }
}

public struct PageIndicator: View {
    let currentPage: Int
    @Environment(\.colorScheme) private var colorScheme
    
    public init(currentPage: Int) {
        self.currentPage = currentPage
    }
    
    public var body: some View {
        HStack(spacing: 16) {
            ForEach(NowPlayingPage.allCases, id: \.rawValue) { page in
                pageIndicatorItem(for: page, isCurrent: page.rawValue == currentPage)
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
                Image(systemName: page.icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color.primary.opacity(0.4))
            }
        }
        .frame(width: 20, height: 20) // Consistent hit area (though not tappable)
    }
}
