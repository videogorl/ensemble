import EnsembleDomain
import EnsembleWatchCore
import SwiftUI

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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    nowPlayingLink
                }
            }
        }
        .environmentObject(experience)
        .environmentObject(remoteSession)
        .onAppear {
            experience.start()
        }
    }

    private var nowPlayingLink: some View {
        NavigationLink(destination: WatchNowPlayingView()) {
            Image(systemName: "music.note")
        }
        .accessibilityLabel("Now Playing")
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
                    VStack(spacing: 6) {
                        ForEach(snapshot.pins) { item in
                            NavigationLink(destination: WatchMediaDetailView(item: item)) {
                                WatchMediaRow(item: item)
                            }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: WatchNowPlayingView()) {
                    Image(systemName: "music.note")
                }
                .accessibilityLabel("Now Playing")
            }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: WatchNowPlayingView()) {
                    Image(systemName: "music.note")
                }
                .accessibilityLabel("Now Playing")
            }
        }
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

private struct WatchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}

private struct WatchMediaRow: View {
    let item: EnsembleMediaSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.systemImage)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 20)

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
    }
}

private struct WatchTrackRow: View {
    let track: EnsembleTrack

    var body: some View {
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
