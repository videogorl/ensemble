import EnsembleCore
import SwiftUI

/// Left card displaying lyrics (currently a placeholder stub)
/// Includes fade masks for future scroll view implementation
public struct LyricsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    
    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }
    
    public var body: some View {
        // TODO: Implement placeholder with "Lyrics" title
        // Center icon + "Lyrics coming soon" text
        // Add fade masks for future scroll view
        Text("Lyrics Card Placeholder")
            .foregroundColor(.white)
    }
}
