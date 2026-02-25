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
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @StateObject private var viewModel: FavoritesViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    @ObservedObject private var syncCoordinator = DependencyContainer.shared.syncCoordinator
    @State private var showFilterSheet = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var showingAddSourceFlow = false
    @State private var showingManageSources = false
    
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
            #else
            ToolbarItem(placement: .automatic) {
                if !viewModel.tracks.isEmpty {
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
            #endif
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $viewModel.filterOptions
            )
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
        .sheet(isPresented: $showingAddSourceFlow) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .sheet(isPresented: $showingManageSources) {
            SettingsView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Favorites Yet")
                .font(.title2)
            
            if !accountManager.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingAddSourceFlow = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if syncCoordinator.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !hasEnabledLibraries {
                Text("No libraries enabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingManageSources = true
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
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
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var hasEnabledLibraries: Bool {
        accountManager.plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
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
                        TrackSwipeContainer(
                            track: track,
                            nowPlayingVM: nowPlayingVM,
                            onPlayNext: { nowPlayingVM.playNext(track) },
                            onPlayLast: { nowPlayingVM.playLast(track) },
                            onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                        ) {
                            TrackRow(
                                track: track,
                                showArtwork: true,
                                isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                                onPlayNext: { nowPlayingVM.playNext(track) },
                                onPlayLast: { nowPlayingVM.playLast(track) },
                                onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                                onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                                onToggleFavorite: {
                                    Task {
                                        await nowPlayingVM.toggleTrackFavorite(track)
                                    }
                                },
                                isFavorited: nowPlayingVM.isTrackFavorited(track),
                                recentPlaylistTitle: recentPlaylistTitle(for: track)
                            ) {
                                nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                            }
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
        .miniPlayerBottomSpacing(140)
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: "Add to Playlist")
    }

    private func addToRecentPlaylist(_ track: Track) {
        guard recentPlaylistTitle(for: track) != nil else { return }
        Task {
            guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: [track]) else { return }
            _ = try? await nowPlayingVM.addTracks([track], to: playlist)
        }
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        guard let target = nowPlayingVM.lastPlaylistTarget else { return nil }
        let playlist = Playlist(
            id: target.id,
            key: "/playlists/\(target.id)",
            title: target.title,
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: target.sourceCompositeKey
        )
        return nowPlayingVM.compatibleTrackCount([track], for: playlist) > 0 ? target.title : nil
    }
}
