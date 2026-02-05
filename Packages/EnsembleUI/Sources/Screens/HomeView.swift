import EnsembleCore
import SwiftUI

public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    let onArtistTap: (Artist) -> Void
    let onPlaylistTap: (Playlist) -> Void
    
    public init(
        nowPlayingVM: NowPlayingViewModel,
        onAlbumTap: @escaping (Album) -> Void,
        onArtistTap: @escaping (Artist) -> Void,
        onPlaylistTap: @escaping (Playlist) -> Void
    ) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
        self.onArtistTap = onArtistTap
        self.onPlaylistTap = onPlaylistTap
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
            print("🏠 HomeView: .task {} modifier triggered at \(Date())")
            // Spawn a detached task so we don't block the view's task modifier
            print("🏠 HomeView: Creating Task.detached...")
            let task = Task.detached(priority: .userInitiated) { [viewModel] in
                print("🏠 HomeView: Task.detached started executing at \(Date())")
                print("🏠 HomeView: About to call viewModel.loadHubs() at \(Date())")
                await viewModel.loadHubs()
                print("🏠 HomeView: Returned from viewModel.loadHubs() at \(Date())")
                print("🏠 HomeView: Task.detached completed at \(Date())")
            }
            print("🏠 HomeView: Task.detached created, .task {} returning at \(Date())")
        }
        .refreshable {
            print("🏠 HomeView: .refreshable {} triggered")
            await viewModel.refresh()
            print("🏠 HomeView: .refreshable {} completed")
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
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 60)
                
                Image(systemName: "house")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                
                Text("Welcome Home")
                    .font(.title2)
                
                VStack(spacing: 8) {
                    if let errorMessage = viewModel.error {
                        Text("Unable to load content")
                            .font(.subheadline)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Text("No content available yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Your Plex server may not have hub data available, or content may still be loading. Pull down to refresh.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
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
                        onArtistTap: onArtistTap,
                        onPlaylistTap: onPlaylistTap
                    )
                }
            }
            .padding(.vertical)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 110)
        }
    }
}

// MARK: - Hub Section

struct HubSection: View {
    let hub: Hub
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    let onArtistTap: (Artist) -> Void
    let onPlaylistTap: (Playlist) -> Void
    
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
                            onArtistTap: onArtistTap,
                            onPlaylistTap: onPlaylistTap
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
    let onPlaylistTap: (Playlist) -> Void
    
    var body: some View {
        Button {
            handleTap()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Artwork
                ArtworkView(
                    path: item.thumbPath,
                    sourceKey: item.sourceCompositeKey,
                    ratingKey: item.id,
                    size: .medium,
                    cornerRadius: item.type == "artist" ? 80 : 8
                )
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                
                VStack(alignment: item.type == "artist" ? .center : .leading, spacing: 2) {
                    // Title
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(item.type == "artist" ? .center : .leading)
                    
                    // Subtitle (Artist or Album name)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(item.type == "artist" ? .center : .leading)
                    }
                    
                    // Extra info for albums (Year)
                    if item.type == "album", let year = item.year {
                        Text(String(year))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 160, alignment: item.type == "artist" ? .center : .leading)
            }
        }
        .buttonStyle(.plain)
    }
    
    private func handleTap() {
        print("🏠 HubItemCard: Tapped item '\(item.title)' of type '\(item.type)'")
        
        if item.type == "album" {
            if let album = item.album {
                print("🏠 HubItemCard: Navigating to album using reference")
                onAlbumTap(album)
            } else {
                print("🏠 HubItemCard: Navigating to album using skeleton")
                let skeleton = Album(
                    id: item.id,
                    key: item.id,
                    title: item.title,
                    artistName: item.subtitle,
                    year: item.year,
                    thumbPath: item.thumbPath,
                    sourceCompositeKey: item.sourceCompositeKey
                )
                onAlbumTap(skeleton)
            }
        } else if item.type == "track" {
            if let track = item.track {
                print("🏠 HubItemCard: Playing track using reference")
                nowPlayingVM.play(tracks: [track])
            } else {
                print("🏠 HubItemCard: Playing track using skeleton")
                let skeleton = Track(
                    id: item.id,
                    key: item.id,
                    title: item.title,
                    artistName: item.subtitle,
                    thumbPath: item.thumbPath,
                    sourceCompositeKey: item.sourceCompositeKey
                )
                nowPlayingVM.play(tracks: [skeleton])
            }
        } else if item.type == "artist" {
            if let artist = item.artist {
                print("🏠 HubItemCard: Navigating to artist using reference")
                onArtistTap(artist)
            } else {
                print("🏠 HubItemCard: Navigating to artist using skeleton")
                let skeleton = Artist(
                    id: item.id,
                    key: item.id,
                    name: item.title,
                    thumbPath: item.thumbPath,
                    sourceCompositeKey: item.sourceCompositeKey
                )
                onArtistTap(skeleton)
            }
        } else if item.type == "playlist" {
            if let playlist = item.playlist {
                print("🏠 HubItemCard: Navigating to playlist using reference")
                onPlaylistTap(playlist)
            } else {
                print("🏠 HubItemCard: Navigating to playlist using skeleton")
                let skeleton = Playlist(
                    id: item.id,
                    key: item.id,
                    title: item.title,
                    sourceCompositeKey: item.sourceCompositeKey
                )
                onPlaylistTap(skeleton)
            }
        } else {
            print("🏠 HubItemCard: Unknown item type '\(item.type)', no action taken")
        }
    }
}