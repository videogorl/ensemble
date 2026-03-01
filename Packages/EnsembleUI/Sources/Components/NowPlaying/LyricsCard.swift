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
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            // Scrollable content area with fade masks
            contentView
            
            // Page indicator at bottom
            PageIndicator(currentPage: currentPage)
                .padding(.bottom, 20)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Content
    
    private var contentView: some View {
        ZStack {
            // Placeholder content
            VStack(spacing: 16) {
                Image(systemName: "text.quote")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.3))
                
                Text("Lyrics coming soon")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.6))
                
                Text("Lyrics display and time-synced\nhighlighting will be available\nin a future update")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .mask(
            VStack(spacing: 0) {
                // Top fade
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.05)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 30)
                
                // Middle: full opacity
                Rectangle().fill(Color.black)
                
                // Bottom fade
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 50)
            }
        )
    }
}
