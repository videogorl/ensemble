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
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var isStageFlowActive = false
    @State private var cachedStageFlowAlbums: [SongsStageFlowAlbum] = []
    // Targeted observation: only re-evaluate when these specific values change,
    // not when any of offlineDownloadService's 5+ @Published props update
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration

    private var supportsStageFlow: Bool {
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
        Group {
            if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                loadingView
            } else if libraryVM.tracks.isEmpty {
                emptyView
            } else if isStageFlowActive {
                landscapeAlbumStageFlowView
            } else {
                trackListView
            }
        }
        // Detect landscape for StageFlow via background GeometryReader.
        // Placed in .background so it doesn't block the navigation controller
        // from finding the ScrollView for large title collapse tracking.
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        isStageFlowActive = supportsStageFlow && geometry.size.width > geometry.size.height
                    }
                    .onChange(of: geometry.size) { newSize in
                        isStageFlowActive = supportsStageFlow && newSize.width > newSize.height
                    }
            }
        )
        .hideTabBarIfAvailable(isHidden: isStageFlowActive)
        .stageFlowRotationSupport(isEnabled: supportsStageFlow)
        #if os(iOS)
        .preference(key: ChromeVisibilityPreferenceKey.self, value: isStageFlowActive)
        #endif
        .navigationTitle(isStageFlowActive ? "" : "Songs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(isStageFlowActive ? .inline : .large)
        #endif
        .searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .if(!isViewportNowPlayingPresented) { content in
            content.toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.tracks.isEmpty && !isStageFlowActive {
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
                    if !libraryVM.tracks.isEmpty && !isStageFlowActive {
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
                #endif
            }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(libraryVM.$filteredTracks) { tracks in
            let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: tracks)
            if rebuiltAlbums != cachedStageFlowAlbums {
                cachedStageFlowAlbums = rebuiltAlbums
            }
        }
        .onAppear {
            let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: libraryVM.filteredTracks)
            if rebuiltAlbums != cachedStageFlowAlbums {
                cachedStageFlowAlbums = rebuiltAlbums
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.tracksFilterOptions,
                availableGenres: libraryVM.availableTrackGenres,
                showGenreFilter: true
            )
        }
    }

    private var landscapeAlbumStageFlowView: some View {
        #if os(iOS)
        albumStageFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        albumStageFlowView
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
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
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
                    DependencyContainer.shared.navigationCoordinator.openSettings()
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
                #if os(iOS)
                // Indexed mode: ScrollView + LazyVStack for section headers + scroll index
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            GenreChipBar(
                                availableGenres: libraryVM.availableTrackGenres,
                                selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
                                excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
                            )
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
                #else
                // macOS indexed mode: List with Section headers + native swipe actions
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        List {
                            // Genre chip bar as a non-interactive header section
                            Section {
                                GenreChipBar(
                                    availableGenres: libraryVM.availableTrackGenres,
                                    selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
                                    excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
                                )
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)

                            ForEach(libraryVM.trackSections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    ForEach(Array(section.tracks.enumerated()), id: \.element.id) { _, track in
                                        TrackRow(
                                            track: track,
                                            showArtwork: true,
                                            isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                                            onPlayNext: { nowPlayingVM.playNext(track) },
                                            onPlayLast: { nowPlayingVM.playLast(track) },
                                            onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                                            onAddToRecentPlaylist: { addToRecentPlaylist(track) },
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
                                            recentPlaylistTitle: recentPlaylistTitle(for: track)
                                        ) {
                                            if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                                                nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                                            }
                                        }
                                        .trackSwipeActions(
                                            track: track,
                                            nowPlayingVM: nowPlayingVM,
                                            onPlayNext: { nowPlayingVM.playNext(track) },
                                            onPlayLast: { nowPlayingVM.playLast(track) },
                                            onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                                        )
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    }
                                }
                                .id(section.letter)
                            }
                        }
                        .listStyle(.plain)
                        .modifier(ClearScrollContentBackgroundModifier())
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
                #endif
            } else {
                #if os(iOS)
                // Non-indexed mode: UITableView manages its own scrolling directly.
                // No SwiftUI ScrollView wrapper — avoids the fixed-frame height hack
                // that was forcing all 1500+ rows to be laid out simultaneously.
                VStack(spacing: 0) {
                    GenreChipBar(
                        availableGenres: libraryVM.availableTrackGenres,
                        selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
                        excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
                    )
                    unsortedTrackListContent
                }
                #else
                VStack(spacing: 0) {
                    GenreChipBar(
                        availableGenres: libraryVM.availableTrackGenres,
                        selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
                        excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
                    )
                    unsortedTrackListContent
                }
                #endif
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
            let trackCount = section.tracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount * 68)

            #if os(iOS)
            MediaTrackList(
                tracks: section.tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: nowPlayingVM.currentTrack?.id,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
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
            // macOS: uses List rows with native .swipeActions (applied in the wrapping List)
            ForEach(Array(section.tracks.enumerated()), id: \.element.id) { _, track in
                TrackRow(
                    track: track,
                    showArtwork: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                    onAddToRecentPlaylist: { addToRecentPlaylist(track) },
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
                    recentPlaylistTitle: recentPlaylistTitle(for: track)
                ) {
                    if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                        nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                    }
                }
                .trackSwipeActions(
                    track: track,
                    nowPlayingVM: nowPlayingVM,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            #endif
        }
        .id(section.letter)
    }
    
    /// Non-indexed mode: self-scrolling UITableView with cell recycling.
    private var unsortedTrackListContent: some View {
        #if os(iOS)
        MediaTrackList(
            tracks: libraryVM.filteredTracks,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
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
        // macOS: List with native .swipeActions for trackpad two-finger swipe support
        List {
            ForEach(Array(libraryVM.filteredTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                    onAddToRecentPlaylist: { addToRecentPlaylist(track) },
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
                    recentPlaylistTitle: recentPlaylistTitle(for: track)
                ) {
                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
                }
                .trackSwipeActions(
                    track: track,
                    nowPlayingVM: nowPlayingVM,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listStyle(.plain)
        .modifier(ClearScrollContentBackgroundModifier())
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
    
    private var albumStageFlowView: some View {
        StageFlowView(
            items: cachedStageFlowAlbums,
            nowPlayingVM: nowPlayingVM,
            itemView: { album in
                StageFlowItemView(albumItem: album)
            },
            detailView: { selectedAlbum in
                StageFlowTrackPanel(
                    contentType: .album(id: selectedAlbum.albumID, sourceCompositeKey: selectedAlbum.sourceCompositeKey),
                    nowPlayingVM: nowPlayingVM
                )
            },
            titleContent: { $0.title },
            subtitleContent: { $0.artistName },
            resolvePlaybackTracks: { album in
                await resolveStageFlowTracks(for: album)
            },
            selectedItem: $selectedAlbum
        )
    }

    private func resolveStageFlowTracks(for album: SongsStageFlowAlbum) async -> [Track] {
        let cachedTracks: [CDTrack]
        if let sourceCompositeKey = album.sourceCompositeKey {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.albumID, sourceCompositeKey: sourceCompositeKey)) ?? []
        } else {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.albumID)) ?? []
        }

        return cachedTracks.map { Track(from: $0) }
    }
}
