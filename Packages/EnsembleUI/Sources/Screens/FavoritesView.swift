import EnsembleCore
import SwiftUI

/// View showing favorited/loved tracks (rated 4+ stars)
public struct FavoritesView: View {
    @StateObject private var viewModel: FavoritesViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    
    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeFavoritesViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.tracks.isEmpty {
                loadingView
            } else if viewModel.tracks.isEmpty {
                emptyView
            } else {
                MediaDetailView(
                    viewModel: viewModel,
                    nowPlayingVM: nowPlayingVM,
                    headerData: headerData,
                    navigationTitle: "Favorites",
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false
                )
            }
        }
        .navigationTitle("Favorites")
    }
    
    private var headerData: MediaHeaderData {
        MediaHeaderData(
            title: "Favorites",
            subtitle: "\(viewModel.tracks.count) tracks",
            metadataLine: "Your loved tracks",
            artworkPath: viewModel.tracks.first?.thumbPath,
            sourceKey: viewModel.tracks.first?.sourceCompositeKey,
            ratingKey: viewModel.tracks.first?.id
        )
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading favorites...")
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Favorites Yet")
                .font(.title2)
            
            VStack(spacing: 8) {
                Text("Rate tracks 4 or 5 stars to add them here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
