import SwiftUI

/// Visual indicator showing current card/page in the carousel
/// Active page: filled dot; Inactive pages: icon with transparency
/// Follows system color scheme (not accent color), not tappable
public enum NowPlayingPage: Int, CaseIterable {
    case lyrics = 0
    case controls = 1
    case queue = 2
    
    var icon: String {
        switch self {
        case .lyrics: return "text.alignleft"
        case .controls: return "play.circle"
        case .queue: return "list.bullet"
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
        // TODO: Implement icon/dot indicator layout
        // Active: filled circle; Inactive: icon with opacity
        Text("Page Indicator Placeholder")
            .foregroundColor(.white.opacity(0.5))
            .font(.caption2)
    }
}
