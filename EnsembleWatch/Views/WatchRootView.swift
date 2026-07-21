import EnsembleDomain
import EnsembleWatchCore
import SwiftUI
#if canImport(UIKit)
import CoreGraphics
import UIKit
#endif

struct WatchRootView: View {
    @StateObject private var experience = WatchExperienceModel()
    @StateObject private var remoteSession = WatchSessionModel()
    @State private var showsNowPlaying = false
    @State private var selectedPin: EnsembleMediaSummary?

    var body: some View {
        NavigationStack {
            rootContent
                .navigationDestination(isPresented: $showsNowPlaying) {
                    WatchNowPlayingView()
                }
                .navigationDestination(isPresented: showsPinDetail) {
                    selectedPinDestination
                }
        }
        .environmentObject(experience)
        .environmentObject(experience.playback)
        .environmentObject(remoteSession)
        .environment(\.watchOpenNowPlaying) {
            showsNowPlaying = true
        }
        .onAppear {
            experience.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            experience.cloudPreferencesDidChange()
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
        .navigationTitle("Ensemble")
        .watchNowPlayingToolbar()
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

            Section("Library") {
                ForEach(EnsembleLibraryCategory.allCases) { category in
                    NavigationLink(destination: WatchCategoryView(category: category)) {
                        Label(category.title, systemImage: category.systemImage)
                    }
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
    let item: EnsembleMediaSummary
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            WatchPinArtworkTile(item: item)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
    }
}

private struct WatchSourceSettingsView: View {
    @EnvironmentObject private var experience: WatchExperienceModel

    var body: some View {
        List {
            if experience.sourceAccounts.isEmpty {
                Section {
                    Text("No sources found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    Button {
                        experience.syncSelectedLibraries()
                    } label: {
                        Label("Sync Selected Libraries", systemImage: "arrow.clockwise")
                    }
                    .disabled(experience.libraries.isEmpty)
                }

                ForEach(experience.sourceAccounts) { account in
                    ForEach(account.servers) { server in
                        Section {
                            ForEach(server.libraries) { library in
                                Toggle(isOn: Binding(
                                    get: { library.isEnabled },
                                    set: { _ in experience.toggleLibrarySelection(library) }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(library.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text(library.isEnabled ? "Synced" : "Not synced")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.title)
                                Text(account.title)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Text(experience.statusMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .watchNowPlayingToolbar()
    }
}

private struct WatchCategoryView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let category: EnsembleLibraryCategory

    var body: some View {
        Group {
            if category == .albums {
                albumStack
            } else if category == .playlists {
                playlistList
            } else if category == .recentlyAdded {
                List(items, id: \.watchListID) { item in
                    row(for: item)
                }
            } else if #available(watchOS 26.0, *) {
                List {
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
                    ForEach(sections, id: \.letter) { section in
                        Section(section.letter) {
                            rows(for: section.items)
                        }
                    }
                }
            }
        }
        .navigationTitle(category.title)
        .watchNowPlayingToolbar()
    }

    private var albumStack: some View {
        GeometryReader { geometry in
            let albums = sections.flatMap(\.items)
            let artworkSize = min(geometry.size.width - 4, geometry.size.height - 16)

            if albums.isEmpty {
                Text("No Albums")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WatchCrownAlbumStack(
                    albums: albums,
                    artworkSize: artworkSize,
                    pageWidth: geometry.size.width,
                    pageHeight: geometry.size.height
                )
            }
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        if #available(watchOS 26.0, *) {
            List {
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
            .sorted { $0.letter < $1.letter }
    }

    private var playlistSections: [(letter: String, groups: [WatchPlaylistGroup])] {
        Dictionary(grouping: sortedPlaylistGroups) { $0.title.ensembleIndexingLetter }
            .map { (letter: $0.key, groups: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    private var sortedItems: [EnsembleMediaSummary] {
        items.sorted { lhs, rhs in
            let comparison = lhs.title.ensembleSortingKey.localizedStandardCompare(rhs.title.ensembleSortingKey)
            if comparison == .orderedSame {
                return lhs.watchListID < rhs.watchListID
            }
            return comparison == .orderedAscending
        }
    }

    private var sortedPlaylistGroups: [WatchPlaylistGroup] {
        experience.playlistGroups.sorted { lhs, rhs in
            let comparison = lhs.title.ensembleSortingKey.localizedStandardCompare(rhs.title.ensembleSortingKey)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    private var items: [EnsembleMediaSummary] {
        guard let snapshot = experience.catalogSnapshot else { return [] }
        switch category {
        case .albums:
            return snapshot.albums
        case .artists:
            return snapshot.artists
        case .playlists:
            return snapshot.playlists
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

    var body: some View {
        List {
            WatchCollectionHeaderSection(
                title: item.title,
                subtitle: item.subtitle,
                actionTarget: .media(item)
            )

            Section {
                if experience.detailTracks.isEmpty {
                    Text(experience.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(artistAlbums) { album in
                        WatchArtistAlbumNavigationRow(album: album)
                    }
                }
            }
        }
        .navigationTitle("Artist")
        .watchNowPlayingToolbar()
        .onAppear {
            experience.tracks(for: item)
        }
    }

    private var artistAlbums: [WatchArtistAlbumSummary] {
        WatchArtistAlbumSummary.albums(from: experience.detailTracks)
    }
}

private struct WatchArtistAlbumNavigationRow: View {
    let album: WatchArtistAlbumSummary

    var body: some View {
        NavigationLink {
            WatchTrackCollectionDetailView(
                title: album.title,
                source: .artistAlbum(album.id)
            )
        } label: {
            WatchArtistAlbumRow(album: album)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .watchMediaSwipeActions(.artistAlbum(album))
    }
}

private struct WatchTrackCollectionDetailView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let title: String
    let source: WatchTrackCollectionSource

    var body: some View {
        TabView {
            collectionHero
                .toolbar {
                    if let headerActionTarget {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button {
                                headerActionTarget.play(in: experience)
                                openNowPlaying()
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .accessibilityLabel("Play \(title)")

                            Text(title)
                                .font(.headline)
                                .lineLimit(1)

                            WatchMediaMoreButton(target: headerActionTarget)
                        }
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
            case .artistAlbum:
                break
            }
        }
    }

    private var collectionHero: some View {
        WatchCollectionHero(
            title: title,
            artworkItem: artworkItem,
            fallbackArtworkTrack: tracks.first,
            actionTarget: headerActionTarget
        )
    }

    private var trackList: some View {
        List {
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
        NavigationLink {
            WatchNowPlayingView()
                .task {
                    experience.play(track, in: tracks)
                }
        } label: {
            row()
        }
        .watchMediaSwipeActions(.track(track))
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
        case .artistAlbum:
            return true
        }
    }

    private var tracks: [EnsembleTrack] {
        switch source {
        case .media, .playlistGroup:
            return experience.detailTracks
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks)?.tracks ?? []
        }
    }

    private var emptyMessage: String {
        switch source {
        case .media, .playlistGroup:
            return experience.statusMessage
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
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks)?.mediaSummary
        }
    }
}

private enum WatchTrackCollectionSource {
    case media(EnsembleMediaSummary)
    case playlistGroup(WatchPlaylistGroup)
    case artistAlbum(String)
}

private enum WatchMediaActionTarget: Identifiable {
    case media(EnsembleMediaSummary)
    case playlistGroup(WatchPlaylistGroup)
    case artistAlbum(WatchArtistAlbumSummary)
    case track(EnsembleTrack)

    var id: String {
        switch self {
        case .media(let item):
            return "media:\(item.id)"
        case .playlistGroup(let group):
            return "playlistGroup:\(group.id)"
        case .artistAlbum(let album):
            return "artistAlbum:\(album.id)"
        case .track(let track):
            return "track:\(track.id)"
        }
    }

    var title: String {
        switch self {
        case .media(let item):
            return item.title
        case .playlistGroup(let group):
            return group.title
        case .artistAlbum(let album):
            return album.title
        case .track(let track):
            return track.title
        }
    }

    @MainActor
    func canPin(in experience: WatchExperienceModel) -> Bool {
        switch self {
        case .media(let item):
            return experience.canPin(item)
        case .playlistGroup(let group):
            return experience.canPin(group)
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
        case .artistAlbum:
            return true
        case .track:
            return false
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
            guard let track = shuffled ? album.tracks.randomElement() : album.tracks.first else { return }
            experience.play(track, in: album.tracks)
        case .track(let track):
            experience.play(track)
        }
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
        confirmationDialog(target.title, isPresented: isPresented, titleVisibility: .visible) {
            WatchMediaActionButtons(target: target)
        }
    }

}

private struct WatchMediaActionButtons: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @Environment(\.watchOpenNowPlaying) private var openNowPlaying
    let target: WatchMediaActionTarget

    var body: some View {
        Button {
            target.play(in: experience)
            openNowPlaying()
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        if target.supportsShuffle {
            Button {
                target.play(in: experience, shuffled: true)
                openNowPlaying()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }

        if target.canPin(in: experience) {
            Button {
                target.togglePin(in: experience)
            } label: {
                Label(
                    target.isPinned(in: experience) ? "Unpin" : "Pin",
                    systemImage: target.isPinned(in: experience) ? "pin.slash" : "pin"
                )
            }
        }
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
        }
        .accessibilityLabel("More Actions")
        .watchMediaActions(target, isPresented: $showsActions)
    }
}

private struct WatchCollectionHero: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let title: String
    let artworkItem: EnsembleMediaSummary?
    let fallbackArtworkTrack: EnsembleTrack?
    let actionTarget: WatchMediaActionTarget?
    @State private var artworkURL: URL?

    var body: some View {
        VStack(spacing: 10) {
            WatchArtworkImage(url: artworkURL)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if actionTarget == nil {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

private struct WatchOpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
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

private struct WatchNowPlayingView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var playback: WatchPlaybackController
    @EnvironmentObject private var remoteSession: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var volume = 1.0
    @State private var artwork: UIImage?
    @State private var blurredArtwork: UIImage?
    @State private var showsMoreActions = false

    var body: some View {
        ZStack {
            nowPlayingBackground

            if let presentation = currentPresentation {
                GeometryReader { geometry in
                    let artworkSide = min(136, min(geometry.size.width * 0.56, geometry.size.height * 0.48))

                    VStack(spacing: 6) {
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

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
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
                    Text(experience.statusMessage)
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
            playbackTargetMenu

            if experience.playbackTarget == .remote {
                Button(remoteSession.snapshot?.isShuffleEnabled == true ? "Disable Shuffle" : "Enable Shuffle") {
                    remoteSession.send(.toggleShuffle)
                }

                Button(remoteRepeatTitle) {
                    remoteSession.send(.cycleRepeatMode)
                }
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $volume,
            from: 0,
            through: 1,
            by: 0.02,
            sensitivity: .medium,
            isContinuous: true,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            volume = playback.volume
        }
        .onChange(of: volume) { _, newVolume in
            playback.setVolume(newVolume)
        }
        .task(id: artworkIdentity) {
            await loadArtwork()
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
    private var playbackTargetMenu: some View {
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
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.headline)
                .overlay {
                    Circle()
                        .trim(from: 0, to: playbackProgress)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32, height: 32)
                }
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
            return WatchNowPlayingPresentation(
                title: remoteSession.currentTrackTitle,
                artist: remoteSession.snapshot?.currentTrack?.artistName ?? "Unknown Artist"
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
        return remoteSession.isSendingCommand
    }

    private var previousDisabled: Bool {
        if experience.playbackTarget == .local {
            return !experience.canPlayPrevious
        }
        return remoteSession.isSendingCommand
    }

    private var nextDisabled: Bool {
        if experience.playbackTarget == .local {
            return !experience.canPlayNext
        }
        return remoteSession.isSendingCommand
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

    private var artworkIdentity: String {
        guard experience.playbackTarget == .local, let track = playback.currentTrack else {
            return "remote"
        }
        return "\(track.sourceKey):\(track.id)"
    }

    private func loadArtwork() async {
        artwork = nil
        blurredArtwork = nil
        guard experience.playbackTarget == .local,
              let track = playback.currentTrack,
              let url = await experience.artworkURL(for: track, size: 240),
              let image = await WatchArtworkLoader.image(from: url) else {
            return
        }
        artwork = image
        blurredArtwork = WatchArtworkLoader.blurred(image)
    }
}

private struct WatchNowPlayingPresentation {
    let title: String
    let artist: String

    init(
        title: String,
        artist: String
    ) {
        self.title = title
        self.artist = artist
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
    var body: some View {
        NavigationLink(destination: WatchNowPlayingView()) {
            Image(systemName: "waveform")
        }
        .accessibilityLabel("Now Playing")
    }
}

private enum WatchPinsGrid {
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
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

private struct WatchCrownAlbumStack: View {
    let albums: [EnsembleMediaSummary]
    let artworkSize: CGFloat
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    private let sectionStartIndices: [Int]

    @State private var selection = 0
    @State private var currentIndex = 0
    @State private var baseIndex = 0
    @State private var overlayIndex = 0
    @State private var overlayLift: CGFloat = 0
    @State private var isApplyingIndexJump = false

    private static let indexScrollVelocityThreshold = 50.0

    init(
        albums: [EnsembleMediaSummary],
        artworkSize: CGFloat,
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) {
        self.albums = albums
        self.artworkSize = artworkSize
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight

        var previousLetter: String?
        sectionStartIndices = albums.indices.filter { index in
            let letter = albums[index].title.ensembleIndexingLetter
            defer { previousLetter = letter }
            return letter != previousLetter
        }
    }

    var body: some View {
        Group {
            if let selectedAlbum = album(at: currentIndex) {
                WatchAlbumNavigationCard(
                    album: selectedAlbum,
                    baseAlbum: album(at: baseIndex),
                    overlayAlbum: album(at: overlayIndex),
                    artworkSize: artworkSize,
                    pageWidth: pageWidth,
                    overlayLift: overlayLift
                )
            }
        }
        .frame(width: pageWidth, height: pageHeight, alignment: .top)
        .focusable()
        .digitalCrownRotation(
            detent: $selection,
            from: 0,
            through: max(albums.count - 1, 0),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true,
            onChange: { event in
                handleCrownEvent(event)
            },
            onIdle: finishCrownScrolling
        )
        .digitalCrownAccessory {
            if let selectedAlbum = album(at: currentIndex) {
                Text(selectedAlbum.title.ensembleIndexingLetter)
            }
        }
        .onChange(of: selection, showSelectionChange)
        .onChange(of: albums.count) { _, _ in clampSelection() }
    }

    private func album(at index: Int) -> EnsembleMediaSummary? {
        albums.indices.contains(index) ? albums[index] : albums.first
    }

    private func showSelectionChange(from _: Int, to newIndex: Int) {
        if isApplyingIndexJump {
            isApplyingIndexJump = false
        } else {
            showAlbum(at: newIndex)
        }
    }

    private func handleCrownEvent(_ event: DigitalCrownEvent) {
        guard abs(event.velocity) >= Self.indexScrollVelocityThreshold else { return }
        moveToAdjacentSection(forward: event.velocity > 0)
    }

    private func moveToAdjacentSection(forward: Bool) {
        guard !sectionStartIndices.isEmpty else { return }
        let currentSection = sectionStartIndices.lastIndex { $0 <= currentIndex } ?? 0
        let targetSection = min(
            max(currentSection + (forward ? 1 : -1), 0),
            sectionStartIndices.count - 1
        )
        let targetIndex = sectionStartIndices[targetSection]

        if selection != targetIndex {
            isApplyingIndexJump = true
            selection = targetIndex
        }
        showAlbum(at: targetIndex)
    }

    private func finishCrownScrolling() {
        if selection != currentIndex {
            isApplyingIndexJump = true
            selection = currentIndex
        }
    }

    private func showAlbum(at newIndex: Int) {
        guard albums.indices.contains(newIndex), newIndex != currentIndex else { return }
        let previousIndex = currentIndex
        currentIndex = newIndex

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if newIndex > previousIndex {
                baseIndex = previousIndex
                overlayIndex = newIndex
                overlayLift = 1
            } else {
                baseIndex = newIndex
                overlayIndex = previousIndex
                overlayLift = 0
            }
        }

        withAnimation(.easeOut(duration: 0.16)) {
            overlayLift = newIndex > previousIndex ? 0 : 1
        }
    }

    private func clampSelection() {
        let clampedIndex = min(selection, max(albums.count - 1, 0))
        selection = clampedIndex
        currentIndex = clampedIndex
        baseIndex = clampedIndex
        overlayIndex = clampedIndex
        overlayLift = 0
        isApplyingIndexJump = false
    }
}

private struct WatchAlbumNavigationCard: View {
    let album: EnsembleMediaSummary
    let baseAlbum: EnsembleMediaSummary?
    let overlayAlbum: EnsembleMediaSummary?
    let artworkSize: CGFloat
    let pageWidth: CGFloat
    let overlayLift: CGFloat

    var body: some View {
        NavigationLink(destination: WatchMediaDetailView(item: album)) {
            ZStack(alignment: .top) {
                WatchAlbumCoverStack(
                    baseAlbum: baseAlbum,
                    overlayAlbum: overlayAlbum,
                    artworkSize: artworkSize,
                    pageWidth: pageWidth,
                    overlayLift: overlayLift
                )

                WatchAlbumTitleLane(album: album, artworkSize: artworkSize)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(album.title)
        .accessibilityHint("Opens album")
    }
}

private struct WatchAlbumCoverStack: View {
    let baseAlbum: EnsembleMediaSummary?
    let overlayAlbum: EnsembleMediaSummary?
    let artworkSize: CGFloat
    let pageWidth: CGFloat
    let overlayLift: CGFloat

    var body: some View {
        ZStack {
            if let baseAlbum {
                WatchAlbumBrowseCard(item: baseAlbum, artworkSize: artworkSize)
            }
            if let overlayAlbum {
                WatchAlbumBrowseCard(item: overlayAlbum, artworkSize: artworkSize)
                    .rotation3DEffect(
                        .degrees(-45 * overlayLift),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: .bottom,
                        perspective: 0.4
                    )
                    .offset(y: overlayLift * artworkSize)
            }
        }
        .frame(width: pageWidth, height: artworkSize)
        .clipped()
    }
}

private struct WatchAlbumTitleLane: View {
    let album: EnsembleMediaSummary
    let artworkSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: artworkSize + 1)

            Text(album.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
}

private struct WatchAlbumBrowseCard: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    let artworkSize: CGFloat

    @State private var artworkURL: URL?

    var body: some View {
        ZStack {
            Color.black
            WatchPinArtworkFrame(item: item, artworkURL: artworkURL)
                .frame(width: artworkSize, height: artworkSize)
        }
        .frame(width: artworkSize, height: artworkSize)
        .task(id: "\(item.id)-\(experience.artworkContextID)") {
            artworkURL = await experience.artworkURL(for: item, size: 320)
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

private struct WatchArtistAlbumRow: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let album: WatchArtistAlbumSummary

    @State private var artworkURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            WatchMediaArtworkThumbnail(artworkURL: artworkURL, isArtist: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(album.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: "\(album.id)-\(experience.artworkContextID)") {
            guard let track = album.representativeTrack else {
                artworkURL = nil
                return
            }
            artworkURL = await experience.artworkURL(for: track, size: 80)
        }
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
    static func image(from url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    static func blurred(_ image: UIImage) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage().map(UIImage.init(cgImage:))
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
