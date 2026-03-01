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
        // TODO: Create pinned header (title, history toggle, menu)
        // Embed QueueTableView with fade masks
        // Move shuffle/repeat/autoplay to secondary controls
        // Add PageIndicator below secondary controls
        Text("Queue Card Placeholder")
            .foregroundColor(.white)
    }
}
