import EnsembleCore
import SwiftUI

/// Right card displaying scrollable queue with pinned header and secondary controls
/// Includes shuffle, repeat, autoplay buttons relocated from Controls card
public struct QueueCard: View {
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
                Image(systemName: "list.bullet")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.7))
                
                Text("Queue Card")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Scrollable queue with header and secondary controls will go here")
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
