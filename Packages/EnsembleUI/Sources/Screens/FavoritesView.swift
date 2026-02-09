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
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.tracks.isEmpty {
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
                }
            }
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
            VStack(spacing: 0) {
                // Header with heart icon
                VStack(spacing: 16) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.red)
                        .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text("Favorites")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("\(viewModel.filteredTracks.count) tracks • \(viewModel.totalDuration)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("All libraries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)

                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        nowPlayingVM.play(tracks: viewModel.filteredTracks)
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }

                    Button {
                        nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
                    } label: {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Shuffle")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)

                // Track list
                LazyVStack(alignment: .leading, spacing: 0) {
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
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }
    }
}
