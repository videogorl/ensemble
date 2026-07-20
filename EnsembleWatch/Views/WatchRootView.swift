import EnsembleDomain
import EnsembleWatchCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WatchRootView: View {
    @StateObject private var experience = WatchExperienceModel()
    @StateObject private var remoteSession = WatchSessionModel()
    @StateObject private var navigation = WatchNavigationModel()
    @State private var selectedHomePinID: String?

    var body: some View {
        Group {
            if #available(watchOS 9.0, *) {
                NavigationStack(path: $navigation.path) {
                    rootContent
                        .watchRouteDestinations()
                }
            } else {
                NavigationView {
                    rootContent
                }
            }
        }
        .environmentObject(experience)
        .environmentObject(experience.playback)
        .environmentObject(remoteSession)
        .environmentObject(navigation)
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
                            WatchHomePinCell(item: item, selectedPinID: $selectedHomePinID)
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
}

private struct WatchHomePinCell: View {
    let item: EnsembleMediaSummary
    @Binding var selectedPinID: String?

    var body: some View {
        Button {
            selectedPinID = item.id
        } label: {
            WatchPinArtworkTile(item: item)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .background {
            NavigationLink(isActive: isSelected) {
                WatchMediaDetailView(item: item)
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { selectedPinID == item.id },
            set: { isActive in
                if isActive {
                    selectedPinID = item.id
                } else if selectedPinID == item.id {
                    selectedPinID = nil
                }
            }
        )
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
        List(items) { item in
            NavigationLink(destination: WatchMediaDetailView(item: item)) {
                WatchMediaRow(item: item)
            }
            .watchMediaSwipeActions(.media(item))
        }
        .navigationTitle(category.title)
        .watchNowPlayingToolbar()
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

private struct WatchMediaDetailView: View {
    let item: EnsembleMediaSummary

    @ViewBuilder
    var body: some View {
        if item.kind == .artist {
            WatchArtistAlbumsView(item: item)
        } else {
            WatchTrackCollectionDetailView(
                title: item.title,
                subtitle: item.subtitle,
                navigationTitle: item.kind.title,
                source: .media(item)
            )
        }
    }
}

private struct WatchArtistAlbumsView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary
    @State private var selectedAlbumID: String?

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
                        WatchArtistAlbumNavigationRow(album: album, selectedAlbumID: $selectedAlbumID)
                    }
                }
            }
        }
        .navigationTitle("Artist")
        .watchNowPlayingToolbar()
        .watchRouteDestinations()
        .onAppear {
            experience.tracks(for: item)
        }
    }

    private var artistAlbums: [WatchArtistAlbumSummary] {
        WatchArtistAlbumSummary.albums(from: experience.detailTracks)
    }
}

private struct WatchArtistAlbumNavigationRow: View {
    @EnvironmentObject private var navigation: WatchNavigationModel
    let album: WatchArtistAlbumSummary
    @Binding var selectedAlbumID: String?

    @ViewBuilder
    var body: some View {
        if #available(watchOS 9.0, *) {
            Button {
                navigation.path.append(album.route)
            } label: {
                WatchArtistAlbumRow(album: album)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .watchMediaSwipeActions(.artistAlbum(album))
        } else {
            legacyNavigationButton
                .watchMediaSwipeActions(.artistAlbum(album))
        }
    }

    private var legacyNavigationButton: some View {
        Button {
            selectedAlbumID = album.id
        } label: {
            WatchArtistAlbumRow(album: album)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            NavigationLink(isActive: isSelected) {
                WatchTrackCollectionDetailView(
                    title: album.title,
                    subtitle: album.artistName,
                    navigationTitle: "Album",
                    source: .tracks(album.tracks)
                )
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    private var isSelected: Binding<Bool> {
        Binding(
            get: { selectedAlbumID == album.id },
            set: { isActive in
                if isActive {
                    selectedAlbumID = album.id
                } else if selectedAlbumID == album.id {
                    selectedAlbumID = nil
                }
            }
        )
    }
}

private struct WatchTrackCollectionDetailView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let title: String
    let subtitle: String?
    let navigationTitle: String
    let source: WatchTrackCollectionSource

    var body: some View {
        List {
            WatchCollectionHeaderSection(
                title: title,
                subtitle: subtitle,
                actionTarget: headerActionTarget
            )

            Section {
                if tracks.isEmpty {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(tracks) { track in
                        Button {
                            experience.play(track)
                        } label: {
                            WatchTrackRow(track: track)
                        }
                        .watchMediaSwipeActions(.track(track))
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .watchNowPlayingToolbar()
        .onAppear {
            if case let .media(item) = source {
                experience.tracks(for: item)
            }
        }
    }

    private var tracks: [EnsembleTrack] {
        switch source {
        case .media:
            return experience.detailTracks
        case .tracks(let tracks):
            return tracks
        case .artistAlbum(let id):
            return WatchArtistAlbumSummary.album(withID: id, in: experience.detailTracks)?.tracks ?? []
        }
    }

    private var emptyMessage: String {
        switch source {
        case .media:
            return experience.statusMessage
        case .tracks, .artistAlbum:
            return "No tracks found."
        }
    }

    private var headerActionTarget: WatchMediaActionTarget? {
        guard case .media(let item) = source else { return nil }
        return .media(item)
    }
}

private enum WatchTrackCollectionSource {
    case media(EnsembleMediaSummary)
    case tracks([EnsembleTrack])
    case artistAlbum(String)
}

private enum WatchMediaActionTarget: Identifiable {
    case media(EnsembleMediaSummary)
    case artistAlbum(WatchArtistAlbumSummary)
    case track(EnsembleTrack)

    var id: String {
        switch self {
        case .media(let item):
            return "media:\(item.id)"
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
        case .artistAlbum(let album):
            return album.title
        case .track(let track):
            return track.title
        }
    }

    var pinnableItem: EnsembleMediaSummary? {
        switch self {
        case .media(let item):
            switch item.kind {
            case .album, .artist, .playlist:
                return item
            case .track:
                return nil
            }
        case .artistAlbum(let album):
            return album.mediaSummary
        case .track:
            return nil
        }
    }

    var supportsShuffle: Bool {
        switch self {
        case .media(let item):
            return item.kind != .track
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
        case .artistAlbum(let album):
            guard let track = shuffled ? album.tracks.randomElement() : album.tracks.first else { return }
            experience.play(track)
        case .track(let track):
            experience.play(track)
        }
    }
}

private struct WatchMediaSwipeActionsModifier: ViewModifier {
    @EnvironmentObject private var experience: WatchExperienceModel
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
            .confirmationDialog(target.title, isPresented: $showsActions, titleVisibility: .visible) {
                Button {
                    target.play(in: experience)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                if target.supportsShuffle {
                    Button {
                        target.play(in: experience, shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }

                if let item = target.pinnableItem, experience.canPin(item) {
                    Button {
                        experience.togglePin(item)
                    } label: {
                        Label(
                            experience.isPinned(item) ? "Unpin" : "Pin",
                            systemImage: experience.isPinned(item) ? "pin.slash" : "pin"
                        )
                    }
                }
            }
    }
}

private extension View {
    func watchMediaSwipeActions(_ target: WatchMediaActionTarget) -> some View {
        modifier(WatchMediaSwipeActionsModifier(target: target))
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

private enum WatchRoute: Hashable {
    case artistAlbum(id: String, title: String, artistName: String?)
}

@MainActor
private final class WatchNavigationModel: ObservableObject {
    @Published var path: [WatchRoute] = []
}

private extension View {
    @ViewBuilder
    func watchRouteDestinations() -> some View {
        if #available(watchOS 9.0, *) {
            navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .artistAlbum(let id, let title, let artistName):
                    WatchTrackCollectionDetailView(
                        title: title,
                        subtitle: artistName,
                        navigationTitle: "Album",
                        source: .artistAlbum(id)
                    )
                }
            }
        } else {
            self
        }
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

    var route: WatchRoute {
        .artistAlbum(id: id, title: title, artistName: artistName)
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
    @State private var showsTargetPicker = false
    @State private var showsQueueActions = false

    var body: some View {
        let baseView = ScrollView {
            VStack(spacing: 10) {
                if let presentation = currentPresentation {
                    WatchNowPlayingArtwork(presentation: presentation)

                    VStack(spacing: 4) {
                        Text(presentation.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)

                        Text(presentation.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    ProgressView(value: presentation.progress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(presentation.elapsedText)
                        Spacer()
                        Text(presentation.remainingText)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)

                    transportControls

                    HStack {
                        Spacer()

                        Button {
                            showsTargetPicker = true
                        } label: {
                            Image(systemName: "airplayaudio")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Playback Target")
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Nothing Playing")
                            .font(.headline)
                        Text(experience.statusMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Now Playing")
        .confirmationDialog("Playback Target", isPresented: $showsTargetPicker) {
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
        .confirmationDialog("Queue Controls", isPresented: $showsQueueActions) {
            if experience.playbackTarget == .remote {
                Button(remoteSession.snapshot?.isShuffleEnabled == true ? "Disable Shuffle" : "Enable Shuffle") {
                    remoteSession.send(.toggleShuffle)
                }

                Button(remoteRepeatTitle) {
                    remoteSession.send(.cycleRepeatMode)
                }
            }
        }

        if #available(watchOS 10.0, *) {
            baseView.toolbar {
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
                        showsQueueActions = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More Actions")
                    .disabled(experience.playbackTarget == .local)
                }
            }
        } else {
            baseView.toolbar {
                ToolbarItem {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Now Playing")
                }

                ToolbarItem {
                    Button {
                        showsQueueActions = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More Actions")
                    .disabled(experience.playbackTarget == .local)
                }
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            Button {
                if experience.playbackTarget == .remote {
                    remoteSession.send(.previous)
                }
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(experience.playbackTarget == .local || remoteSession.isSendingCommand)

            Button {
                if experience.playbackTarget == .local {
                    playback.togglePlayPause()
                } else {
                    remoteSession.send(.togglePlayPause)
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .disabled(playPauseDisabled)

            Button {
                if experience.playbackTarget == .remote {
                    remoteSession.send(.next)
                }
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(experience.playbackTarget == .local || remoteSession.isSendingCommand)
        }
        .buttonStyle(.plain)
    }

    private var currentPresentation: WatchNowPlayingPresentation? {
        if experience.playbackTarget == .remote {
            return WatchNowPlayingPresentation(
                title: remoteSession.currentTrackTitle,
                subtitle: remoteSession.currentTrackSubtitle,
                artworkURL: nil,
                progress: remoteSession.progress,
                elapsedText: remoteSession.elapsedText,
                remainingText: remoteSession.remainingText,
                isRemote: true
            )
        }

        guard let track = playback.currentTrack else { return nil }
        return WatchNowPlayingPresentation(
            title: track.title,
            subtitle: localSubtitle,
            artworkTrack: track,
            progress: playback.progress,
            elapsedText: playback.currentTime.ensembleWatchClockText,
            remainingText: "-" + max(0, track.duration - playback.currentTime).ensembleWatchClockText,
            isRemote: false
        )
    }

    private var isPlaying: Bool {
        experience.playbackTarget == .local ? playback.isPlaying : remoteSession.isPlaying
    }

    private var playPauseDisabled: Bool {
        if experience.playbackTarget == .local {
            return playback.currentTrack == nil
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

    private var localSubtitle: String {
        let artist = experience.playback.currentTrack?.artistName
        let album = experience.playback.currentTrack?.albumTitle
        switch (artist?.isEmpty == false ? artist : nil, album?.isEmpty == false ? album : nil) {
        case let (.some(artist), .some(album)):
            return "\(artist) - \(album)"
        case let (.some(artist), nil):
            return artist
        case let (nil, .some(album)):
            return album
        case (nil, nil):
            return experience.statusMessage
        }
    }
}

private struct WatchNowPlayingPresentation {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let artworkTrack: EnsembleTrack?
    let progress: Double
    let elapsedText: String
    let remainingText: String
    let isRemote: Bool

    init(
        title: String,
        subtitle: String,
        artworkURL: URL? = nil,
        artworkTrack: EnsembleTrack? = nil,
        progress: Double,
        elapsedText: String,
        remainingText: String,
        isRemote: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.artworkTrack = artworkTrack
        self.progress = progress
        self.elapsedText = elapsedText
        self.remainingText = remainingText
        self.isRemote = isRemote
    }
}

private struct WatchNowPlayingArtwork: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    let presentation: WatchNowPlayingPresentation
    @State private var artworkURL: URL?

    var body: some View {
        WatchArtworkImage(url: resolvedArtworkURL)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: presentation.isRemote ? "iphone" : "applewatch")
                    .font(.caption2)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.62)))
                    .padding(5)
            }
            .task(id: presentation.artworkTrack?.id) {
                guard let track = presentation.artworkTrack else {
                    artworkURL = presentation.artworkURL
                    return
                }
                artworkURL = await experience.artworkURL(for: track, size: 240)
            }
    }

    private var resolvedArtworkURL: URL? {
        artworkURL ?? presentation.artworkURL
    }
}

private extension View {
    @ViewBuilder
    func watchNowPlayingToolbar() -> some View {
        if #available(watchOS 10.0, *) {
            toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchNowPlayingToolbarLink(usesNativeToolbarButton: true)
                }
            }
        } else {
            overlay(alignment: .topTrailing) {
                WatchNowPlayingToolbarLink(usesNativeToolbarButton: false)
                    .padding(.top, 2)
                    .padding(.trailing, 4)
            }
        }
    }
}

private struct WatchNowPlayingToolbarLink: View {
    let usesNativeToolbarButton: Bool

    var body: some View {
        if usesNativeToolbarButton, #available(watchOS 10.0, *) {
            NavigationLink(destination: WatchNowPlayingView()) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel("Now Playing")
        } else {
            NavigationLink(destination: WatchNowPlayingView()) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.24))
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .frame(width: 34, height: 34)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing")
        }
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

    @State private var artworkURL: URL?

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
                if let subtitle = item.subtitle, !subtitle.isEmpty {
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

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
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

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                image = Image(uiImage: uiImage)
            }
            #endif
        } catch {
            image = nil
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
