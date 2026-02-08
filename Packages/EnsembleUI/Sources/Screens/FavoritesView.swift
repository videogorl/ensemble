import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// View showing favorited/loved tracks (rated 4+ stars)
/// Offline-first hub that displays tracks from CoreData across all servers and libraries
public struct FavoritesView: View {
    @StateObject private var viewModel: FavoritesViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    
    private var backgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
    
    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeFavoritesViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        Group {
            if viewModel.tracks.isEmpty {
                emptyView
            } else {
                trackListView
            }
        }
        .navigationTitle("Favorites")
        .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter favorites")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.tracks.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                
                                // Badge indicator when filters are active
                                if viewModel.filterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                        
                        Menu {
                            Button {
                                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
                            } label: {
                                Label("Shuffle All", systemImage: "shuffle")
                            }
                            
                            Button {
                                nowPlayingVM.play(tracks: viewModel.filteredTracks)
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if !viewModel.tracks.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                if viewModel.filterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                    }
                }
            }
            #endif
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $viewModel.filterOptions
            )
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
                
                Text("\(viewModel.tracks.count) total tracks • Showing favorites from all libraries")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
    
    private var trackListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Header stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(viewModel.filteredTracks.count) favorite tracks")
                        .font(.headline)
                    Text("All libraries • \(viewModel.totalDuration)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                Divider()
                
                // Track list
                ForEach(Array(viewModel.filteredTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        showArtwork: true,
                        isPlaying: track.id == nowPlayingVM.currentTrack?.id
                    ) {
                        nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                    }
                    .id(track.id)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    
                    if index < viewModel.filteredTracks.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .padding(.vertical)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }
    }
}
