import EnsembleCore
import SwiftUI

public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    let onArtistTap: (Artist) -> Void
    
    public init(
        nowPlayingVM: NowPlayingViewModel,
        onAlbumTap: @escaping (Album) -> Void,
        onArtistTap: @escaping (Artist) -> Void
    ) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
        self.onArtistTap = onArtistTap
    }
    
    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.hubs.isEmpty {
                loadingView
            } else if viewModel.hubs.isEmpty {
                emptyView
            } else {
                hubsScrollView
            }
        }
        .navigationTitle("Home")
        .task {
            await viewModel.loadHubs()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Content")
                .font(.title2)
            
            Text("Sync your library to see content here")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var hubsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.hubs) { hub in
                    HubSection(
                        hub: hub,
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: onAlbumTap,
                        onArtistTap: onArtistTap
                    )
                }
            }
            .padding(.vertical)
            .padding(.bottom, 100)
        }
    }
}

// MARK: - Hub Section

struct HubSection: View {
    let hub: Hub
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    let onArtistTap: (Artist) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text(hub.title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            // Horizontal scroll of items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(hub.items) { item in
                        HubItemCard(
                            item: item,
                            nowPlayingVM: nowPlayingVM,
                            onAlbumTap: onAlbumTap,
                            onArtistTap: onArtistTap
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Hub Item Card

struct HubItemCard: View {
    let item: HubItem
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    let onArtistTap: (Artist) -> Void
    
    var body: some View {
        Button {
            handleTap()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Artwork
                ArtworkView(
                    path: item.thumbPath,
                    sourceKey: item.sourceCompositeKey,
                    size: .medium,
                    cornerRadius: 8
                )
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                
                // Title
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .frame(width: 160, alignment: .leading)
                
                // Subtitle
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private func handleTap() {
        if item.type == "album", let album = item.album {
            onAlbumTap(album)
        } else if item.type == "track", let track = item.track {
            nowPlayingVM.play(tracks: [track])
        }
    }
}
