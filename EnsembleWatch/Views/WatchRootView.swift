import EnsembleDomain
import EnsemblePlex
import EnsembleWatchCore
import Foundation
import SwiftUI
import WatchKit
#if canImport(UIKit)
import CoreGraphics
import UIKit
#endif

struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var experience = WatchExperienceModel()
    @StateObject private var remoteSession = WatchSessionModel()
    @State private var navigationPath = NavigationPath()
    @State private var showsNowPlaying = false
    @State private var selectedPin: EnsembleMediaSummary?
    @State private var hasHandledRemotePresentationForActivePhase = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationDestination(isPresented: showsPinDetail) {
                    selectedPinDestination
                }
                .navigationDestination(for: WatchMediaActionDestination.self) { destination in
                    WatchMediaDetailView(item: destination.mediaSummary)
                }
        }
        .tint(accentColor)
        .sheet(isPresented: $showsNowPlaying) {
            NavigationStack {
                WatchNowPlayingView()
            }
        }
        .confirmationDialog(
            "Replace Queue?",
            isPresented: queueReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Queue", role: .destructive) {
                experience.confirmQueueReplacement()
                remoteSession.confirmQueueReplacement()
            }
            Button("Cancel", role: .cancel) {
                experience.cancelQueueReplacement()
                remoteSession.cancelQueueReplacement()
            }
        } message: {
            Text("This replaces your current queue.")
        }
        .environmentObject(experience)
        .environmentObject(experience.playback)
        .environmentObject(remoteSession)
        .environment(\.watchNavigateToMedia) { destination in
            navigationPath.append(destination)
        }
        .environment(\.watchOpenNowPlaying) {
            selectNowPlayingSource()
            showsNowPlaying = true
        }
        .onAppear {
            experience.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                hasHandledRemotePresentationForActivePhase = false
            case .background:
                experience.persistPlaybackQueue()
                hasHandledRemotePresentationForActivePhase = false
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ensembleWatchRemoteNowPlayingActivity)) { _ in
            presentRemoteNowPlayingFromSystem()
        }
        .onReceive(experience.$playbackTarget) { target in
            if target == .local {
                remoteSession.setSystemNowPlayingProxyEnabled(false)
                experience.playback.setSystemRemoteCommandsEnabled(true)
            } else {
                experience.playback.setSystemRemoteCommandsEnabled(false)
                remoteSession.setSystemNowPlayingProxyEnabled(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            experience.cloudPreferencesDidChange()
        }
    }

    private func presentRemoteNowPlayingFromSystem() {
        guard scenePhase == .active,
              !hasHandledRemotePresentationForActivePhase else { return }

        hasHandledRemotePresentationForActivePhase = true
        experience.playbackTarget = .remote
        remoteSession.setSystemNowPlayingProxyEnabled(true)
        showsNowPlaying = true
    }

    private func selectNowPlayingSource() {
        if experience.playback.currentTrack == nil,
           remoteSession.snapshot?.currentTrack != nil {
            experience.playbackTarget = .remote
            remoteSession.setSystemNowPlayingProxyEnabled(true)
        }
    }

    private var rootContent: some View {
        Group {
            switch experience.bootstrapState {
            case .idle, .loading:
                loadingView
            case .needsLink:
                linkView
            case .ready:
                homeView
            case .failed:
                errorView
            }
        }
        .navigationTitle("Home")
        .watchNowPlayingToolbar()
    }

    private var accentColor: Color {
        WatchAccentColor.color(for: experience.accentColorName)
    }

    private var queueReplacementConfirmation: Binding<Bool> {
        Binding(
            get: {
                experience.pendingQueueReplacement != nil
                    || remoteSession.pendingQueueReplacement != nil
            },
            set: { isPresented in
                guard !isPresented else { return }
                experience.cancelQueueReplacement()
                remoteSession.cancelQueueReplacement()
            }
        )
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(experience.statusMessage)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var linkView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                if let link = experience.linkState {
                    Text(link.code)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("Plex Link code \(link.code)")

                    Text("plex.tv/link")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Sign in with Plex Link.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                Button {
                    experience.startLinkFlow()
                } label: {
                    Label("Get Code", systemImage: "key")
                }
                .buttonStyle(.borderedProminent)

                Text(experience.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }

    private var errorView: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.orange)

                Text(experience.statusMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                Button {
                    experience.refresh()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var homeView: some View {
        List {
            if experience.isCatalogSyncing {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Syncing Libraries")
                            Text(experience.statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let snapshot = experience.catalogSnapshot, !snapshot.pins.isEmpty {
                Section("Pins") {
                    LazyVGrid(columns: WatchPinsGrid.columns, spacing: WatchPinsGrid.spacing) {
                        ForEach(snapshot.pins) { item in
                            WatchHomePinCell(item: item) {
                                selectedPin = item
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section("Menu") {
                ForEach([
                    EnsembleLibraryCategory.songs,
                    .artists,
                    .albums,
                    .genres,
                    .playlists,
                    .favorites,
                    .hidden
                ]) { category in
                    NavigationLink(destination: WatchCategoryView(category: category)) {
                        Label(category.title, systemImage: category.systemImage)
                    }
                }
            }

            if let recentlyAdded = experience.catalogSnapshot?.recentlyAdded
                .filter({ $0.kind == .album })
                .prefix(6), !recentlyAdded.isEmpty {
                Section("Recently Added") {
                    LazyVGrid(columns: WatchRecentGrid.columns, spacing: WatchRecentGrid.spacing) {
                        ForEach(Array(recentlyAdded), id: \.watchListID) { item in
                            NavigationLink(destination: WatchMediaDetailView(item: item)) {
                                WatchRecentAlbumCell(item: item)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Button {
                    experience.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                NavigationLink(destination: WatchSourceSettingsView()) {
                    Label("Settings", systemImage: "gearshape")
                }
            } footer: {
                Text(experience.statusMessage)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
        }
        .refreshable {
            experience.refresh()
        }
    }

    private var showsPinDetail: Binding<Bool> {
        Binding(
            get: { selectedPin != nil },
            set: { if !$0 { selectedPin = nil } }
        )
    }

    @ViewBuilder
    private var selectedPinDestination: some View {
        if let selectedPin {
            if let group = experience.playlistGroup(containing: selectedPin) {
                WatchTrackCollectionDetailView(title: group.title, source: .playlistGroup(group))
            } else {
                WatchMediaDetailView(item: selectedPin)
            }
        }
    }
}

private struct WatchHomePinCell: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            WatchPinArtworkTile(item: item)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .contextMenu {
            Button(role: .destructive) {
                experience.togglePin(item)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        }
    }
}

private struct WatchSourceSettingsView: View {
    @EnvironmentObject private var experience: WatchExperienceModel

    var body: some View {
        List {
            Section("Music Sources") {
                if experience.sourceAccounts.isEmpty {
                    Text("No sources found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(experience.sourceAccounts) { account in
                        NavigationLink {
                            WatchSourceAccountView(account: account)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Plex")
                                    Text(account.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "server.rack")
                            }
                        }
                    }
                }

                NavigationLink(destination: WatchAddSourceView()) {
                    Label("Add Source", systemImage: "plus.circle")
                }
            }

            Section {
                NavigationLink(destination: WatchCloudSettingsView()) {
                    Label("iCloud Sync", systemImage: "icloud")
                }
                NavigationLink(destination: WatchPersonalizationView()) {
                    Label("Personalization", systemImage: "paintpalette")
                }
            }

            Section {
                Text(experience.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Settings")
        .watchNowPlayingToolbar()
    }
}

private struct WatchSourceAccountView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let account: WatchSourceAccountSection

    var body: some View {
        List {
            ForEach(account.servers) { server in
                Section(server.title) {
                    ForEach(server.libraries) { library in
                        Toggle(isOn: Binding(
                            get: { library.isEnabled },
                            set: { _ in experience.toggleLibrarySelection(library) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.title)
                                Text(library.isEnabled ? "Synced" : "Not synced")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    experience.syncSelectedLibraries()
                } label: {
                    Label("Sync Libraries", systemImage: "arrow.clockwise")
                }
                .disabled(experience.libraries.isEmpty || experience.isCatalogSyncing)
            } footer: {
                Text(experience.isCatalogSyncing ? experience.statusMessage : account.title)
            }
        }
        .navigationTitle("Plex")
        .watchNowPlayingToolbar()
    }
}

private struct WatchAddSourceView: View {
    @EnvironmentObject private var experience: WatchExperienceModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "link.circle")
                    .font(.title2)
                if let link = experience.linkState {
                    Text(link.code)
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Text("plex.tv/link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Get Code") { experience.startLinkFlow() }
                }
                Text(experience.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Add Source")
        .task { experience.startLinkFlow() }
    }
}

private struct WatchCloudSettingsView: View {
    @EnvironmentObject private var experience: WatchExperienceModel

    var body: some View {
        List {
            Section {
                Label("Pins", systemImage: "pin")
                Label("Library Selections", systemImage: "books.vertical")
            } footer: {
                Text("Changes sync with Ensemble on your other devices through iCloud.")
            }
            Button {
                experience.cloudPreferencesDidChange()
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
        }
        .navigationTitle("iCloud Sync")
        .watchNowPlayingToolbar()
    }
}

private struct WatchPersonalizationView: View {
    @EnvironmentObject private var experience: WatchExperienceModel

    var body: some View {
        List {
            Picker("Accent Color", selection: Binding(
                get: { experience.accentColorName },
                set: { experience.setAccentColorName($0) }
            )) {
                ForEach(WatchAccentColor.names, id: \.self) { name in
                    Text(name.capitalized).tag(name)
                }
            }
        }
        .navigationTitle("Personalization")
        .watchNowPlayingToolbar()
    }
}

private struct WatchCategoryView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let category: EnsembleLibraryCategory
    @State private var searchText = ""
    @State private var sortDirection = SortDirection.ascending

    var body: some View {
        Group {
            if category == .playlists {
                playlistList
            } else if category == .genres {
                genreList
            } else if category == .songs || category == .favorites {
                songList
            } else if category == .recentlyAdded {
                List(items, id: \.watchListID) { item in
                    row(for: item)
                }
            } else {
                mediaList
            }
        }
        .navigationTitle(category.title)
        .searchable(text: $searchText, prompt: "Filter \(category.title)")
        .watchNowPlayingToolbar()
    }

    @ViewBuilder
    private var mediaList: some View {
        if #available(watchOS 26.0, *) {
            List {
                viewOptions
                if sections.isEmpty { emptyCategoryRow }
                ForEach(sections, id: \.letter) { section in
                    Section(section.letter) {
                        rows(for: section.items)
                    }
                    .sectionIndexLabel(section.letter)
                }
            }
            .listSectionIndexVisibility(.visible)
        } else {
            List {
                viewOptions
                if sections.isEmpty { emptyCategoryRow }
                ForEach(sections, id: \.letter) { section in
                    Section(section.letter) { rows(for: section.items) }
                }
            }
        }
    }

    private var genreList: some View {
        List {
            viewOptions
            if sortedGenres.isEmpty { emptyCategoryRow }
            ForEach(sortedGenres) { genre in
                NavigationLink(destination: WatchTrackCollectionDetailView(
                    title: genre.title,
                    source: .genre(genre)
                )) {
                    Text(genre.title)
                        .font(.headline)
                }
            }
        }
    }

    private var songList: some View {
        List {
            viewOptions
            if songTracks.isEmpty {
                emptyCategoryRow
            } else {
                ForEach(songSections, id: \.letter) { section in
                    Section(section.letter) {
                        ForEach(section.tracks, id: \.watchListID) { track in
                            Button {
                                if experience.playbackTarget == .remote {
                                    // Remote mode is deliberately queue-only: the iPhone owns playback.
                                    remoteSession.requestQueueReplacement(
                                        .play,
                                        tracks: [track.companionPayload]
                                    )
                                } else {
                                    experience.play(track, in: songTracks)
                                }
                                openNowPlaying()
                            } label: {
                                WatchTrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .watchMediaSwipeActions(.track(track, queue: songTracks))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        if #available(watchOS 26.0, *) {
            List {
                viewOptions
                if playlistSections.isEmpty { emptyCategoryRow }
                ForEach(playlistSections, id: \.letter) { section in
                    Section(section.letter) {
                        playlistRows(for: section.groups)
                    }
                    .sectionIndexLabel(section.letter)
                }
            }
            .listSectionIndexVisibility(.visible)
        } else {
            List {
                viewOptions
                if playlistSections.isEmpty { emptyCategoryRow }
                ForEach(playlistSections, id: \.letter) { section in
                    Section(section.letter) {
                        playlistRows(for: section.groups)
                    }
                }
            }
        }
    }

    private func row(for item: EnsembleMediaSummary) -> some View {
        NavigationLink(destination: WatchMediaDetailView(item: item)) {
            WatchMediaRow(item: item)
        }
        .watchMediaSwipeActions(.media(item))
    }

    private func playlistRow(for group: WatchPlaylistGroup) -> some View {
        NavigationLink(destination: WatchTrackCollectionDetailView(title: group.title, source: .playlistGroup(group))) {
            WatchMediaRow(item: group.primaryPlaylist, subtitle: group.subtitle)
        }
        .watchMediaSwipeActions(.playlistGroup(group))
    }

    @ViewBuilder
    private func rows(for items: [EnsembleMediaSummary]) -> some View {
        ForEach(items, id: \.watchListID) { item in
            row(for: item)
        }
    }

    @ViewBuilder
    private func playlistRows(for groups: [WatchPlaylistGroup]) -> some View {
        ForEach(groups) { group in
            playlistRow(for: group)
        }
    }

    private var sections: [(letter: String, items: [EnsembleMediaSummary])] {
        Dictionary(grouping: sortedItems) { $0.title.ensembleIndexingLetter }
            .map { (letter: $0.key, items: $0.value) }
            .sorted { sortDirection == .ascending ? $0.letter < $1.letter : $0.letter > $1.letter }
    }

    private var playlistSections: [(letter: String, groups: [WatchPlaylistGroup])] {
        Dictionary(grouping: sortedPlaylistGroups) { $0.title.ensembleIndexingLetter }
            .map { (letter: $0.key, groups: $0.value) }
            .sorted { sortDirection == .ascending ? $0.letter < $1.letter : $0.letter > $1.letter }
    }

    private var sortedGenres: [EnsembleGenreSummary] {
        experience.libraryGenres
            .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
            .sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame
                ? (sortDirection == .ascending ? $0.id < $1.id : $0.id > $1.id)
                : comparison == (sortDirection == .ascending ? .orderedAscending : .orderedDescending)
        }
    }

    @ViewBuilder
    private var emptyCategoryRow: some View {
        if experience.isCatalogSyncing { ProgressView() }
        Text(experience.isCatalogSyncing ? "Syncing Libraries" : "No \(category.title)")
            .foregroundStyle(.secondary)
    }

    private var songTracks: [EnsembleTrack] {
        switch category {
        case .favorites:
            return experience.libraryTracks.filter { $0.isFavorite == true }.filter(matchesSearch)
        case .songs:
            return experience.libraryTracks.filter(matchesSearch)
        default:
            return []
        }
    }

    private var songSections: [(letter: String, tracks: [EnsembleTrack])] {
        Dictionary(grouping: songTracks) { $0.title.ensembleIndexingLetter }
            .map { (letter: $0.key, tracks: $0.value.sorted {
                $0.title.localizedStandardCompare($1.title) == (sortDirection == .ascending ? .orderedAscending : .orderedDescending)
            }) }
            .sorted { sortDirection == .ascending ? $0.letter < $1.letter : $0.letter > $1.letter }
    }

    private var sortedItems: [EnsembleMediaSummary] {
        items.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }.sorted { lhs, rhs in
            let comparison = lhs.title.ensembleSortingKey.localizedStandardCompare(rhs.title.ensembleSortingKey)
            if comparison == .orderedSame {
                return sortDirection == .ascending ? lhs.watchListID < rhs.watchListID : lhs.watchListID > rhs.watchListID
            }
            return comparison == (sortDirection == .ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private var sortedPlaylistGroups: [WatchPlaylistGroup] {
        experience.playlistGroups
            .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
            .sorted { lhs, rhs in
            let comparison = lhs.title.ensembleSortingKey.localizedStandardCompare(rhs.title.ensembleSortingKey)
            return comparison == .orderedSame
                ? (sortDirection == .ascending ? lhs.id < rhs.id : lhs.id > rhs.id)
                : comparison == (sortDirection == .ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private var viewOptions: some View {
        Section("View") {
            Picker("Order", selection: $sortDirection) {
                ForEach(SortDirection.allCases, id: \.self) { direction in
                    Text(direction.label).tag(direction)
                }
            }
        }
    }

    private func matchesSearch(_ track: EnsembleTrack) -> Bool {
        searchText.isEmpty
            || track.title.localizedCaseInsensitiveContains(searchText)
            || track.artistName?.localizedCaseInsensitiveContains(searchText) == true
    }

    private var items: [EnsembleMediaSummary] {
        guard let snapshot = experience.catalogSnapshot else { return [] }
        switch category {
        case .songs, .favorites:
            return snapshot.tracks.map(\.summary)
        case .genres:
            return []
        case .albums:
            return snapshot.albums
        case .artists:
            return snapshot.artists
        case .playlists:
            return snapshot.playlists
        case .hidden:
            return experience.hiddenItems
        case .recentlyAdded:
            return snapshot.recentlyAdded
        }
    }
}

private extension EnsembleMediaSummary {
    var watchListID: String {
        "\(sourceKey):\(kind.rawValue):\(id)"
    }
}

private struct WatchMediaDetailView: View {
    let item: EnsembleMediaSummary

    @ViewBuilder
    var body: some View {
        if item.kind == .artist {
            WatchArtistAlbumsView(item: item)
        } else {
            WatchTrackCollectionDetailView(
                title: item.title,
                source: .media(item)
            )
        }
    }
}

private struct WatchArtistAlbumsView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    @State private var searchText = ""
    @State private var sortDirection = SortDirection.ascending

    var body: some View {
        TabView {
            VStack(spacing: 4) {
                WatchCollectionHero(
                    title: item.title,
                    artworkItem: item,
                    fallbackArtworkTrack: experience.detailTracks.first
                )
                WatchCollectionPlaybackControls(
                    title: item.title,
                    target: .media(item),
                    tracks: experience.detailTracks
                )
            }

            List {
                Section("View") {
                    Picker("Order", selection: $sortDirection) {
                        ForEach(SortDirection.allCases, id: \.self) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                }
                if artistAlbums.isEmpty {
                    Text(experience.detailStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(artistAlbums) { album in
                        NavigationLink(destination: WatchTrackCollectionDetailView(
                            title: album.title,
                            source: .artistAlbum(album.id)
                        )) {
                            if let summary = album.mediaSummary {
                                WatchMediaRow(item: summary)
                            } else {
                                Text(album.title)
                            }
                        }
                        .watchMediaSwipeActions(.artistAlbum(album))
                    }
                }
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("Artist")
        .searchable(text: $searchText, prompt: "Filter Albums")
        .watchNowPlayingToolbar()
        .onAppear {
            experience.tracks(for: item)
        }
    }

    private var artistAlbums: [WatchArtistAlbumSummary] {
        WatchArtistAlbumSummary.albums(from: experience.detailTracks)
            .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
            .sorted {
                $0.title.localizedStandardCompare($1.title)
                    == (sortDirection == .ascending ? .orderedAscending : .orderedDescending)
            }
    }
}

private struct WatchTrackCollectionDetailView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let title: String
    let source: WatchTrackCollectionSource
    @State private var sortOrder = WatchTrackSortOrder.collection
    @State private var favoritesOnly = false

    var body: some View {
        TabView {
            VStack(spacing: 4) {
                collectionHero
                if let headerActionTarget {
                    WatchCollectionPlaybackControls(
                        title: title,
                        target: headerActionTarget,
                        tracks: tracks
                    )
                }
            }
            trackList
        }
        .tabViewStyle(.verticalPage)
        .watchNowPlayingToolbar()
        .onAppear {
            switch source {
            case .media(let item):
                experience.tracks(for: item)
            case .playlistGroup(let group):
                experience.tracks(for: group)
            case .genre(let genre):
                experience.tracks(for: genre)
            case .artistAlbum:
                break
            }
        }
    }

    private var collectionHero: some View {
        WatchCollectionHero(
            title: title,
            artworkItem: artworkItem,
            fallbackArtworkTrack: tracks.first
        )
    }

    private var trackList: some View {
        List {
            Section("View") {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(WatchTrackSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Toggle("Favorites Only", isOn: $favoritesOnly)
            }
            trackSections
        }
    }

    @ViewBuilder
    private var trackSections: some View {
        if tracks.isEmpty {
            Section {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if isAlbum {
            ForEach(albumDiscs, id: \.number) { disc in
                Section {
                    ForEach(disc.tracks, id: \.watchListID) { track in
                        trackButton(track) {
                            WatchAlbumTrackRow(track: track)
                        }
                    }
                } header: {
                    if albumDiscs.count > 1 {
                        Text("Disc \(disc.number)")
                    }
                }
            }
        } else {
            Section {
                ForEach(tracks, id: \.watchListID) { track in
                    trackButton(track) {
                        WatchTrackRow(track: track)
                    }
                }
            }
        }
    }

    private func trackButton<Row: View>(
        _ track: EnsembleTrack,
        @ViewBuilder row: () -> Row
    ) -> some View {
        Button {
            if experience.playbackTarget == .remote {
                remoteSession.requestQueueReplacement(
                    .play,
                    tracks: [track.companionPayload]
                )
            } else {
                experience.play(track, in: tracks)
            }
            openNowPlaying()
        } label: {
            row()
        }
        .buttonStyle(.plain)
        .watchMediaSwipeActions(.track(track, queue: tracks))
    }

    private var albumDiscs: [(number: Int, tracks: [EnsembleTrack])] {
        Dictionary(grouping: tracks) { max(1, $0.discNumber ?? 1) }
            .map { (number: $0.key, tracks: $0.value) }
            .sorted { $0.number < $1.number }
    }

    private var isAlbum: Bool {
        switch source {
        case .media(let item):
            return item.kind == .album
        case .playlistGroup:
            return false
        case .genre:
            return false
        case .artistAlbum:
            return true
        }
    }

    private var sourceTracks: [EnsembleTrack] {
        switch source {
        case .media, .playlistGroup, .genre:
            return experience.detailTracks
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks)?.tracks ?? []
        }
    }

    private var tracks: [EnsembleTrack] {
        let filtered = favoritesOnly ? sourceTracks.filter { $0.isFavorite == true } : sourceTracks
        switch sortOrder {
        case .collection:
            return filtered
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return filtered.sorted {
                ($0.artistName ?? "").localizedStandardCompare($1.artistName ?? "") == .orderedAscending
            }
        }
    }

    private var emptyMessage: String {
        switch source {
        case .media, .playlistGroup, .genre:
            return experience.detailStatusMessage
        case .artistAlbum:
            return "No tracks found."
        }
    }

    private var headerActionTarget: WatchMediaActionTarget? {
        switch source {
        case .media(let item):
            return .media(item)
        case .playlistGroup(let group):
            return .playlistGroup(group)
        case .genre(let genre):
            return .genre(genre)
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks).map {
                .artistAlbum($0)
            }
        }
    }

    private var artworkItem: EnsembleMediaSummary? {
        switch source {
        case .media(let item):
            return item
        case .playlistGroup(let group):
            return group.primaryPlaylist
        case .genre:
            return nil
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks)?.mediaSummary
        }
    }
}

private enum WatchTrackSortOrder: String, CaseIterable, Identifiable {
    case collection
    case title
    case artist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collection: return "Collection Order"
        case .title: return "Title"
        case .artist: return "Artist"
        }
    }
}

private enum WatchTrackCollectionSource {
    case media(EnsembleMediaSummary)
    case playlistGroup(WatchPlaylistGroup)
    case genre(EnsembleGenreSummary)
    case artistAlbum(String)
}

private enum WatchMediaActionTarget: Identifiable {
    case media(EnsembleMediaSummary)
    case playlistGroup(WatchPlaylistGroup)
    case genre(EnsembleGenreSummary)
    case artistAlbum(WatchArtistAlbumSummary)
    case track(EnsembleTrack, queue: [EnsembleTrack])

    var id: String {
        switch self {
        case .media(let item):
            return "media:\(item.id)"
        case .playlistGroup(let group):
            return "playlistGroup:\(group.id)"
        case .genre(let genre):
            return "genre:\(genre.sourceKey):\(genre.id)"
        case .artistAlbum(let album):
            return "artistAlbum:\(album.id)"
        case .track(let track, _):
            return "track:\(track.id)"
        }
    }

    var title: String {
        switch self {
        case .media(let item):
            return item.title
        case .playlistGroup(let group):
            return group.title
        case .genre(let genre):
            return genre.title
        case .artistAlbum(let album):
            return album.title
        case .track(let track, _):
            return track.title
        }
    }

    var sourceKeys: [String] {
        switch self {
        case .media(let item):
            return [item.sourceKey]
        case .playlistGroup(let group):
            return group.playlists.map(\.sourceKey)
        case .genre(let genre):
            return [genre.sourceKey]
        case .artistAlbum(let album):
            return album.tracks.map(\.sourceKey)
        case .track(let track, _):
            return [track.sourceKey]
        }
    }

    var albumDestination: WatchMediaActionDestination? {
        guard case .track(let track, _) = self,
              let albumID = track.albumID, !albumID.isEmpty,
              let albumTitle = track.albumTitle, !albumTitle.isEmpty else {
            return nil
        }

        return WatchMediaActionDestination(
            item: EnsembleMediaSummary(
                id: albumID,
                kind: .album,
                title: albumTitle,
                subtitle: track.artistName,
                artistID: track.artistID,
                artworkPath: track.artworkPath,
                sourceKey: track.sourceKey
            )
        )
    }

    var artistDestination: WatchMediaActionDestination? {
        switch self {
        case .media(let item):
            guard let artistID = item.artistID,
                  let artistTitle = item.subtitle,
                  !artistID.isEmpty,
                  !artistTitle.isEmpty else {
                return nil
            }
            return WatchMediaActionDestination(
                item: EnsembleMediaSummary(
                    id: artistID,
                    kind: .artist,
                    title: artistTitle,
                    artworkPath: item.artworkPath,
                    sourceKey: item.sourceKey
                )
            )
        case .track(let track, _):
            guard let artistID = track.artistID,
                  let artistTitle = track.artistName,
                  !artistID.isEmpty,
                  !artistTitle.isEmpty else {
                return nil
            }
            return WatchMediaActionDestination(
                item: EnsembleMediaSummary(
                    id: artistID,
                    kind: .artist,
                    title: artistTitle,
                    artworkPath: track.artworkPath,
                    sourceKey: track.sourceKey
                )
            )
        case .artistAlbum(let album):
            guard let track = album.representativeTrack,
                  let artistID = track.artistID,
                  let artistTitle = track.artistName,
                  !artistID.isEmpty,
                  !artistTitle.isEmpty else {
                return nil
            }
            return WatchMediaActionDestination(
                item: EnsembleMediaSummary(
                    id: artistID,
                    kind: .artist,
                    title: artistTitle,
                    artworkPath: track.artworkPath,
                    sourceKey: track.sourceKey
                )
            )
        case .playlistGroup, .genre:
            return nil
        }
    }

    var deletionItem: EnsembleMediaSummary? {
        switch self {
        case .media(let item):
            return item.kind == .playlist && item.isSmart == true ? nil : item
        case .playlistGroup(let group):
            guard !group.isMerged, !group.isSmart else { return nil }
            return group.primaryPlaylist
        case .artistAlbum(let album):
            return album.mediaSummary
        case .track(let track, _):
            return track.summary
        case .genre:
            return nil
        }
    }

    @MainActor
    func canPin(in experience: WatchExperienceModel) -> Bool {
        switch self {
        case .media(let item):
            return experience.canPin(item)
        case .playlistGroup(let group):
            return experience.canPin(group)
        case .genre:
            return false
        case .artistAlbum(let album):
            return album.mediaSummary.map(experience.canPin) ?? false
        case .track:
            return false
        }
    }

    @MainActor
    func isPinned(in experience: WatchExperienceModel) -> Bool {
        switch self {
        case .media(let item):
            return experience.isPinned(item)
        case .playlistGroup(let group):
            return experience.isPinned(group)
        case .genre:
            return false
        case .artistAlbum(let album):
            return album.mediaSummary.map(experience.isPinned) ?? false
        case .track:
            return false
        }
    }

    @MainActor
    func togglePin(in experience: WatchExperienceModel) {
        switch self {
        case .media(let item):
            experience.togglePin(item)
        case .playlistGroup(let group):
            experience.togglePin(group)
        case .genre:
            break
        case .artistAlbum(let album):
            if let item = album.mediaSummary { experience.togglePin(item) }
        case .track:
            break
        }
    }

    var supportsShuffle: Bool {
        switch self {
        case .media(let item):
            return item.kind != .track
        case .playlistGroup:
            return true
        case .genre:
            return true
        case .artistAlbum:
            return true
        case .track:
            return false
        }
    }

    var supportsRadio: Bool {
        switch self {
        case .media(let item):
            return item.kind == .album || item.kind == .artist
        case .artistAlbum:
            return true
        case .genre:
            return true
        case .playlistGroup, .track:
            return false
        }
    }

    var trackForFavorite: EnsembleTrack? {
        if case .track(let track, _) = self { return track }
        return nil
    }

    var shareURL: URL? {
        switch self {
        case .media(let item):
            return Self.makeShareURL(
                kind: item.kind,
                title: item.title,
                artistName: item.subtitle,
                isSmartPlaylist: item.isSmart
            )
        case .playlistGroup(let group):
            let item = group.primaryPlaylist
            return Self.makeShareURL(
                kind: .playlist,
                title: item.title,
                isSmartPlaylist: item.isSmart
            )
        case .artistAlbum(let album):
            return album.mediaSummary.flatMap {
                Self.makeShareURL(
                    kind: .album,
                    title: $0.title,
                    artistName: $0.subtitle
                )
            }
        case .track(let track, _):
            return Self.makeShareURL(
                kind: .track,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                duration: track.duration,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber
            )
        case .genre:
            return nil
        }
    }

    private static func makeShareURL(
        kind: EnsembleMediaKind,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        isSmartPlaylist: Bool? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ensemble.videogorl.me"
        components.path = "/media/v1/\(kind == .track ? "song" : kind.rawValue)/\(title)"
        components.queryItems = [
            artistName.map { URLQueryItem(name: "artist", value: $0) },
            albumTitle.map { URLQueryItem(name: "album", value: $0) },
            duration.map { URLQueryItem(name: "duration", value: String(Int($0.rounded()))) },
            trackNumber.map { URLQueryItem(name: "track", value: String($0)) },
            discNumber.map { URLQueryItem(name: "disc", value: String($0)) },
            isSmartPlaylist.map { URLQueryItem(name: "smart", value: String($0)) }
        ].compactMap { $0 }
        return components.url
    }

    @MainActor
    func loadTracks(in experience: WatchExperienceModel) async -> [EnsembleTrack] {
        switch self {
        case .media(let item):
            return await experience.loadTracks(for: item)
        case .playlistGroup(let group):
            return await experience.loadTracks(for: group)
        case .genre(let genre):
            return await experience.loadTracks(for: genre)
        case .artistAlbum(let album):
            return album.tracks
        case .track(let track, _):
            return [track]
        }
    }

    @MainActor
    func play(in experience: WatchExperienceModel, shuffled: Bool = false) {
        switch self {
        case .media(let item):
            experience.play(item, shuffled: shuffled)
        case .playlistGroup(let group):
            experience.play(group, shuffled: shuffled)
        case .artistAlbum(let album):
            experience.play(album.tracks, shuffled: shuffled)
        case .genre:
            break
        case .track(let track, let queue):
            experience.play(track, in: queue)
        }
    }

    @MainActor
    func play(_ tracks: [EnsembleTrack], in experience: WatchExperienceModel, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        if case .track(let track, _) = self, !shuffled {
            experience.play(track, in: tracks)
        } else {
            experience.play(tracks, shuffled: shuffled)
        }
    }

    @MainActor
    func playRadio(in experience: WatchExperienceModel) async {
        let tracks = await loadTracks(in: experience)
        experience.playRadio(tracks)
    }
}

private struct WatchMediaSwipeActionsModifier: ViewModifier {
    let target: WatchMediaActionTarget
    @State private var showsActions = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    showsActions = true
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .tint(.gray)
            }
            .watchMediaActions(target, isPresented: $showsActions)
    }
}

private extension View {
    func watchMediaSwipeActions(_ target: WatchMediaActionTarget) -> some View {
        modifier(WatchMediaSwipeActionsModifier(target: target))
    }

    func watchMediaActions(
        _ target: WatchMediaActionTarget,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(WatchMediaActionsModifier(target: target, isPresented: isPresented))
    }

}

private struct WatchMediaActionsModifier: ViewModifier {
    @EnvironmentObject private var experience: WatchExperienceModel
    let target: WatchMediaActionTarget
    @Binding var isPresented: Bool
    @State private var showsDeleteConfirmation = false
    @State private var playlistTracks: [EnsembleTrack] = []
    @State private var showsPlaylistPicker = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(target.title, isPresented: $isPresented, titleVisibility: .visible) {
                WatchMediaActionButtons(target: target) { tracks in
                    playlistTracks = tracks
                    showsPlaylistPicker = true
                } requestDelete: {
                    showsDeleteConfirmation = true
                }
            }
            .sheet(isPresented: $showsPlaylistPicker) {
                NavigationStack {
                    if experience.playbackTarget == .remote {
                        WatchRemotePlaylistPicker(tracks: playlistTracks)
                    } else {
                        WatchPlaylistPicker(tracks: playlistTracks)
                    }
                }
            }
            .alert("Delete \(target.title)?", isPresented: $showsDeleteConfirmation) {
                if let item = target.deletionItem {
                    Button("Delete", role: .destructive) {
                        Task { _ = await experience.delete(item) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes it from your Plex library.")
            }
    }
}

private struct WatchMediaActionButtons: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.watchNavigateToMedia) private var navigateToMedia
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let target: WatchMediaActionTarget
    let actions: [EnsembleMediaAction]
    let openPlaylistPicker: ([EnsembleTrack]) -> Void
    let requestDelete: () -> Void

    init(
        target: WatchMediaActionTarget,
        actions: [EnsembleMediaAction] = EnsembleMediaActionCatalog.ordered.map(\.action),
        openPlaylistPicker: @escaping ([EnsembleTrack]) -> Void,
        requestDelete: @escaping () -> Void
    ) {
        self.target = target
        self.actions = actions
        self.openPlaylistPicker = openPlaylistPicker
        self.requestDelete = requestDelete
    }

    var body: some View {
        ForEach(EnsembleMediaActionCatalog.ordered.filter { actions.contains($0.action) }, id: \.action.rawValue) { descriptor in
            actionView(descriptor)
                .disabled(!actionAvailability(for: descriptor.action).isAvailable)
                .accessibilityHint(actionAvailability(for: descriptor.action).reason ?? "")
        }
        .task {
            if experience.playbackTarget == .remote {
                remoteSession.send(.requestPlaylistTargets)
            } else {
                await experience.loadPlaylistTargets()
            }
        }
        if let unavailableReason {
            Button(unavailableReason) {}
                .disabled(true)
        }
    }

    @ViewBuilder
    private func actionView(_ descriptor: EnsembleMediaActionDescriptor) -> some View {
        switch descriptor.action {
        case .play:
            playbackButton(descriptor, kind: .play)
        case .shuffle:
            if target.supportsShuffle { playbackButton(descriptor, kind: .shuffle) }
        case .radio:
            if target.supportsRadio { playbackButton(descriptor, kind: .radio) }
        case .playNext:
            playbackButton(descriptor, kind: .playNext)
        case .playLast:
            playbackButton(descriptor, kind: .playLast)
        case .addToPlaylist:
            Button {
                Task {
                    let tracks = await target.loadTracks(in: experience)
                    if experience.playbackTarget == .remote {
                        remoteSession.send(.requestPlaylistTargets)
                    } else {
                        await experience.loadPlaylistTargets()
                    }
                    openPlaylistPicker(tracks)
                }
            } label: {
                Label(descriptor.title, systemImage: descriptor.systemImage)
            }
        case .addToRecentPlaylist:
            if experience.playbackTarget == .remote,
               let recent = remoteSession.playlistTargets
                .filter({ playlist in
                    target.sourceKeys.contains {
                        EnsembleSourceScope.isCompatible($0, playlist.sourceKey)
                    }
                })
                .max(by: { ($0.updatedAt ?? 0, $0.id) < ($1.updatedAt ?? 0, $1.id) }) {
                Button {
                    Task {
                        let tracks = await target.loadTracks(in: experience).filter {
                            EnsembleSourceScope.isCompatible($0.sourceKey, recent.sourceKey)
                        }
                        remoteSession.send(
                            .addItemsToPlaylist,
                            tracks: tracks.map(\.companionPayload),
                            targetID: recent.id,
                            targetSourceKey: recent.sourceKey
                        )
                    }
                } label: {
                    Label("Add to \(recent.title)", systemImage: descriptor.systemImage)
                }
            } else if let recent = experience.recentPlaylistTarget,
                      !recent.isSmart,
                      targetCanAddToPlaylist(target, with: recent) {
                Button {
                    Task {
                        let tracks = await target.loadTracks(in: experience)
                        let compatibleTracks = tracks.filter { isCompatible($0, with: recent) }
                        _ = await experience.addToPlaylist(compatibleTracks, target: recent)
                    }
                } label: {
                    Label("Add to \(recent.title)", systemImage: descriptor.systemImage)
                }
            }
        case .favorite:
            if let track = target.trackForFavorite {
                Button {
                    if experience.playbackTarget == .remote {
                        remoteSession.send(
                            .setItemFavorite,
                            tracks: [track.companionPayload],
                            booleanValue: track.isFavorite != true
                        )
                    } else {
                        experience.toggleFavorite(track)
                    }
                } label: {
                    Label(
                        track.isFavorite == true ? "Unfavorite" : descriptor.title,
                        systemImage: track.isFavorite == true ? "heart.slash" : descriptor.systemImage
                    )
                }
            }
        case .pin:
            if target.canPin(in: experience) {
                Button { target.togglePin(in: experience) } label: {
                    Label(
                        target.isPinned(in: experience) ? "Unpin" : descriptor.title,
                        systemImage: target.isPinned(in: experience) ? "pin.slash" : descriptor.systemImage
                    )
                }
            }
        case .goToAlbum:
            if let destination = target.albumDestination {
                Button { navigateToMedia(destination) } label: {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        case .goToArtist:
            if let destination = target.artistDestination {
                Button { navigateToMedia(destination) } label: {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        case .share:
            if let shareURL = target.shareURL {
                ShareLink(item: shareURL) {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        case .delete:
            if target.deletionItem != nil {
                Button(role: .destructive, action: requestDelete) {
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                }
            }
        }
    }

    private func playbackButton(
        _ descriptor: EnsembleMediaActionDescriptor,
        kind: WatchCompanionCommandKind
    ) -> some View {
        Button {
            Task {
                let tracks = await target.loadTracks(in: experience)
                if experience.playbackTarget == .remote {
                    if kind == .playNext || kind == .playLast {
                        remoteSession.send(kind, tracks: tracks.map(\.companionPayload))
                    } else {
                        remoteSession.requestQueueReplacement(kind, tracks: tracks.map(\.companionPayload))
                    }
                } else {
                    switch kind {
                    case .shuffle:
                        target.play(tracks, in: experience, shuffled: true)
                    case .radio:
                        experience.playRadio(tracks)
                    case .playNext:
                        experience.playNext(tracks)
                    case .playLast:
                        experience.playLast(tracks)
                    default:
                        target.play(tracks, in: experience)
                    }
                }
                if kind == .play || kind == .shuffle || kind == .radio {
                    openNowPlaying()
                }
            }
        } label: {
            Label(descriptor.title, systemImage: descriptor.systemImage)
        }
    }

    private func actionAvailability(for action: EnsembleMediaAction) -> MusicItemActionAvailability {
        guard experience.playbackTarget == .remote,
              [.play, .shuffle, .radio, .playNext, .playLast, .addToPlaylist,
               .addToRecentPlaylist, .favorite].contains(action) else {
            return .available
        }
        guard remoteSession.isReachable else {
            return .unavailable(reason: "Reconnect to iPhone")
        }
        return remoteSession.canControl(sourceKeys: target.sourceKeys)
            ? .available
            : .unavailable(reason: "Source isn’t synced to iPhone")
    }

    private var unavailableReason: String? {
        EnsembleMediaActionCatalog.ordered
            .filter { actions.contains($0.action) }
            .compactMap { actionAvailability(for: $0.action).reason }
            .first
    }

    private func targetCanAddToPlaylist(
        _ target: WatchMediaActionTarget,
        with playlist: EnsemblePlexPlaylistTarget
    ) -> Bool {
        target.sourceKeys.contains {
            $0 == playlist.sourceKey || $0.hasPrefix(playlist.sourceKey + ":")
        }
    }

    private func isCompatible(_ track: EnsembleTrack, with playlist: EnsemblePlexPlaylistTarget) -> Bool {
        track.sourceKey == playlist.sourceKey || track.sourceKey.hasPrefix(playlist.sourceKey + ":")
    }
}

private struct WatchPlaylistPicker: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @Environment(\.dismiss) private var dismiss
    let tracks: [EnsembleTrack]
    @State private var searchText = ""
    @State private var showsCreate = false

    private var compatibleTargets: [EnsemblePlexPlaylistTarget] {
        experience.playlistTargets.filter { target in
            !target.isSmart && tracks.contains { isCompatible($0, with: target) }
        }
        .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if let recent = experience.recentPlaylistTarget,
               !recent.isSmart,
               tracks.contains(where: { isCompatible($0, with: recent) }) {
                Section("Recent") {
                    Button {
                        add(to: recent)
                    } label: {
                        Label("Add to \(recent.title)", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Section("Playlists") {
                if compatibleTargets.isEmpty {
                    Text("No compatible playlists")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(compatibleTargets) { target in
                        Button {
                            add(to: target)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.title)
                                Text(sourceTitle(for: target))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showsCreate = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                .disabled(tracks.isEmpty)
            }
        }
        .navigationTitle("Add to Playlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
        .searchable(text: $searchText, prompt: "Search playlists")
        .sheet(isPresented: $showsCreate) {
            WatchNewPlaylistView(sourceKeys: newPlaylistSourceKeys) { title, sourceKey in
                let sourceTracks = tracks.filter {
                    EnsembleSourceScope.isCompatible($0.sourceKey, sourceKey)
                }
                return await experience.createPlaylist(
                    title: title,
                    tracks: sourceTracks,
                    sourceKey: sourceKey
                )
            }
        }
    }

    private func add(to target: EnsemblePlexPlaylistTarget) {
        let sourceTracks = tracks.filter { isCompatible($0, with: target) }
        Task {
            guard !sourceTracks.isEmpty else { return }
            if await experience.addToPlaylist(sourceTracks, target: target) != nil {
                dismiss()
            }
        }
    }

    private func isCompatible(_ track: EnsembleTrack, with target: EnsemblePlexPlaylistTarget) -> Bool {
        track.sourceKey == target.sourceKey || track.sourceKey.hasPrefix(target.sourceKey + ":")
    }

    private func sourceTitle(for target: EnsemblePlexPlaylistTarget) -> String {
        target.sourceKey.split(separator: ":").last.map(String.init) ?? target.sourceKey
    }

    private var newPlaylistSourceKeys: [String] {
        Array(Set(tracks.compactMap { EnsembleSourceScope(sourceKey: $0.sourceKey)?.serverSourceKey })).sorted()
    }
}

private struct WatchRemotePlaylistPicker: View {
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    let tracks: [EnsembleTrack]
    @State private var searchText = ""
    @State private var showsCreate = false

    private var targets: [WatchCompanionPlaylistTargetSnapshot] {
        remoteSession.playlistTargets
            .filter { target in
                tracks.contains { EnsembleSourceScope.isCompatible($0.sourceKey, target.sourceKey) }
            }
            .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var recent: WatchCompanionPlaylistTargetSnapshot? {
        targets.max { ($0.updatedAt ?? 0, $0.id) < ($1.updatedAt ?? 0, $1.id) }
    }

    var body: some View {
        List {
            if let recent {
                Section("Recent") { targetButton(recent) }
            }
            Section("Playlists") {
                if targets.isEmpty {
                    Text("No compatible playlists")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets) { target in
                        targetButton(target)
                    }
                }
            }
            Section {
                Button {
                    showsCreate = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                .disabled(newPlaylistSourceKeys.isEmpty || remoteSession.isCommandInFlight)
            }
        }
        .navigationTitle("Add to Playlist")
        .searchable(text: $searchText, prompt: "Search playlists")
        .task { remoteSession.send(.requestPlaylistTargets) }
        .sheet(isPresented: $showsCreate) {
            WatchNewPlaylistView(sourceKeys: newPlaylistSourceKeys) { title, sourceKey in
                let compatibleTracks = tracks.filter {
                    EnsembleSourceScope.isCompatible($0.sourceKey, sourceKey)
                }
                return await withCheckedContinuation { continuation in
                    remoteSession.send(
                        .createPlaylist,
                        tracks: compatibleTracks.map(\.companionPayload),
                        targetSourceKey: sourceKey,
                        targetTitle: title
                    ) { accepted, _ in
                        continuation.resume(returning: accepted)
                    }
                }
            }
        }
    }

    private func targetButton(_ target: WatchCompanionPlaylistTargetSnapshot) -> some View {
        let compatibleTracks = tracks.filter {
            EnsembleSourceScope.isCompatible($0.sourceKey, target.sourceKey)
        }
        return Button(target.title) {
            remoteSession.send(
                .addItemsToPlaylist,
                tracks: compatibleTracks.map(\.companionPayload),
                targetID: target.id,
                targetSourceKey: target.sourceKey
            ) { accepted, _ in
                if accepted { dismiss() }
            }
        }
        .disabled(compatibleTracks.isEmpty || remoteSession.isCommandInFlight)
    }

    private var newPlaylistSourceKeys: [String] {
        Array(Set(tracks.compactMap { EnsembleSourceScope(sourceKey: $0.sourceKey)?.serverSourceKey })).sorted()
    }
}

private struct WatchNewPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    let sourceKeys: [String]
    let create: (String, String) async -> Bool
    @State private var title = ""
    @State private var selectedSourceKey = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 10) {
            Text("New Playlist")
                .font(.headline)
            TextField("Name", text: $title)
            if sourceKeys.count > 1 {
                Picker("Source", selection: $selectedSourceKey) {
                    ForEach(sourceKeys, id: \.self) { sourceKey in
                        Text(sourceTitle(sourceKey)).tag(sourceKey)
                    }
                }
            }
            Button("Create") {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let sourceKey else { return }
                isSubmitting = true
                Task {
                    if await create(trimmed, sourceKey) { dismiss() }
                    isSubmitting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceKey == nil)
            Button("Cancel") { dismiss() }
        }
        .padding()
        .onAppear {
            if selectedSourceKey.isEmpty {
                selectedSourceKey = sourceKeys.first ?? ""
            }
        }
    }

    private var sourceKey: String? {
        sourceKeys.contains(selectedSourceKey) ? selectedSourceKey : sourceKeys.first
    }

    private func sourceTitle(_ sourceKey: String) -> String {
        sourceKey.split(separator: ":").last.map(String.init) ?? sourceKey
    }
}

private extension EnsembleTrack {
    var companionPayload: WatchCompanionTrackPayload {
        WatchCompanionTrackPayload(
            id: id,
            playlistItemID: playlistItemID,
            title: title,
            artistName: artistName,
            albumID: albumID,
            artistID: artistID,
            albumTitle: albumTitle,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            artworkPath: artworkPath,
            streamKey: streamKey,
            sourceKey: sourceKey
        )
    }
}

private struct WatchMediaMoreButton: View {
    let target: WatchMediaActionTarget
    @State private var showsActions = false

    var body: some View {
        Button {
            showsActions = true
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.secondary.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("More Actions")
        .watchMediaActions(target, isPresented: $showsActions)
    }
}

private struct WatchCollectionPlaybackControls: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let title: String
    let target: WatchMediaActionTarget
    let tracks: [EnsembleTrack]

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                actionButton("Play", systemImage: "play.fill", kind: .play)
                if target.supportsShuffle {
                    actionButton("Shuffle", systemImage: "shuffle", kind: .shuffle)
                }
                if target.supportsRadio {
                    actionButton("Radio", systemImage: "dot.radiowaves.left.and.right", kind: .radio)
                }
                WatchMediaMoreButton(target: target)
            }
            if remotePlaybackDisabled {
                Text("Source isn’t synced to iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionButton(
        _ label: String,
        systemImage: String,
        kind: WatchCompanionCommandKind
    ) -> some View {
        Button {
            if experience.playbackTarget == .remote {
                remoteSession.requestQueueReplacement(kind, tracks: tracks.map(\.companionPayload))
            } else {
                switch kind {
                case .shuffle:
                    target.play(tracks, in: experience, shuffled: true)
                case .radio:
                    experience.playRadio(tracks)
                default:
                    target.play(tracks, in: experience)
                }
            }
            openNowPlaying()
        } label: {
            Image(systemName: systemImage)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.secondary.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("\(label) \(title)")
        .disabled(tracks.isEmpty || remotePlaybackDisabled)
    }

    private var remotePlaybackDisabled: Bool {
        experience.playbackTarget == .remote
            && !remoteSession.canControl(sourceKeys: target.sourceKeys)
    }
}

private struct WatchCollectionHero: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let title: String
    let artworkItem: EnsembleMediaSummary?
    let fallbackArtworkTrack: EnsembleTrack?
    @State private var artworkURL: URL?

    var body: some View {
        VStack(spacing: 4) {
            WatchArtworkImage(url: artworkURL)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .task(id: artworkTaskID) {
            if let artworkItem, artworkItem.artworkPath != nil {
                artworkURL = await experience.artworkURL(for: artworkItem, size: 320)
            } else if let fallbackArtworkTrack {
                artworkURL = await experience.artworkURL(for: fallbackArtworkTrack, size: 320)
            } else {
                artworkURL = nil
            }
        }
    }

    private var artworkTaskID: String {
        "\(artworkItem?.id ?? "none")-\(fallbackArtworkTrack?.id ?? "none")-\(experience.artworkContextID)"
    }
}

private struct WatchCollectionHeaderSection: View {
    let title: String
    let subtitle: String?
    let actionTarget: WatchMediaActionTarget?

    init(title: String, subtitle: String?, actionTarget: WatchMediaActionTarget? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.actionTarget = actionTarget
    }

    var body: some View {
        Section {
            headerRow
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        let row = VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .lineLimit(3)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)

        if let actionTarget {
            row.watchMediaSwipeActions(actionTarget)
        } else {
            row
        }
    }
}

private struct WatchMediaActionDestination: Hashable {
    let id: String
    let kindRawValue: String
    let title: String
    let subtitle: String?
    let albumID: String?
    let artistID: String?
    let artworkPath: String?
    let sourceKey: String
    let isSmart: Bool?

    init(item: EnsembleMediaSummary) {
        id = item.id
        kindRawValue = item.kind.rawValue
        title = item.title
        subtitle = item.subtitle
        albumID = item.albumID
        artistID = item.artistID
        artworkPath = item.artworkPath
        sourceKey = item.sourceKey
        isSmart = item.isSmart
    }

    var mediaSummary: EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: id,
            kind: EnsembleMediaKind(rawValue: kindRawValue) ?? .track,
            title: title,
            subtitle: subtitle,
            albumID: albumID,
            artistID: artistID,
            artworkPath: artworkPath,
            sourceKey: sourceKey,
            isSmart: isSmart
        )
    }
}

private struct WatchNavigateToMediaKey: EnvironmentKey {
    static let defaultValue: (WatchMediaActionDestination) -> Void = { _ in }
}

private struct WatchOpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
    var watchNavigateToMedia: (WatchMediaActionDestination) -> Void {
        get { self[WatchNavigateToMediaKey.self] }
        set { self[WatchNavigateToMediaKey.self] = newValue }
    }

    var watchOpenNowPlaying: () -> Void {
        get { self[WatchOpenNowPlayingKey.self] }
        set { self[WatchOpenNowPlayingKey.self] = newValue }
    }
}

private struct WatchArtistAlbumSummary: Identifiable {
    let id: String
    let title: String
    let artistName: String?
    let sourceKey: String
    let tracks: [EnsembleTrack]

    var representativeTrack: EnsembleTrack? {
        tracks.first
    }

    var mediaSummary: EnsembleMediaSummary? {
        guard let albumID = representativeTrack?.albumID else { return nil }
        return EnsembleMediaSummary(
            id: albumID,
            kind: .album,
            title: title,
            subtitle: artistName,
            artworkPath: representativeTrack?.artworkPath,
            sourceKey: sourceKey
        )
    }

    var subtitle: String {
        let count = tracks.count
        return count == 1 ? "1 track" : "\(count) tracks"
    }

    static func albums(from tracks: [EnsembleTrack]) -> [WatchArtistAlbumSummary] {
        var albums: [WatchArtistAlbumSummary] = []
        var albumIndexesByKey: [String: Int] = [:]

        for track in tracks {
            let title = normalizedAlbumTitle(for: track)
            let albumID = track.albumID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = if let albumID, !albumID.isEmpty {
                "\(track.sourceKey)|\(albumID)"
            } else {
                "\(track.sourceKey)|\(title.lowercased())"
            }

            if let index = albumIndexesByKey[key] {
                let album = albums[index]
                albums[index] = WatchArtistAlbumSummary(
                    id: album.id,
                    title: album.title,
                    artistName: album.artistName,
                    sourceKey: album.sourceKey,
                    tracks: album.tracks + [track]
                )
            } else {
                albumIndexesByKey[key] = albums.count
                albums.append(WatchArtistAlbumSummary(
                    id: key,
                    title: title,
                    artistName: track.artistName,
                    sourceKey: track.sourceKey,
                    tracks: [track]
                ))
            }
        }

        return albums
    }

    static func album(withID id: String, in tracks: [EnsembleTrack]) -> WatchArtistAlbumSummary? {
        albums(from: tracks).first { $0.id == id }
    }

    private static func normalizedAlbumTitle(for track: EnsembleTrack) -> String {
        guard let albumTitle = track.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !albumTitle.isEmpty else {
            return "Unknown Album"
        }
        return albumTitle
    }
}

private enum WatchQueueSection: String, CaseIterable, Identifiable {
    case upNext
    case continuePlaying
    case autoplay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .upNext: return "Up Next"
        case .continuePlaying: return "Continue Playing"
        case .autoplay: return "AutoPlay"
        }
    }

    var source: EnsembleQueueItemSource { EnsembleQueueItemSource(rawValue: rawValue)! }
}

private struct WatchQueueView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if experience.playbackTarget == .remote {
                remoteQueue
            } else {
                localQueue
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: experience.playbackTarget) {
            if experience.playbackTarget == .remote, remoteSession.isReachable {
                remoteSession.requestQueue()
            }
        }
    }

    @ViewBuilder
    private var localQueue: some View {
        Section {
            queueControls(
                shuffle: experience.isShuffleEnabled,
                repeatTitle: localRepeatTitle,
                autoplay: experience.isAutoplayEnabled,
                toggleShuffle: experience.toggleShuffle,
                cycleRepeat: experience.cycleRepeatMode,
                toggleAutoplay: experience.toggleAutoplay
            )
        }

        let allItems = experience.upcomingQueueItems
        let items = Array(allItems.prefix(experience.queueDisplayLimit))
        if items.isEmpty {
            Text("Queue is empty")
                .foregroundStyle(.secondary)
        } else {
            ForEach(WatchQueueSection.allCases) { section in
                let sectionItems = items.filter { $0.source == section.source }
                if !sectionItems.isEmpty {
                    Section(section.title) {
                        ForEach(sectionItems) { item in
                            Button {
                                experience.playQueueItem(id: item.id)
                            } label: {
                                WatchQueueRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            moreRow(totalCount: allItems.count)
        }
    }

    @ViewBuilder
    private var remoteQueue: some View {
        if !remoteSession.isReachable {
            Text("Reconnect to iPhone")
                .foregroundStyle(.secondary)
        } else if let queue = remoteSession.queueSnapshot {
            Section {
                queueControls(
                    shuffle: remoteSession.snapshot?.isShuffleEnabled == true,
                    repeatTitle: remoteRepeatTitle,
                    autoplay: remoteSession.snapshot?.isAutoplayEnabled == true,
                    toggleShuffle: { remoteSession.send(.toggleShuffle) },
                    cycleRepeat: { remoteSession.send(.cycleRepeatMode) },
                    toggleAutoplay: { remoteSession.send(.toggleAutoplay) },
                    disabled: remoteSession.isCommandInFlight
                )
            }

            let start = max(0, queue.currentQueueIndex + 1)
            let allItems = Array(queue.items.dropFirst(start))
            let items = Array(allItems.prefix(experience.queueDisplayLimit))
            if items.isEmpty {
                Text("Queue is empty")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(WatchQueueSection.allCases) { section in
                    let sectionItems = items.filter { $0.source == section.source.rawValue }
                    if !sectionItems.isEmpty {
                        Section(section.title) {
                            ForEach(sectionItems, id: \.id) { item in
                                Button {
                                    remoteSession.send(
                                        .playQueueItem,
                                        itemID: item.id,
                                        itemSourceKey: item.sourceKey,
                                        itemPlaylistItemID: item.playlistItemID,
                                        queueRevision: queue.revision
                                    )
                                } label: {
                                    WatchRemoteQueueRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .disabled(remoteSession.isCommandInFlight)
                            }
                        }
                    }
                }
                moreRow(totalCount: queue.totalUpcomingCount ?? allItems.count)
            }
        } else {
            ProgressView("Loading queue")
        }
    }

    @ViewBuilder
    private func queueControls(
        shuffle: Bool,
        repeatTitle: String,
        autoplay: Bool,
        toggleShuffle: @escaping () -> Void,
        cycleRepeat: @escaping () -> Void,
        toggleAutoplay: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        Button {
            toggleShuffle()
        } label: {
            Label(shuffle ? "Shuffle On" : "Shuffle Off", systemImage: "shuffle")
        }
        .disabled(disabled)
        Button {
            cycleRepeat()
        } label: {
            Label(repeatTitle, systemImage: "repeat")
        }
        .disabled(disabled)
        Button {
            toggleAutoplay()
        } label: {
            Label(autoplay ? "AutoPlay On" : "AutoPlay Off", systemImage: "infinity.circle.fill")
        }
        .disabled(disabled)
    }

    @ViewBuilder
    private func moreRow(totalCount: Int) -> some View {
        if totalCount > experience.queueDisplayLimit {
            Text("\(totalCount - experience.queueDisplayLimit) more songs")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var localRepeatTitle: String {
        switch experience.repeatMode {
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        case .off: return "Repeat Off"
        }
    }

    private var remoteRepeatTitle: String {
        switch remoteSession.snapshot?.repeatMode {
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        case .off, nil: return "Repeat Off"
        }
    }
}

private struct WatchQueueRow: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: WatchQueueItem
    @State private var artworkURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            WatchArtworkImage(url: artworkURL)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.track.artistName ?? "Unknown Artist")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: item.id) {
            artworkURL = await experience.artworkURL(for: item.track, size: 96)
        }
    }
}

private struct WatchRemoteQueueRow: View {
    let item: WatchCompanionQueueItemSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if let artworkData = item.artworkData,
               let image = UIImage(data: artworkData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.artistName ?? "Unknown Artist")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct WatchNowPlayingView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var playback: WatchPlaybackController
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var artwork: UIImage?
    @State private var blurredArtwork: UIImage?
    @State private var showsMoreActions = false
    @State private var showsQueue = false
    @State private var showsPlaybackTargets = false
    @State private var showsSystemNowPlaying = false
    @State private var currentPlaylistTracks: [EnsembleTrack] = []
    @State private var showsCurrentPlaylistPicker = false
    @State private var showsCurrentItemActions = false
    @State private var showsCurrentDeleteConfirmation = false

    var body: some View {
        ZStack {
            nowPlayingBackground

            if let presentation = currentPresentation {
                GeometryReader { geometry in
                    let artworkSide = min(136, min(geometry.size.width * 0.6, geometry.size.height * 0.48))

                    VStack(spacing: 4) {
                        Spacer(minLength: 0)

                        artworkView
                            .frame(width: artworkSide, height: artworkSide)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(spacing: 0) {
                            Text(presentation.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(presentation.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)

                        Spacer(minLength: 0)
                    }
                    .safeAreaPadding(.bottom, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Nothing Playing")
                        .font(.headline)
                    Text(currentEmptyMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close Now Playing")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsMoreActions = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More Actions")
            }

            ToolbarItemGroup(placement: .bottomBar) {
                previousButton
                playPauseButton
                nextButton
            }
        }
        .confirmationDialog("More Actions", isPresented: $showsMoreActions, titleVisibility: .visible) {
            Button {
                showsQueue = true
            } label: {
                Label("Queue", systemImage: "list.bullet")
            }

            Button {
                showsPlaybackTargets = true
            } label: {
                Label("Playback Target", systemImage: experience.playbackTarget == .local ? "applewatch" : "iphone")
            }

            Button {
                showsSystemNowPlaying = true
            } label: {
                Label("Output", systemImage: "airplayaudio")
            }

            Button {
                showsCurrentItemActions = true
            } label: {
                Label("Current Item Actions", systemImage: "ellipsis.circle")
            }
        }
        .confirmationDialog("Playback Target", isPresented: $showsPlaybackTargets, titleVisibility: .visible) {
            playbackTargetButtons
        }
        .confirmationDialog(
            "Current Item Actions",
            isPresented: $showsCurrentItemActions,
            titleVisibility: .visible
        ) {
            currentItemActionButtons
        }
        .sheet(isPresented: $showsQueue) {
            NavigationStack {
                WatchQueueView()
            }
        }
        .sheet(isPresented: $showsSystemNowPlaying) {
            NowPlayingView()
        }
        .sheet(isPresented: $showsCurrentPlaylistPicker) {
            NavigationStack {
                if experience.playbackTarget == .remote {
                    WatchRemotePlaylistPicker(tracks: currentPlaylistTracks)
                } else {
                    WatchPlaylistPicker(tracks: currentPlaylistTracks)
                }
            }
        }
        .alert(
            "Delete \(currentActionTrack?.title ?? "Track")?",
            isPresented: $showsCurrentDeleteConfirmation
        ) {
            if let track = currentActionTrack {
                Button("Delete", role: .destructive) {
                    if experience.playbackTarget == .remote {
                        remoteSession.send(
                            .deleteCurrentItem,
                            itemID: track.id,
                            itemSourceKey: track.sourceKey
                        )
                    } else {
                        Task { _ = await experience.delete(track.summary) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from your Plex library.")
        }
        .task(id: artworkIdentity) {
            await loadArtwork()
        }
        .task(id: experience.playbackTarget) {
            if experience.playbackTarget == .remote, remoteSession.isReachable {
                remoteSession.send(.requestPlaylistTargets)
            }
        }
    }

    @ViewBuilder
    private var nowPlayingBackground: some View {
        if let blurredArtwork {
            Image(uiImage: blurredArtwork)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .saturation(0.8)
                .overlay(Color.black.opacity(0.42))
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.18)
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var playbackTargetButtons: some View {
        Button {
            experience.playbackTarget = .local
        } label: {
            Label("This Watch", systemImage: experience.playbackTarget == .local ? "checkmark" : "applewatch")
        }

        Button {
            experience.playbackTarget = .remote
        } label: {
            Label("iPhone", systemImage: experience.playbackTarget == .remote ? "checkmark" : "iphone")
        }
    }

    private var previousButton: some View {
        Button {
            if experience.playbackTarget == .local {
                experience.playPrevious()
            } else {
                remoteSession.send(.previous)
            }
        } label: {
            Image(systemName: "backward.fill")
        }
        .accessibilityLabel("Previous")
        .disabled(previousDisabled)
    }

    private var playPauseButton: some View {
        Button {
            if experience.playbackTarget == .local {
                playback.togglePlayPause()
            } else {
                remoteSession.send(.togglePlayPause)
            }
        } label: {
            ZStack {
                Circle()
                    .trim(from: 0, to: playbackProgress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)

                WatchSystemVolumeControl(origin: volumeControlOrigin)
                    .id(volumeControlOrigin)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: 32, height: 32)
        }
        .buttonBorderShape(.circle)
        .scaleEffect(1.15)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityValue("\(Int(playbackProgress * 100)) percent")
        .disabled(playPauseDisabled)
    }

    private var nextButton: some View {
        Button {
            if experience.playbackTarget == .local {
                experience.playNext()
            } else {
                remoteSession.send(.next)
            }
        } label: {
            Image(systemName: "forward.fill")
        }
        .accessibilityLabel("Next")
        .disabled(nextDisabled)
    }

    private var currentPresentation: WatchNowPlayingPresentation? {
        if experience.playbackTarget == .remote {
            guard let track = remoteSession.snapshot?.currentTrack else { return nil }
            return WatchNowPlayingPresentation(
                title: track.title,
                artist: track.artistName ?? "Unknown Artist"
            )
        }

        guard let track = playback.currentTrack else { return nil }
        return WatchNowPlayingPresentation(
            title: track.title,
            artist: track.artistName ?? "Unknown Artist"
        )
    }

    private var isPlaying: Bool {
        experience.playbackTarget == .local ? playback.isPlaying : remoteSession.isPlaying
    }

    private var playbackProgress: Double {
        experience.playbackTarget == .local ? playback.progress : remoteSession.progress
    }

    private var playPauseDisabled: Bool {
        if experience.playbackTarget == .local {
            return playback.currentTrack == nil
        }
        return remoteSession.snapshot?.currentTrack == nil
            || !remoteSession.isReachable
            || remoteSession.isCommandInFlight
    }

    private var previousDisabled: Bool {
        if experience.playbackTarget == .local {
            return !experience.canPlayPrevious
        }
        return remoteSession.snapshot?.currentTrack == nil
            || !remoteSession.isReachable
            || remoteSession.isCommandInFlight
    }

    private var nextDisabled: Bool {
        if experience.playbackTarget == .local {
            return !experience.canPlayNext
        }
        guard remoteSession.isReachable, let snapshot = remoteSession.snapshot else { return true }
        return snapshot.currentTrack == nil
            || snapshot.currentQueueIndex >= snapshot.queueCount - 1
            || remoteSession.isCommandInFlight
    }

    private var currentEmptyMessage: String {
        experience.playbackTarget == .local ? experience.playbackStatusMessage : remoteSession.statusMessage
    }

    private var remoteRepeatTitle: String {
        switch remoteSession.snapshot?.repeatMode {
        case .all:
            return "Repeat All"
        case .one:
            return "Repeat One"
        case .off, nil:
            return "Repeat Off"
        }
    }

    private var localRepeatTitle: String {
        switch experience.repeatMode {
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        case .off: return "Repeat Off"
        }
    }

    @ViewBuilder
    private var currentItemActionButtons: some View {
        if let currentTrack = currentActionTrack {
            WatchMediaActionButtons(
                target: .track(currentTrack, queue: experience.libraryTracks),
                actions: [.addToPlaylist, .addToRecentPlaylist, .favorite,
                          .goToAlbum, .goToArtist, .share, .delete],
                openPlaylistPicker: { tracks in
                    currentPlaylistTracks = tracks
                    showsCurrentPlaylistPicker = true
                }
            ) {
                showsCurrentDeleteConfirmation = true
            }
        }
    }

    private var currentActionTrack: EnsembleTrack? {
        if experience.playbackTarget == .local {
            return experience.currentQueueItem?.track
        }
        guard let track = remoteSession.snapshot?.currentTrack,
              let sourceKey = track.sourceKey else { return nil }
        return EnsembleTrack(
            id: track.id,
            title: track.title,
            artistName: track.artistName,
            albumID: track.albumID,
            artistID: track.artistID,
            albumTitle: track.albumTitle,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration ?? remoteSession.snapshot?.duration ?? 0,
            sourceKey: sourceKey,
            isFavorite: track.isFavorite
        )
    }

    private var volumeControlOrigin: WKInterfaceVolumeControl.Origin {
        experience.playbackTarget == .local ? .local : .companion
    }

    private var artworkIdentity: String {
        if experience.playbackTarget == .remote {
            guard let track = remoteSession.snapshot?.currentTrack else { return "remote" }
            return "remote:\(track.id):\(track.artworkData?.hashValue ?? 0)"
        }
        guard let track = playback.currentTrack else { return "local" }
        return "local:\(track.sourceKey):\(track.id)"
    }

    private func loadArtwork() async {
        artwork = nil
        blurredArtwork = nil

        if experience.playbackTarget == .remote {
            guard let data = remoteSession.snapshot?.currentTrack?.artworkData,
                  let image = UIImage(data: data) else { return }
            artwork = image
            blurredArtwork = WatchArtworkLoader.blurred(image, key: artworkIdentity)
            return
        }

        guard let track = playback.currentTrack,
              let url = await experience.artworkURL(for: track, size: 240),
              let image = await WatchArtworkLoader.image(from: url) else { return }
        playback.setNowPlayingArtwork(image, for: track)
        artwork = image
        blurredArtwork = WatchArtworkLoader.blurred(image, key: artworkIdentity)
    }
}

private struct WatchNowPlayingPresentation {
    let title: String
    let artist: String
}

private struct WatchSystemVolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: origin)
        control.setTintColor(.green)
        focus(control)
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.setTintColor(.green)
        focus(control)
    }

    static func dismantleWKInterfaceObject(
        _ control: WKInterfaceVolumeControl,
        coordinator: Void
    ) {
        control.resignFocus()
    }

    private func focus(_ control: WKInterfaceVolumeControl) {
        DispatchQueue.main.async {
            control.focus()
        }
    }
}

private extension View {
    func watchNowPlayingToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WatchNowPlayingToolbarLink()
            }
        }
    }
}

private struct WatchNowPlayingToolbarLink: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying

    var body: some View {
        Button {
            openNowPlaying()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.22))
                Image(systemName: experience.playbackTarget == .local ? "applewatch" : "iphone")
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing")
    }

    private var progress: Double {
        experience.playbackTarget == .local ? experience.playback.progress : remoteSession.progress
    }
}

private enum WatchPinsGrid {
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
}

private enum WatchRecentGrid {
    static let spacing: CGFloat = 8
    static let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 2)
}

private struct WatchRecentAlbumCell: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    @State private var artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WatchArtworkImage(url: artworkURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .task(id: "\(item.watchListID)-\(experience.artworkContextID)") {
            artworkURL = await experience.artworkURL(for: item, size: 160)
        }
    }
}

private struct WatchPinArtworkTile: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary

    @State private var artworkURL: URL?

    var body: some View {
        WatchPinArtworkFrame(item: item, artworkURL: artworkURL)
            .aspectRatio(1, contentMode: .fit)
            .task(id: "\(item.id)-\(experience.artworkContextID)") {
                artworkURL = await experience.artworkURL(for: item, size: 112)
            }
    }
}

private struct WatchPinArtworkFrame: View {
    let item: EnsembleMediaSummary
    let artworkURL: URL?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            if item.kind == .artist {
                artworkContent
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .background(Circle().fill(Color.secondary.opacity(0.18)))
            } else {
                artworkContent
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: WatchPinsGrid.cornerRadius, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: WatchPinsGrid.cornerRadius, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                    )
            }
        }
    }

    @ViewBuilder
    private var artworkContent: some View {
        WatchArtworkImage(url: artworkURL)
    }
}

private struct WatchMediaRow: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    let subtitle: String?

    @State private var artworkURL: URL?

    init(item: EnsembleMediaSummary, subtitle: String? = nil) {
        self.item = item
        self.subtitle = subtitle ?? item.subtitle
    }

    var body: some View {
        HStack(spacing: 8) {
            WatchMediaArtworkThumbnail(
                artworkURL: artworkURL,
                isArtist: item.kind == .artist
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .task(id: "\(item.id)-\(experience.artworkContextID)") {
            artworkURL = await experience.artworkURL(for: item, size: 80)
        }
    }
}

private struct WatchTrackRow: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let track: EnsembleTrack

    @State private var artworkURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            WatchMediaArtworkThumbnail(artworkURL: artworkURL, isArtist: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(track.artistName ?? track.albumTitle ?? "Track")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: "\(track.id)-\(experience.artworkContextID)") {
            artworkURL = await experience.artworkURL(for: track, size: 80)
        }
    }
}

private struct WatchAlbumTrackRow: View {
    let track: EnsembleTrack

    var body: some View {
        HStack(spacing: 8) {
            Text(track.trackNumber.map(String.init) ?? "")
                .font(.headline.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(track.title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension EnsembleTrack {
    var watchListID: String {
        "\(sourceKey):\(playlistItemID ?? id)"
    }
}

private extension WatchExperienceModel {
    var artworkContextID: String {
        libraries
            .map { "\($0.sourceKey)@\($0.server.url)" }
            .sorted()
            .joined(separator: "|")
    }
}

private struct WatchMediaArtworkThumbnail: View {
    let artworkURL: URL?
    let isArtist: Bool

    var body: some View {
        if isArtist {
            thumbnail
                .clipShape(Circle())
        } else {
            thumbnail
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var thumbnail: some View {
        WatchArtworkImage(url: artworkURL)
        .frame(width: 34, height: 34)
    }
}

private struct WatchArtworkImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if url != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.18))
            } else {
                Color.secondary.opacity(0.18)
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        guard let url else { return }
        image = await WatchArtworkLoader.image(from: url)
    }
}

private enum WatchArtworkLoader {
    private static let blurredCache = NSCache<NSString, UIImage>()

    static func image(from url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    static func blurred(_ image: UIImage, key: String) -> UIImage? {
        let cacheKey = key as NSString
        if let cached = blurredCache.object(forKey: cacheKey) { return cached }
        guard let source = image.cgImage else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let output = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()
        }
        guard let output else { return nil }
        let result = UIImage(cgImage: output)
        blurredCache.setObject(result, forKey: cacheKey)
        return result
    }
}

private enum WatchAccentColor {
    static let names = ["purple", "blue", "pink", "red", "orange", "yellow", "green"]

    static func color(for name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        default: return .blue
        }
    }
}

private extension EnsembleMediaKind {
    var title: String {
        switch self {
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        case .track: return "Track"
        }
    }
}
