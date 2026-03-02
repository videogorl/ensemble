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
                .padding(.bottom, 60) // Space for fixed page indicator
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Content
    
    private var contentView: some View {
        ZStack {
            // Placeholder content
            VStack(spacing: 16) {
                Image(systemName: "text.quote")
                    .font(.system(size: 48))
                    .foregroundColor(.primary.opacity(0.3))
                
                Text("Lyrics coming soon")
                    .font(.headline)
                    .foregroundColor(.primary.opacity(0.6))
                
                Text("Lyrics display and time-synced\nhighlighting will be available\nin a future update")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
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
