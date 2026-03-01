import EnsembleCore
import SwiftUI

/// Center card displaying artwork, scrubber, playback controls, and secondary controls
/// Extracts and refines existing NowPlayingView controls into standalone card
public struct ControlsCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    
    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Placeholder content
            VStack(spacing: 16) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.7))
                
                Text("Controls Card")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Artwork, scrubber, and playback controls will go here")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Page indicator at bottom
            PageIndicator(currentPage: currentPage)
                .padding(.bottom, 20)
        }
    }
}
