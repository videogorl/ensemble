import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct SongsView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @Environment(\.dependencies) private var deps
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var showingManageSources = false
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @ObservedObject private var offlineDownloadService = DependencyContainer.shared.offlineDownloadService
    @ObservedObject private var trackAvailabilityResolver = DependencyContainer.shared.trackAvailabilityResolver

    private var supportsCoverFlow: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    
    private var backgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isCoverFlowActive = supportsCoverFlow && isLandscape
            
            Group {
                if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                    loadingView
                } else if libraryVM.tracks.isEmpty {
                    emptyView
                } else if isCoverFlowActive {
                    landscapeAlbumCoverFlowView
                } else {
                    trackListView
                }
            }
            .hideTabBarIfAvailable(isHidden: isCoverFlowActive)
            .coverFlowRotationSupport(isEnabled: supportsCoverFlow)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isCoverFlowActive)
            #endif
            .navigationTitle(isCoverFlowActive ? "" : "Songs")
            .searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
            .refreshable {
                await libraryVM.refreshFromServer()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.tracks.isEmpty && !isCoverFlowActive {
                        HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                
                                // Badge indicator when filters are active
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

                        Menu {
                            Menu {
                                ForEach(TrackSortOption.allCases, id: \.self) { option in
                                    Button {
                                        if libraryVM.trackSortOption == option {
                                            libraryVM.tracksFilterOptions.sortDirection =
                                                libraryVM.tracksFilterOptions.sortDirection == .ascending ? .descending : .ascending
                                        } else {
                                            libraryVM.trackSortOption = option
                                            libraryVM.tracksFilterOptions.sortDirection = option.defaultDirection
                                        }
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if libraryVM.trackSortOption == option {
                                                Image(systemName: libraryVM.tracksFilterOptions.sortDirection == .ascending
                                                      ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                            
                            Divider()
                            
                            Button {
                                nowPlayingVM.shufflePlay(tracks: libraryVM.filteredTracks)
                            } label: {
                                Label("Shuffle All", systemImage: "shuffle")
                            }

                            Button {
                                nowPlayingVM.play(tracks: libraryVM.filteredTracks)
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
                    if !libraryVM.tracks.isEmpty && !isCoverFlowActive {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
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
                filterOptions: $libraryVM.tracksFilterOptions
            )
        }
        .sheet(isPresented: $showingManageSources) {
            NavigationView {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingManageSources = false
                            }
                        }
                    }
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        }
    }

    private var landscapeAlbumCoverFlowView: some View {
        #if os(iOS)
        albumCoverFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        albumCoverFlowView
        #endif
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading songs...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Songs")
                .font(.title2)

            if !libraryVM.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if libraryVM.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !libraryVM.hasEnabledLibraries {
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
                Text("No songs found in enabled libraries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var trackListView: some View {
        Group {
            if libraryVM.trackSortOption == .title {
                // Indexed mode: ScrollView + LazyVStack for section headers + scroll index
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            indexedTrackListContent
                        }
                        .miniPlayerBottomSpacing(140)

                        if !libraryVM.filteredTracks.isEmpty {
                            ScrollIndex(
                                letters: libraryVM.trackSections.map { $0.letter },
                                currentLetter: .constant(nil),
                                onLetterTap: { letter in
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            )
                            .frame(maxHeight: .infinity)
                            .ignoresSafeArea(.container, edges: .top)
                        }
                    }
                }
            } else {
                // Non-indexed mode: UITableView manages its own scrolling directly.
                // No SwiftUI ScrollView wrapper — avoids the fixed-frame height hack
                // that was forcing all 1500+ rows to be laid out simultaneously.
                unsortedTrackListContent
            }
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }
    
    private var indexedTrackListContent: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(libraryVM.trackSections) { section in
                indexedSection(section: section)
            }
        }
        .padding(.vertical)
    }
    
    private func indexedSection(section: LibraryViewModel.TrackSection) -> some View {
        Section(header: sectionHeader(section.letter)) {
            #if os(iOS)
            let trackCount = section.tracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount * 68)

            MediaTrackList(
                tracks: section.tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: nowPlayingVM.currentTrack?.id,
                availabilityGeneration: trackAvailabilityResolver.availabilityGeneration,
                activeDownloadRatingKeys: offlineDownloadService.activeDownloadRatingKeys,
                onPlayNext: { track in
                    nowPlayingVM.playNext(track)
                },
                onPlayLast: { track in
                    nowPlayingVM.playLast(track)
                },
                onAddToPlaylist: { track in
                    presentPlaylistPicker(with: [track])
                },
                onAddToRecentPlaylist: { track in
                    addToRecentPlaylist(track)
                },
                onToggleFavorite: { track in
                    Task {
                        await nowPlayingVM.toggleTrackFavorite(track)
                    }
                },
                onGoToAlbum: { track in
                    if let albumId = track.albumRatingKey {
                        DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                    }
                },
                onGoToArtist: { track in
                    if let artistId = track.artistRatingKey {
                        DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                    }
                },
                onShareLink: { track in
                    ShareActions.shareTrackLink(track, deps: deps)
                },
                onShareFile: { track in
                    ShareActions.shareTrackFile(track, deps: deps)
                },
                isTrackFavorited: { track in
                    nowPlayingVM.isTrackFavorited(track)
                },
                canAddToRecentPlaylist: { track in
                    recentPlaylistTitle(for: track) != nil
                },
                recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
            ) { track, _ in
                if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                }
            }
            .frame(height: height)
            .padding(.horizontal)
            #else
            VStack(spacing: 0) {
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
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
                            onGoToAlbum: {
                                if let albumId = track.albumRatingKey {
                                    DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                                }
                            },
                            onGoToArtist: {
                                if let artistId = track.artistRatingKey {
                                    DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                                }
                            },
                            onShareLink: {
                                ShareActions.shareTrackLink(track, deps: deps)
                            },
                            onShareFile: {
                                ShareActions.shareTrackFile(track, deps: deps)
                            },
                            isFavorited: nowPlayingVM.isTrackFavorited(track),
                            recentPlaylistTitle: recentPlaylistTitle(for: track),
                            onTap: {
                                if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                                }
                            }
                        )
                    }
                    .id(track.id)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    
                    if index < section.tracks.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            #endif
        }
        .id(section.letter)
    }
    
    private var unsortedTrackListContent: some View {
        #if os(iOS)
        // MediaTrackList's UITableView manages its own scrolling and cell recycling.
        // No fixed .frame(height:) — that was defeating virtualization by forcing
        // all rows to be laid out simultaneously.
        return MediaTrackList(
            tracks: libraryVM.filteredTracks,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            availabilityGeneration: trackAvailabilityResolver.availabilityGeneration,
            activeDownloadRatingKeys: offlineDownloadService.activeDownloadRatingKeys,
            managesOwnScrolling: true,
            bottomContentInset: 140,
            onPlayNext: { track in
                nowPlayingVM.playNext(track)
            },
            onPlayLast: { track in
                nowPlayingVM.playLast(track)
            },
            onAddToPlaylist: { track in
                presentPlaylistPicker(with: [track])
            },
            onAddToRecentPlaylist: { track in
                addToRecentPlaylist(track)
            },
            onToggleFavorite: { track in
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            },
            onGoToAlbum: { track in
                if let albumId = track.albumRatingKey {
                    DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                }
            },
            onShareLink: { track in
                ShareActions.shareTrackLink(track, deps: deps)
            },
            onShareFile: { track in
                ShareActions.shareTrackFile(track, deps: deps)
            },
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            },
            canAddToRecentPlaylist: { track in
                recentPlaylistTitle(for: track) != nil
            },
            recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
        ) { _, index in
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
        }
        .padding(.horizontal)
        #else
        return TrackListView(
            tracks: libraryVM.filteredTracks,
            showArtwork: true,
            showTrackNumbers: false,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            onPlayNext: { track in
                nowPlayingVM.playNext(track)
            },
            onPlayLast: { track in
                nowPlayingVM.playLast(track)
            },
            onAddToPlaylist: { track in
                presentPlaylistPicker(with: [track])
            },
            onAddToRecentPlaylist: { track in
                addToRecentPlaylist(track)
            },
            onToggleFavorite: { track in
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            },
            onGoToAlbum: { track in
                if let albumId = track.albumRatingKey {
                    DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                }
            },
            onShareLink: { track in
                ShareActions.shareTrackLink(track, deps: deps)
            },
            onShareFile: { track in
                ShareActions.shareTrackFile(track, deps: deps)
            },
            canAddToRecentPlaylist: { track in
                recentPlaylistTitle(for: track) != nil
            },
            recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title,
            nowPlayingVM: nowPlayingVM
        ) { track, index in
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
        }
        .padding(.vertical)
        #endif
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

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.headline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(backgroundColor.opacity(0.9))
    }
    
    private var albumCoverFlowView: some View {
        CoverFlowView(
            items: libraryVM.albums,
            itemView: { album in
                CoverFlowItemView(album: album)
            },
            detailContent: { selectedAlbum in
                if let selectedAlbum = selectedAlbum {
                    AnyView(
                        CoverFlowDetailView(
                            contentType: .album(selectedAlbum.id),
                            nowPlayingVM: nowPlayingVM
                        )
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            titleContent: { $0.title },
            subtitleContent: { $0.artistName },
            selectedItem: $selectedAlbum
        )
        .background(Color.black)
    }
}
