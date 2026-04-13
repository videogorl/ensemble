import EnsembleCore
import SwiftUI

struct WatchRootView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @StateObject private var watchConnectivityCoordinator = DependencyContainer.shared.watchConnectivityCoordinator
    @StateObject private var bootstrap = DependencyContainer.shared.makeWatchBootstrapCoordinator()
    @StateObject private var authViewModel = DependencyContainer.shared.makeAddPlexAccountViewModel()
    @StateObject private var homeViewModel = DependencyContainer.shared.makeHomeViewModel()
    @StateObject private var libraryViewModel = DependencyContainer.shared.makeLibraryViewModel()
    @StateObject private var playlistViewModel = DependencyContainer.shared.makePlaylistViewModel()
    @StateObject private var favoritesViewModel = DependencyContainer.shared.makeFavoritesViewModel()
    @StateObject private var searchViewModel = DependencyContainer.shared.makeSearchViewModel()
    @StateObject private var pinnedViewModel = DependencyContainer.shared.makePinnedViewModel()
    @StateObject private var downloadsViewModel = DependencyContainer.shared.makeDownloadsViewModel()
    @StateObject private var nowPlayingViewModel = DependencyContainer.shared.makeNowPlayingViewModel()
    @StateObject private var playbackHub = DependencyContainer.shared.makeWatchPlaybackHub()

    var body: some View {
        Group {
            switch bootstrap.phase {
            case .awaitingAuthentication:
                WatchAuthenticationView(viewModel: authViewModel)

            case .failed(let message):
                WatchBootstrapErrorView(message: message) {
                    bootstrap.refreshAfterAuthentication()
                }

            case .ready:
                WatchNavigationContainer {
                    WatchMainMenuView(
                        settingsManager: settingsManager,
                        pinnedViewModel: pinnedViewModel,
                        homeViewModel: homeViewModel,
                        libraryViewModel: libraryViewModel,
                        playlistViewModel: playlistViewModel,
                        favoritesViewModel: favoritesViewModel,
                        searchViewModel: searchViewModel,
                        downloadsViewModel: downloadsViewModel,
                        nowPlayingViewModel: nowPlayingViewModel,
                        playbackHub: playbackHub
                    )
                }

            case .idle, .loadingCredentials, .hydratingCloudState, .syncingLibrary:
                WatchBootstrapLoadingView(phase: bootstrap.phase)
            }
        }
        .task {
            bootstrap.bootstrapIfNeeded()
        }
        .onChange(of: bootstrap.phase) { phase in
            guard phase == .ready else { return }
            Task {
                await refreshRootContent()
            }
        }
        .onChange(of: authViewModel.state) { state in
            guard state == .complete else { return }
            bootstrap.refreshAfterAuthentication()
        }
        .onChange(of: watchConnectivityCoordinator.companionCredentials) { credentials in
            guard bootstrap.phase == .awaitingAuthentication, !credentials.isEmpty else { return }
            EnsembleLogger.debug("WatchRootView: companion credentials arrived after auth gate; retrying bootstrap")
            bootstrap.refreshAfterAuthentication()
        }
    }

    @MainActor
    private func refreshRootContent() async {
        await homeViewModel.loadHubs()
        await libraryViewModel.loadLibrary()
        await playlistViewModel.loadPlaylists()
        await favoritesViewModel.loadTracks()
        await pinnedViewModel.loadPinnedItems()
        await downloadsViewModel.refresh()
        await searchViewModel.loadExploreContentIfNeeded()
    }
}

private struct WatchNavigationContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(watchOS 9.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
        }
    }
}

private struct WatchBootstrapLoadingView: View {
    let phase: WatchBootstrapPhase

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var title: String {
        switch phase {
        case .loadingCredentials:
            return "Loading Sources"
        case .hydratingCloudState:
            return "Syncing Cloud State"
        case .syncingLibrary:
            return "Syncing Library"
        default:
            return "Starting Ensemble"
        }
    }

    private var subtitle: String {
        switch phase {
        case .loadingCredentials:
            return "Checking local credentials and iCloud Keychain."
        case .hydratingCloudState:
            return "Applying pins and library selection."
        case .syncingLibrary:
            return "Refreshing your watch library for local playback."
        default:
            return "Preparing the watch app."
        }
    }
}

private struct WatchBootstrapErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)

            Text("Couldn’t Start")
                .font(.headline)

            Text(message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct WatchAuthenticationView: View {
    @ObservedObject var viewModel: AddPlexAccountViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "music.note.house.fill")
                    .font(.title)
                    .foregroundColor(.accentColor)

                Text("Sign In")
                    .font(.headline)

                Text("This watch can sync and play without the iPhone after setup.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                switch viewModel.state {
                case .ready:
                    Button("Continue with Plex") {
                        Task {
                            await viewModel.startAuth()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                case .authenticating(let code, let linkURL):
                    Link(destination: linkURL) {
                        VStack(spacing: 6) {
                            Text("Open plex.tv/link")
                                .font(.caption)
                            Text(code)
                                .font(.title2.monospacedDigit())
                                .fontWeight(.bold)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel") {
                        viewModel.cancelAuth()
                    }
                    .buttonStyle(.bordered)

                case .selectingServer, .selectingLibraries:
                    WatchLibrarySelectionView(viewModel: viewModel)

                case .complete:
                    ProgressView("Finalizing")
                }

                if viewModel.isLoading {
                    ProgressView()
                }

                if let error = viewModel.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }
}

private struct WatchLibrarySelectionView: View {
    @ObservedObject var viewModel: AddPlexAccountViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Libraries")
                .font(.headline)

            Text("Discovered servers stay selected by default. Disable any libraries you don’t want on the watch.")
                .font(.caption2)
                .foregroundColor(.secondary)

            ForEach(viewModel.servers) { server in
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(viewModel.libraries(for: server.id)) { library in
                        Button {
                            viewModel.toggleLibrary(for: server.id, library: library)
                        } label: {
                            HStack {
                                Image(systemName: viewModel.isLibrarySelected(serverId: server.id, libraryKey: library.key)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                Text(library.title)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = viewModel.serverLibraryErrors[server.id] {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            Button("Start Sync") {
                viewModel.confirmLibraries()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedLibraryCompositeKeys.isEmpty)
        }
    }
}

private struct WatchMainMenuView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var pinnedViewModel: PinnedViewModel
    @ObservedObject var homeViewModel: HomeViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var playlistViewModel: PlaylistViewModel
    @ObservedObject var favoritesViewModel: FavoritesViewModel
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var downloadsViewModel: DownloadsViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            if playbackHub.currentTrack != nil || playbackHub.isPhoneReachable {
                NavigationLink {
                    WatchNowPlayingView(playbackHub: playbackHub)
                } label: {
                    Label("Now Playing", systemImage: "play.circle.fill")
                }
            }

            Section("Browse") {
                ForEach(supportedTopLevelTabs) { item in
                    NavigationLink {
                        topLevelDestination(for: item)
                    } label: {
                        Label(item.displayTitle, systemImage: item.systemImage)
                    }
                }
            }

            if !pinnedViewModel.resolvedPins.isEmpty {
                Section("Pins") {
                    ForEach(pinnedViewModel.resolvedPins, id: \.id) { pin in
                        NavigationLink {
                            pinDestination(for: pin)
                        } label: {
                            WatchPinRow(pin: pin)
                        }
                    }
                }
            }
        }
        .navigationTitle("Ensemble")
        .task {
            await pinnedViewModel.loadPinnedItems()
        }
    }

    private var supportedTopLevelTabs: [TabItem] {
        settingsManager.enabledTabs.filter {
            switch $0 {
            case .home, .songs, .artists, .albums, .genres, .playlists, .favorites, .search, .downloads:
                return true
            case .settings:
                return false
            }
        }
    }

    @ViewBuilder
    private func topLevelDestination(for item: TabItem) -> some View {
        switch item {
        case .home:
            WatchFeedView(
                viewModel: homeViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .songs:
            WatchTrackListView(
                title: "Songs",
                tracks: libraryViewModel.filteredTracks,
                playbackHub: playbackHub,
                nowPlayingViewModel: nowPlayingViewModel
            )
        case .artists:
            WatchArtistsView(
                libraryViewModel: libraryViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .albums:
            WatchAlbumsView(
                libraryViewModel: libraryViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .genres:
            WatchGenresView(
                libraryViewModel: libraryViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .playlists:
            WatchPlaylistsView(
                playlistViewModel: playlistViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .favorites:
            WatchTrackListView(
                title: "Favorites",
                tracks: favoritesViewModel.filteredTracks,
                playbackHub: playbackHub,
                nowPlayingViewModel: nowPlayingViewModel
            )
        case .search:
            WatchSearchView(
                viewModel: searchViewModel,
                nowPlayingViewModel: nowPlayingViewModel,
                playbackHub: playbackHub
            )
        case .downloads:
            WatchDownloadsView(viewModel: downloadsViewModel)
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func pinDestination(for pin: ResolvedPin) -> some View {
        switch pin {
        case .album(let album, _):
            WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
        case .artist(let artist, _):
            WatchArtistDetailView(artist: artist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
        case .playlist(let playlist, _):
            WatchPlaylistDetailView(playlist: playlist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
        case .mergedPlaylist(let displayPlaylist, _):
            WatchMergedPlaylistDetailView(
                displayPlaylist: displayPlaylist,
                playbackHub: playbackHub,
                nowPlayingViewModel: nowPlayingViewModel
            )
        }
    }
}

private struct WatchPinRow: View {
    let pin: ResolvedPin

    var body: some View {
        switch pin {
        case .album(let album, _):
            Label(album.title, systemImage: "square.stack")
        case .artist(let artist, _):
            Label(artist.name, systemImage: "person.2")
        case .playlist(let playlist, _):
            Label(playlist.title, systemImage: "music.note.list")
        case .mergedPlaylist(let displayPlaylist, _):
            Label(displayPlaylist.title, systemImage: "music.note.list")
        }
    }
}

private struct WatchFeedView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.hubs.isEmpty {
                ProgressView()
            }

            ForEach(viewModel.hubs) { hub in
                Section(hub.title) {
                    ForEach(hub.items.prefix(8)) { item in
                        feedDestination(for: item)
                    }
                }
            }
        }
        .navigationTitle("Feed")
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.loadHubs()
        }
    }

    @ViewBuilder
    private func feedDestination(for item: HubItem) -> some View {
        if let track = item.track {
            Button {
                playbackHub.play(track: track)
            } label: {
                WatchTrackLabel(track: track)
            }
        } else if let album = item.album {
            NavigationLink {
                WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
            } label: {
                Label(album.title, systemImage: "square.stack")
            }
        } else if let artist = item.artist {
            NavigationLink {
                WatchArtistDetailView(artist: artist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
            } label: {
                Label(artist.name, systemImage: "person.2")
            }
        } else if let playlist = item.playlist {
            NavigationLink {
                WatchPlaylistDetailView(playlist: playlist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
            } label: {
                Label(playlist.title, systemImage: "music.note.list")
            }
        }
    }
}

private struct WatchTrackListView: View {
    let title: String
    let tracks: [Track]
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                WatchTrackRow(
                    track: track,
                    trackIndex: index,
                    allTracks: tracks,
                    playbackHub: playbackHub,
                    nowPlayingViewModel: nowPlayingViewModel
                )
            }
        }
        .navigationTitle(title)
    }
}

private struct WatchAlbumsView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            ForEach(libraryViewModel.filteredAlbums) { album in
                NavigationLink {
                    WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                } label: {
                    Label(album.title, systemImage: "square.stack")
                }
            }
        }
        .navigationTitle("Albums")
        .task {
            await libraryViewModel.loadLibrary()
        }
    }
}

private struct WatchArtistsView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            ForEach(libraryViewModel.filteredArtists) { artist in
                NavigationLink {
                    WatchArtistDetailView(artist: artist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                } label: {
                    Label(artist.name, systemImage: "person.2")
                }
            }
        }
        .navigationTitle("Artists")
        .task {
            await libraryViewModel.loadLibrary()
        }
    }
}

private struct WatchGenresView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            ForEach(libraryViewModel.filteredGenres) { genre in
                let matchingTracks = libraryViewModel.filteredTracks.filter { $0.genres.contains(genre.title) }
                NavigationLink {
                    WatchTrackListView(
                        title: genre.title,
                        tracks: matchingTracks,
                        playbackHub: playbackHub,
                        nowPlayingViewModel: nowPlayingViewModel
                    )
                } label: {
                    Label(genre.title, systemImage: "guitars")
                }
            }
        }
        .navigationTitle("Genres")
        .task {
            await libraryViewModel.loadLibrary()
        }
    }
}

private struct WatchPlaylistsView: View {
    @ObservedObject var playlistViewModel: PlaylistViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            ForEach(playlistViewModel.displayPlaylists) { displayPlaylist in
                NavigationLink {
                    if displayPlaylist.isMerged {
                        WatchMergedPlaylistDetailView(
                            displayPlaylist: displayPlaylist,
                            playbackHub: playbackHub,
                            nowPlayingViewModel: nowPlayingViewModel
                        )
                    } else {
                        WatchPlaylistDetailView(
                            playlist: displayPlaylist.primaryPlaylist,
                            playbackHub: playbackHub,
                            nowPlayingViewModel: nowPlayingViewModel
                        )
                    }
                } label: {
                    Label(displayPlaylist.title, systemImage: "music.note.list")
                }
            }
        }
        .navigationTitle("Playlists")
        .task {
            await playlistViewModel.loadPlaylists()
        }
    }
}

private struct WatchDownloadsView: View {
    @ObservedObject var viewModel: DownloadsViewModel

    var body: some View {
        List {
            if !viewModel.librarySummaries.isEmpty {
                Section("Libraries") {
                    ForEach(viewModel.librarySummaries) { summary in
                        Button {
                            Task {
                                await viewModel.setLibraryEnabled(
                                    sourceCompositeKey: summary.sourceCompositeKey,
                                    title: summary.libraryName,
                                    isEnabled: !summary.isEnabled
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: summary.isEnabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    Text(summary.libraryName)
                                    Spacer()
                                }
                                Text("\(summary.downloadedTrackCount) of \(summary.totalTrackCount) tracks")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            if !viewModel.items.isEmpty {
                Section("Targets") {
                    ForEach(viewModel.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.status.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem {
                Button(viewModel.isQueueRunning ? "Pause" : "Resume") {
                    Task {
                        if viewModel.isQueueRunning {
                            await viewModel.pauseQueue()
                        } else {
                            await viewModel.resumeQueue()
                        }
                    }
                }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.refresh()
        }
    }
}

private struct WatchSearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @ObservedObject var playbackHub: WatchPlaybackHub

    var body: some View {
        List {
            if viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !viewModel.recentSearches.isEmpty {
                    Section("Recent") {
                        ForEach(viewModel.recentSearches, id: \.self) { query in
                            Button(query) {
                                viewModel.searchQuery = query
                            }
                        }
                    }
                }

                if !viewModel.recentlyPlayedAlbums.isEmpty {
                    Section("Recently Played") {
                        ForEach(viewModel.recentlyPlayedAlbums.prefix(6)) { album in
                            NavigationLink {
                                WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                            } label: {
                                Label(album.title, systemImage: "clock")
                            }
                        }
                    }
                }
            } else {
                if !viewModel.artistResults.isEmpty {
                    Section("Artists") {
                        ForEach(viewModel.artistResults) { artist in
                            NavigationLink {
                                WatchArtistDetailView(artist: artist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                            } label: {
                                Label(artist.name, systemImage: "person.2")
                            }
                        }
                    }
                }

                if !viewModel.albumResults.isEmpty {
                    Section("Albums") {
                        ForEach(viewModel.albumResults) { album in
                            NavigationLink {
                                WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                            } label: {
                                Label(album.title, systemImage: "square.stack")
                            }
                        }
                    }
                }

                if !viewModel.playlistResults.isEmpty {
                    Section("Playlists") {
                        ForEach(viewModel.playlistResults) { playlist in
                            NavigationLink {
                                WatchPlaylistDetailView(playlist: playlist, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                            } label: {
                                Label(playlist.title, systemImage: "music.note.list")
                            }
                        }
                    }
                }

                if !viewModel.trackResults.isEmpty {
                    Section("Songs") {
                        ForEach(Array(viewModel.trackResults.enumerated()), id: \.element.id) { index, track in
                            WatchTrackRow(
                                track: track,
                                trackIndex: index,
                                allTracks: viewModel.trackResults,
                                playbackHub: playbackHub,
                                nowPlayingViewModel: nowPlayingViewModel
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $viewModel.searchQuery, prompt: "Search")
        .task {
            await viewModel.loadExploreContentIfNeeded()
        }
    }
}

private struct WatchNowPlayingView: View {
    @ObservedObject var playbackHub: WatchPlaybackHub
    @State private var showsTargetPicker = false
    @State private var showsQueueActions = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let track = playbackHub.currentTrack {
                    WatchArtworkImage(track: track, size: 120)

                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if let artist = track.artistName {
                            Text(artist)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: playbackHub.progress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(playbackHub.formattedCurrentTime)
                        Spacer()
                        Text(playbackHub.formattedRemainingTime)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        Button(action: playbackHub.previous) {
                            Image(systemName: "backward.fill")
                        }

                        Button(action: playbackHub.togglePlayPause) {
                            Image(systemName: playbackHub.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }

                        Button(action: playbackHub.next) {
                            Image(systemName: "forward.fill")
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Nothing Playing")
                            .font(.headline)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Now Playing")
        .toolbar {
            ToolbarItem {
                Button {
                    showsTargetPicker = true
                } label: {
                    Image(systemName: "airplayaudio")
                }
                .accessibilityLabel("Playback Target")
            }

            ToolbarItem {
                Button {
                    showsQueueActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More Actions")
            }
        }
        .confirmationDialog("Playback Target", isPresented: $showsTargetPicker) {
            ForEach(playbackHub.availableTargets) { target in
                Button {
                    playbackHub.selectTarget(target)
                } label: {
                    Label(
                        target.displayName,
                        systemImage: target == playbackHub.selectedTarget ? "checkmark" : target.systemImage
                    )
                }
            }
        }
        .confirmationDialog("Queue Controls", isPresented: $showsQueueActions) {
            Button(playbackHub.isShuffleEnabled ? "Disable Shuffle" : "Enable Shuffle") {
                playbackHub.toggleShuffle()
            }
            Button(repeatTitle) {
                playbackHub.cycleRepeatMode()
            }
            Button("Clear Queue", role: .destructive) {
                playbackHub.clearQueue()
            }
        }
    }

    private var repeatTitle: String {
        switch playbackHub.repeatMode {
        case .off:
            return "Repeat Off"
        case .all:
            return "Repeat All"
        case .one:
            return "Repeat One"
        }
    }
}

private struct WatchAlbumDetailView: View {
    let album: Album
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @StateObject private var viewModel: AlbumDetailViewModel
    @State private var isDownloadEnabled = false
    @State private var showsActions = false

    init(album: Album, playbackHub: WatchPlaybackHub, nowPlayingViewModel: NowPlayingViewModel) {
        self.album = album
        self.playbackHub = playbackHub
        self.nowPlayingViewModel = nowPlayingViewModel
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAlbumDetailViewModel(album: album))
    }

    var body: some View {
        WatchTrackListView(
            title: album.title,
            tracks: viewModel.filteredTracks,
            playbackHub: playbackHub,
            nowPlayingViewModel: nowPlayingViewModel
        )
        .toolbar {
            ToolbarItem {
                Button {
                    showsActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Album Actions")
            }
        }
        .confirmationDialog("Album Actions", isPresented: $showsActions) {
            Button("Play Album") {
                playbackHub.play(tracks: viewModel.filteredTracks, startingAt: 0)
            }
            Button("Shuffle Album") {
                let shuffled = viewModel.filteredTracks.shuffled()
                playbackHub.play(tracks: shuffled, startingAt: 0)
            }
            Button(isDownloadEnabled ? "Remove Download" : "Download Album") {
                Task {
                    await DependencyContainer.shared.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloadEnabled)
                    isDownloadEnabled.toggle()
                }
            }
        }
        .task {
            await viewModel.loadTracks()
            isDownloadEnabled = DependencyContainer.shared.offlineDownloadService.isAlbumDownloadEnabled(album)
        }
    }
}

private struct WatchArtistDetailView: View {
    let artist: Artist
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @StateObject private var viewModel: ArtistDetailViewModel
    @State private var isDownloadEnabled = false
    @State private var showsActions = false

    init(artist: Artist, playbackHub: WatchPlaybackHub, nowPlayingViewModel: NowPlayingViewModel) {
        self.artist = artist
        self.playbackHub = playbackHub
        self.nowPlayingViewModel = nowPlayingViewModel
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeArtistDetailViewModel(artist: artist))
    }

    var body: some View {
        List {
            if !viewModel.filteredAlbums.isEmpty {
                Section("Albums") {
                    ForEach(viewModel.filteredAlbums) { album in
                        NavigationLink {
                            WatchAlbumDetailView(album: album, playbackHub: playbackHub, nowPlayingViewModel: nowPlayingViewModel)
                        } label: {
                            Label(album.title, systemImage: "square.stack")
                        }
                    }
                }
            }

            Section("Songs") {
                ForEach(Array(viewModel.filteredTracks.enumerated()), id: \.element.id) { index, track in
                    WatchTrackRow(
                        track: track,
                        trackIndex: index,
                        allTracks: viewModel.filteredTracks,
                        playbackHub: playbackHub,
                        nowPlayingViewModel: nowPlayingViewModel
                    )
                }
            }
        }
        .navigationTitle(artist.name)
        .toolbar {
            ToolbarItem {
                Button {
                    showsActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Artist Actions")
            }
        }
        .confirmationDialog("Artist Actions", isPresented: $showsActions) {
            Button("Play Artist") {
                playbackHub.play(tracks: viewModel.filteredTracks, startingAt: 0)
            }
            Button("Shuffle Artist") {
                let shuffled = viewModel.filteredTracks.shuffled()
                playbackHub.play(tracks: shuffled, startingAt: 0)
            }
            Button(isDownloadEnabled ? "Remove Download" : "Download Artist") {
                Task {
                    await DependencyContainer.shared.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloadEnabled)
                    isDownloadEnabled.toggle()
                }
            }
        }
        .task {
            await viewModel.loadAlbums()
            await viewModel.loadTracks()
            isDownloadEnabled = DependencyContainer.shared.offlineDownloadService.isArtistDownloadEnabled(artist)
        }
    }
}

private struct WatchPlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @StateObject private var viewModel: PlaylistDetailViewModel
    @State private var isDownloadEnabled = false
    @State private var showsActions = false

    init(playlist: Playlist, playbackHub: WatchPlaybackHub, nowPlayingViewModel: NowPlayingViewModel) {
        self.playlist = playlist
        self.playbackHub = playbackHub
        self.nowPlayingViewModel = nowPlayingViewModel
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
    }

    var body: some View {
        WatchTrackListView(
            title: playlist.title,
            tracks: viewModel.filteredTracks,
            playbackHub: playbackHub,
            nowPlayingViewModel: nowPlayingViewModel
        )
        .toolbar {
            ToolbarItem {
                Button {
                    showsActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Actions")
            }
        }
        .confirmationDialog("Playlist Actions", isPresented: $showsActions) {
            Button("Play Playlist") {
                playbackHub.play(tracks: viewModel.filteredTracks, startingAt: 0)
            }
            Button("Shuffle Playlist") {
                let shuffled = viewModel.filteredTracks.shuffled()
                playbackHub.play(tracks: shuffled, startingAt: 0)
            }
            Button(isDownloadEnabled ? "Remove Download" : "Download Playlist") {
                Task {
                    await DependencyContainer.shared.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloadEnabled)
                    isDownloadEnabled.toggle()
                }
            }
        }
        .task {
            await viewModel.loadTracks()
            isDownloadEnabled = DependencyContainer.shared.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
        }
    }
}

private struct WatchMergedPlaylistDetailView: View {
    let displayPlaylist: DisplayPlaylist
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @StateObject private var viewModel: MergedPlaylistDetailViewModel
    @State private var showsActions = false

    init(displayPlaylist: DisplayPlaylist, playbackHub: WatchPlaybackHub, nowPlayingViewModel: NowPlayingViewModel) {
        self.displayPlaylist = displayPlaylist
        self.playbackHub = playbackHub
        self.nowPlayingViewModel = nowPlayingViewModel
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeMergedPlaylistDetailViewModel(displayPlaylist: displayPlaylist))
    }

    var body: some View {
        WatchTrackListView(
            title: displayPlaylist.title,
            tracks: viewModel.filteredTracks,
            playbackHub: playbackHub,
            nowPlayingViewModel: nowPlayingViewModel
        )
        .toolbar {
            ToolbarItem {
                Button {
                    showsActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Actions")
            }
        }
        .confirmationDialog("Playlist Actions", isPresented: $showsActions) {
            Button("Play Playlist") {
                playbackHub.play(tracks: viewModel.filteredTracks, startingAt: 0)
            }
            Button("Shuffle Playlist") {
                let shuffled = viewModel.filteredTracks.shuffled()
                playbackHub.play(tracks: shuffled, startingAt: 0)
            }
        }
        .task {
            await viewModel.loadTracks()
        }
    }
}

private struct WatchTrackRow: View {
    let track: Track
    let trackIndex: Int
    let allTracks: [Track]
    @ObservedObject var playbackHub: WatchPlaybackHub
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @State private var showsMoreActions = false
    @State private var showsPlaylistPicker = false

    var body: some View {
        Button {
            playbackHub.play(tracks: allTracks, startingAt: trackIndex)
        } label: {
            WatchTrackLabel(track: track)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                showsMoreActions = true
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        .confirmationDialog("Track Actions", isPresented: $showsMoreActions) {
            Button("Play Next") {
                playbackHub.playNext(track)
            }
            Button("Play Last") {
                playbackHub.playLast(track)
            }
            Button("Add to Playlist…") {
                showsPlaylistPicker = true
            }

            if nowPlayingViewModel.isTrackFavorited(track) {
                Button("Unfavorite") {
                    Task { await nowPlayingViewModel.setTrackFavorite(false, for: track) }
                }
            } else {
                Button("Favorite") {
                    Task { await nowPlayingViewModel.setTrackFavorite(true, for: track) }
                }
            }
        }
        .sheet(isPresented: $showsPlaylistPicker) {
            WatchPlaylistPickerView(track: track, nowPlayingViewModel: nowPlayingViewModel)
        }
    }
}

private struct WatchPlaylistPickerView: View {
    let track: Track
    @ObservedObject var nowPlayingViewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playlistViewModel = DependencyContainer.shared.makePlaylistViewModel()

    var body: some View {
        NavigationView {
            List {
                ForEach(playlistViewModel.displayPlaylists) { displayPlaylist in
                    Button(displayPlaylist.title) {
                        Task {
                            _ = try? await nowPlayingViewModel.addTracks([track], to: displayPlaylist.primaryPlaylist)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Add Track")
            .task {
                await playlistViewModel.loadPlaylists()
            }
        }
    }
}

private struct WatchTrackLabel: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .lineLimit(1)
            if let artist = track.artistName {
                Text(artist)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WatchArtworkImage: View {
    let track: Track
    let size: CGFloat
    @State private var artworkURL: URL?

    var body: some View {
        Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: track.id) {
            artworkURL = await DependencyContainer.shared.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: Int(size * 3)
            )
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }
}
