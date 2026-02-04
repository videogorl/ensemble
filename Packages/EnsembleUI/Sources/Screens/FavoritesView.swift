import EnsembleCore
import SwiftUI

/// View showing favorited/loved tracks (rated 4+ stars)
public struct FavoritesView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var trackIndexMap: [String: Int] = [:]
    
    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }
    
    private var favoriteTracks: [Track] {
        libraryVM.filteredTracks.filter { $0.rating >= 8 }  // 4+ stars (8/10)
    }
    
    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                loadingView
            } else if favoriteTracks.isEmpty {
                emptyView
            } else {
                trackListView
            }
        }
        .navigationTitle("Favorites")
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !favoriteTracks.isEmpty {
                    Menu {
                        Button {
                            nowPlayingVM.play(tracks: favoriteTracks.shuffled())
                        } label: {
                            Label("Shuffle All", systemImage: "shuffle")
                        }

                        Button {
                            nowPlayingVM.play(tracks: favoriteTracks)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
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
            
            Text("No Favorites")
                .font(.title2)
            
            Text("Rate tracks 4 or 5 stars to see them here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var trackListView: some View {
        List {
            ForEach(Array(favoriteTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id
                ) {
                    nowPlayingVM.play(tracks: favoriteTracks, startingAt: index)
                }
            }
        }
        .listStyle(.plain)
    }
}
