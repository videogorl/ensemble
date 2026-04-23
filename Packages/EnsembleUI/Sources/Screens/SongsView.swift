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
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var isStageFlowActive = false
    @State private var latestContainerSize: CGSize = .zero
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

    private var isKeyboardEditorActive: Bool {
        navigationCoordinator.isKeyboardEditorPresented
    }

    private var isPresenterChromeHidden: Bool {
        isStageFlowActive || isKeyboardEditorActive
    }
    
    private var backgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    private var canShowSongsTable: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone
        #else
        return true
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
                        latestContainerSize = geometry.size
                        let active = supportsStageFlow && geometry.size.width > geometry.size.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        latestContainerSize = newSize
                        let shouldBeActive = supportsStageFlow && newSize.width > newSize.height
                        if shouldBeActive && !isStageFlowActive {
                            isStageFlowActive = true
                        } else if !shouldBeActive && isStageFlowActive {
                            #if os(iOS)
                            if #available(iOS 16.0, *) {
                                isStageFlowActive = false
                            } else {
                                // iOS 15: delay exit to let rotation animation complete
                                // before switching the view tree. Changing nav bar, status bar,
                                // title display mode, and content simultaneously mid-rotation
                                // causes NavigationView layout hangs on iOS 15.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    if latestContainerSize.width < latestContainerSize.height {
                                        isStageFlowActive = false
                                    }
                                }
                            }
                            #else
                            isStageFlowActive = false
                            #endif
                        }
                    }
            }
        )
        .hideTabBarIfAvailable(isHidden: isPresenterChromeHidden)
        .stageFlowRotationSupport(isEnabled: supportsStageFlow)
        .stageFlowImmersiveMode(isActive: isPresenterChromeHidden)
        #if os(iOS)
        .preference(key: ChromeVisibilityPreferenceKey.self, value: isPresenterChromeHidden)
        .navigationBarHidden(isPresenterChromeHidden)
        .statusBar(hidden: isStageFlowActive)
        #endif
        .navigationTitle(isPresenterChromeHidden ? "" : "Songs")
        .if(!isPresenterChromeHidden) { view in
            view.searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
        }
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand("Refresh Songs") {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
                .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.tracks.isEmpty && !isPresenterChromeHidden {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease")

                                // Badge indicator when filters are active
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

                        if canShowSongsTable {
                            songsTableColumnMenu
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
            ToolbarItem { Spacer() }
            ToolbarItem(placement: .primaryActionIfAvailable) {
                if !libraryVM.tracks.isEmpty && !isPresenterChromeHidden {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease")
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

                        if canShowSongsTable {
                            songsTableColumnMenu
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

    /// StageFlow carousel for landscape mode.
    /// Nav bar and status bar hiding are applied at the outer Group level
    /// so SwiftUI diffs a parameter change rather than a view tree swap,
    /// which prevents NavigationView layout hangs on iOS 15 during rotation.
    private var landscapeAlbumStageFlowView: some View {
        albumStageFlowView
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

            if libraryVM.isRestoringCloudSources {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Text("This can take a moment on first launch.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if !libraryVM.hasAnySources {
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
                    navigationCoordinator.openSettings()
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
        GeometryReader { geometry in
            if usesSongsTable(for: geometry.size) {
                songsTableView
            } else {
                compactTrackListView
            }
        }
    }

    private var compactTrackListView: some View {
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
                        .miniPlayerBottomSpacing()

                        if !libraryVM.filteredTracks.isEmpty {
                            ScrollIndex(
                                letters: libraryVM.trackSections.map { $0.letter },
                                currentLetter: .constant(nil),
                                onLetterTap: { letter in
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            )
                            .libraryScrollIndexPositioning()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .hideListRowSeparator()
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
                                                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                                                }
                                            },
                                            onGoToArtist: {
                                                if let artistId = track.artistRatingKey {
                                                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
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
                                        .hideListRowSeparator()
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    }
                                }
                                .id(section.letter)
                            }
                        }
                        .listStyle(.plain)
                        .modifier(ClearScrollContentBackgroundModifier())
                        .miniPlayerBottomSpacing()

                        if !libraryVM.filteredTracks.isEmpty {
                            ScrollIndex(
                                letters: libraryVM.trackSections.map { $0.letter },
                                currentLetter: .constant(nil),
                                onLetterTap: { letter in
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            )
                            .libraryScrollIndexPositioning()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func usesSongsTable(for size: CGSize) -> Bool {
        guard canShowSongsTable else { return false }
        guard #available(iOS 16.0, macOS 12.0, *) else { return false }
        return size.width >= 840
    }

    private var songsTableColumnSpacing: CGFloat { 18 }
    private var songsTableHorizontalPadding: CGFloat { 20 }

    @ViewBuilder
    private var songsTableView: some View {
        VStack(spacing: 0) {
            GenreChipBar(
                availableGenres: libraryVM.availableTrackGenres,
                selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
                excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
            )
            .padding(.vertical, 8)

            GeometryReader { geometry in
                let tableWidth = songsTableContentWidth(for: geometry.size.width)

                ScrollView(.horizontal, showsIndicators: tableWidth > geometry.size.width) {
                    VStack(spacing: 0) {
                        songsTableHeader
                            .frame(width: tableWidth, alignment: .leading)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(libraryVM.filteredTracks.enumerated()), id: \.element.id) { index, track in
                                    songsTableRow(track, index: index)
                                        .frame(width: tableWidth, alignment: .leading)
                                }
                            }
                        }
                        .frame(width: tableWidth, height: max(geometry.size.height - 38, 0))
                    }
                    .frame(width: tableWidth, height: geometry.size.height, alignment: .topLeading)
                }
            }
        }
        .miniPlayerBottomSpacing()
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

    private var songsTableHeader: some View {
        HStack(spacing: songsTableColumnSpacing) {
            ForEach(settingsManager.songsTableColumns) { column in
                songsTableHeaderCell(column)
                    .frame(width: width(for: column), alignment: alignment(for: column))
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, songsTableHorizontalPadding)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.08))
    }

    @ViewBuilder
    private func songsTableHeaderCell(_ column: SongsTableColumn) -> some View {
        if let sortOption = sortOption(for: column) {
            Button {
                toggleSongsTableSort(sortOption)
            } label: {
                HStack(spacing: 4) {
                    Text(column.title)
                    if libraryVM.trackSortOption == sortOption {
                        Image(systemName: libraryVM.tracksFilterOptions.sortDirection == .ascending
                              ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment(for: column))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        } else {
            Text(column.title)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: alignment(for: column))
        }
    }

    private func songsTableRow(_ track: Track, index: Int) -> some View {
        HStack(spacing: songsTableColumnSpacing) {
            ForEach(settingsManager.songsTableColumns) { column in
                songsTableCell(column: column, track: track)
                    .frame(width: width(for: column), alignment: alignment(for: column))
            }
        }
        .font(.callout)
        .padding(.horizontal, songsTableHorizontalPadding)
        .padding(.vertical, 9)
        .background(index.isMultiple(of: 2) ? Color.secondary.opacity(0.055) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
        }
        .contextMenu {
            Button {
                nowPlayingVM.playNext(track)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }

            Button {
                nowPlayingVM.playLast(track)
            } label: {
                Label("Play Last", systemImage: "text.append")
            }

            Button {
                presentPlaylistPicker(with: [track])
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
        }
    }

    @ViewBuilder
    private func songsTableCell(column: SongsTableColumn, track: Track) -> some View {
        switch column {
        case .title:
            HStack(spacing: 6) {
                Text(track.title)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if track.rating >= 8 {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        case .time:
            Text(track.formattedDuration)
                .monospacedDigit()
                .foregroundColor(.secondary)
        case .artist:
            Text(track.artistName ?? "Unknown Artist")
                .lineLimit(1)
        case .album:
            Text(track.albumName ?? "Unknown Album")
                .lineLimit(1)
        case .genre:
            Text(track.genres.first ?? "")
                .lineLimit(1)
        case .favorite:
            Image(systemName: track.rating >= 8 ? "heart.fill" : "heart")
                .foregroundColor(track.rating >= 8 ? .accentColor : .secondary.opacity(0.45))
        case .plays:
            Text(track.playCount > 0 ? "\(track.playCount)" : "")
                .monospacedDigit()
        case .dateAdded:
            Text(track.dateAdded.map(Self.dateAddedFormatter.string(from:)) ?? "")
                .lineLimit(1)
        case .downloaded:
            if track.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
    }

    private func width(for column: SongsTableColumn) -> CGFloat {
        switch column {
        case .title:
            return 280
        case .time:
            return 72
        case .artist:
            return 190
        case .album:
            return 230
        case .genre:
            return 150
        case .favorite:
            return 44
        case .plays:
            return 58
        case .dateAdded:
            return 150
        case .downloaded:
            return 92
        }
    }

    private func songsTableContentWidth(for availableWidth: CGFloat) -> CGFloat {
        let columns = settingsManager.songsTableColumns
        let columnWidth = columns.reduce(CGFloat.zero) { partial, column in
            partial + width(for: column)
        }
        let spacing = CGFloat(max(columns.count - 1, 0)) * songsTableColumnSpacing
        let minimumWidth = columnWidth + spacing + (songsTableHorizontalPadding * 2)
        return max(availableWidth, minimumWidth)
    }

    private func alignment(for column: SongsTableColumn) -> Alignment {
        switch column {
        case .time, .plays:
            return .trailing
        case .favorite, .downloaded:
            return .center
        default:
            return .leading
        }
    }

    private func sortOption(for column: SongsTableColumn) -> TrackSortOption? {
        switch column {
        case .title:
            return .title
        case .time:
            return .duration
        case .artist:
            return .artist
        case .album:
            return .album
        case .favorite:
            return .rating
        case .plays:
            return .playCount
        case .dateAdded:
            return .dateAdded
        case .genre, .downloaded:
            return nil
        }
    }

    private func toggleSongsTableSort(_ option: TrackSortOption) {
        if libraryVM.trackSortOption == option {
            libraryVM.tracksFilterOptions.sortDirection =
                libraryVM.tracksFilterOptions.sortDirection == .ascending ? .descending : .ascending
        } else {
            libraryVM.trackSortOption = option
            libraryVM.tracksFilterOptions.sortDirection = option.defaultDirection
        }
    }

    private var songsTableColumnMenu: some View {
        Menu {
            ForEach(SongsTableColumn.allCases) { column in
                Toggle(isOn: Binding(
                    get: { isSongsTableColumnVisible(column) },
                    set: { settingsManager.setSongsTableColumn(column, isVisible: $0) }
                )) {
                    Text(column.title)
                }
            }

            Divider()

            Button("Reset Columns") {
                settingsManager.resetSongsTableColumnsToDefaults()
            }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .disabled(!canShowSongsTable)
    }

    private func isSongsTableColumnVisible(_ column: SongsTableColumn) -> Bool {
        settingsManager.songsTableColumns.contains(column)
    }

    private static let dateAddedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
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
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount) * TrackListLayoutMetrics.defaultRowHeight

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
                        navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                    }
                },
                onGoToArtist: { track in
                    if let artistId = track.artistRatingKey {
                        navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
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
                            navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
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
                .hideListRowSeparator()
                .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
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
            bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
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
                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
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
                            navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
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
                .hideListRowSeparator()
                .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
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
