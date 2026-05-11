import EnsembleDomain
import EnsembleWatchCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WatchRootView: View {
    @StateObject private var experience = WatchExperienceModel()
    @StateObject private var remoteSession = WatchSessionModel()

    var body: some View {
        NavigationView {
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
        .environmentObject(experience)
        .environmentObject(remoteSession)
        .onAppear {
            experience.start()
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = experience.catalogSnapshot, !snapshot.pins.isEmpty {
                    WatchSectionHeader(title: "Pins")
                    LazyVGrid(columns: WatchPinsGrid.columns, spacing: WatchPinsGrid.spacing) {
                        ForEach(snapshot.pins) { item in
                            NavigationLink(destination: WatchMediaDetailView(item: item)) {
                                WatchPinArtworkTile(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                        }
                    }
                }

                WatchSectionHeader(title: "Library")
                VStack(spacing: 6) {
                    ForEach(EnsembleLibraryCategory.allCases) { category in
                        NavigationLink(destination: WatchCategoryView(category: category)) {
                            Label(category.title, systemImage: category.systemImage)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Button {
                    experience.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                NavigationLink(destination: WatchSourceSettingsView()) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)

                Text(experience.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
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
    @EnvironmentObject private var experience: WatchExperienceModel
    let item: EnsembleMediaSummary

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(3)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                if experience.detailTracks.isEmpty {
                    Text(experience.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(experience.detailTracks) { track in
                        Button {
                            experience.play(track)
                        } label: {
                            WatchTrackRow(track: track)
                        }
                    }
                }
            }
        }
        .navigationTitle(item.kind.title)
        .watchNowPlayingToolbar()
        .onAppear {
            experience.tracks(for: item)
        }
    }
}

private struct WatchNowPlayingView: View {
    @EnvironmentObject private var experience: WatchExperienceModel
    @EnvironmentObject private var remoteSession: WatchSessionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    targetButton(title: "Watch", target: .local)
                    targetButton(title: "Phone", target: .remote)
                }

                if experience.playbackTarget == .local {
                    localNowPlaying
                } else {
                    remoteNowPlaying
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .navigationTitle("Now Playing")
    }

    private var localNowPlaying: some View {
        VStack(spacing: 8) {
            Image(systemName: experience.playback.isPlaying ? "music.note.house.fill" : "music.note.house")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text(experience.playback.currentTrack?.title ?? "Not Playing")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text(localSubtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            ProgressView(value: experience.playback.progress)

            HStack {
                Text(experience.playback.currentTime.ensembleWatchClockText)
                Spacer()
                Text((experience.playback.currentTrack?.duration ?? 0).ensembleWatchClockText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)

            Button {
                experience.playback.togglePlayPause()
            } label: {
                Image(systemName: experience.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(experience.playback.currentTrack == nil)

            if let error = experience.playback.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func targetButton(title: String, target: EnsemblePlaybackTarget) -> some View {
        if experience.playbackTarget == target {
            Button {
                experience.playbackTarget = target
            } label: {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                experience.playbackTarget = target
            } label: {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var remoteNowPlaying: some View {
        VStack(spacing: 8) {
            Image(systemName: remoteSession.isPlaying ? "iphone.radiowaves.left.and.right" : "iphone")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text(remoteSession.currentTrackTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text(remoteSession.currentTrackSubtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            ProgressView(value: remoteSession.progress)

            HStack {
                Text(remoteSession.elapsedText)
                Spacer()
                Text(remoteSession.remainingText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)

            HStack(spacing: 14) {
                Button {
                    remoteSession.send(.previous)
                } label: {
                    Image(systemName: "backward.fill")
                }

                Button {
                    remoteSession.send(.togglePlayPause)
                } label: {
                    Image(systemName: remoteSession.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    remoteSession.send(.next)
                } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .disabled(remoteSession.isSendingCommand)

            HStack(spacing: 10) {
                Button {
                    remoteSession.send(.toggleShuffle)
                } label: {
                    Image(systemName: "shuffle")
                }

                Button {
                    remoteSession.send(.cycleRepeatMode)
                } label: {
                    Image(systemName: remoteSession.snapshot?.repeatMode.systemImage ?? "repeat")
                }
            }
            .disabled(remoteSession.isSendingCommand)
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

private extension View {
    @ViewBuilder
    func watchNowPlayingToolbar() -> some View {
        if #available(watchOS 10.0, *) {
            toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchNowPlayingToolbarLink()
                }
            }
        } else {
            overlay(alignment: .topTrailing) {
                WatchNowPlayingToolbarLink()
                    .padding(.top, 2)
                    .padding(.trailing, 4)
            }
        }
    }
}

private struct WatchNowPlayingToolbarLink: View {
    var body: some View {
        NavigationLink(destination: WatchNowPlayingView()) {
            Image(systemName: "music.note")
                .font(.headline)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Now Playing")
    }
}

private struct WatchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
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

private extension WatchExperienceModel {
    var artworkContextID: String {
        libraries.map(\.sourceKey).sorted().joined(separator: "|")
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

    var systemImage: String {
        switch self {
        case .album: return "square.stack"
        case .artist: return "music.mic"
        case .playlist: return "music.note.list"
        case .track: return "music.note"
        }
    }
}
