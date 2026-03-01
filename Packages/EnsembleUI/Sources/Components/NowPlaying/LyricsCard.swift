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
        VStack(spacing: 20) {
            // Title at top
            Text("Lyrics")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.top, 24)
            
            Spacer()
            
            // Centered placeholder
            VStack(spacing: 16) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.5))
                
                Text("Lyrics coming soon")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            // Page indicator at bottom
            PageIndicator(currentPage: currentPage)
                .padding(.bottom, 20)
        }
    }
}
