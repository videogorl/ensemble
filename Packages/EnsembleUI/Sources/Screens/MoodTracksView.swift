import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct MoodTracksView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    let mood: Mood
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @StateObject private var viewModel: SearchViewModel
    @State private var moodTracks: [Track] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var playlistPickerPayload: PlaylistPickerPayload?

    // Targeted observation state (pattern from MediaDetailView)
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var currentTrackId: String?

    public init(mood: Mood, nowPlayingVM: NowPlayingViewModel) {
        self.mood = mood
        self.nowPlayingVM = nowPlayingVM
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed background gradient
            backgroundGradient
                .ignoresSafeArea()

            #if os(iOS)
            // UIKit table with header/footer, matching MediaDetailView pattern
            MediaTrackList(
                tracks: moodTracks,
                showArtwork: true,
                showTrackNumbers: false,
                showAlbumName: true,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                managesOwnScrolling: true,
                bottomContentInset: 140,
                tableHeaderContent: AnyView(moodHeader),
                tableFooterContent: AnyView(moodFooter),
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
            ) { track, index in
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: index)
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            #else
            ScrollView {
                VStack(spacing: 0) {
                    moodHeader
                    if isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else if let error = error {
                        errorView(error)
                    } else if moodTracks.isEmpty {
                        emptyView
                    } else {
                        TrackListView(
                            tracks: moodTracks,
                            showArtwork: true,
                            showTrackNumbers: false,
                            nowPlayingVM: nowPlayingVM
                        ) { track, index in
                            if !nowPlayingVM.isAutoplayEnabled {
                                nowPlayingVM.toggleAutoplay()
                            }
                            nowPlayingVM.play(tracks: moodTracks, startingAt: index)
                        }
                    }
                }
            }
            #endif
        }
        .navigationTitle(mood.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadTracks()
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.id
            if id != currentTrackId { currentTrackId = id }
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

    // MARK: - Table Header (scrolls with tracks)

    private var moodHeader: some View {
        VStack(spacing: 0) {
            headerView
            actionButtons
        }
    }

    // MARK: - Table Footer (loading/error/empty states)

    @ViewBuilder
    private var moodFooter: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        } else if let error = error {
            VStack(spacing: 12) {
                Text("Failed to load tracks")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry") {
                    Task {
                        await loadTracks()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        } else if moodTracks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No tracks found")
                    .font(.headline)
                Text("for \"\(mood.title)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
    }

    #if !os(iOS)
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Failed to load tracks")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Retry") {
                Task { await loadTracks() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No tracks found")
                .font(.headline)
            Text("for \"\(mood.title)\"")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
    #endif

    // MARK: - Header Views

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                moodColor.opacity(0.6),
                moodColor.opacity(0.3)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 400)
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

    private var headerView: some View {
        VStack(spacing: 16) {
            // Centered mood icon
            ZStack {
                Circle()
                    .fill(moodColor.opacity(0.2))
                    .frame(width: 140, height: 140)

                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundColor(moodColor)
            }
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)

            // Mood title
            Text(mood.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                if nowPlayingVM.isShuffleEnabled {
                    nowPlayingVM.toggleShuffle()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: 0)
            }) {
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

            Button(action: {
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                if !nowPlayingVM.isShuffleEnabled {
                    nowPlayingVM.toggleShuffle()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: 0)
            }) {
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
    }

    // MARK: - Helpers

    /// Generate a deterministic color based on mood name
    private var moodColor: Color {
        let colors: [Color] = [
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo
        ]

        let hash = mood.title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return colors[abs(hash) % colors.count]
    }

    private func loadTracks() async {
        isLoading = true
        error = nil

        var allTracks: [Track] = []
        var trackMap: [String: Track] = [:]  // For deduplication by ratingKey

        // Fetch mood tracks from all enabled libraries
        let accountManager = DependencyContainer.shared.accountManager

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                for library in enabledLibraries {
                    do {
                        let plexTracks = try await client.getTracksByMood(sectionKey: library.key, moodKey: mood.key)

                        // Create composite key for this track from this library
                        let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"

                        for plexTrack in plexTracks {
                            // Create track with explicit sourceKey including plex: prefix
                            let track = Track(from: plexTrack, sourceKey: sourceKey)

                            // Dedup by ratingKey - keep first occurrence
                            if trackMap[track.id] == nil {
                                trackMap[track.id] = track
                                allTracks.append(track)
                            }
                        }
                    } catch {
                        // Continue to next library if this one fails
                        continue
                    }
                }
            }
        }

        moodTracks = allTracks

        if moodTracks.isEmpty {
            error = "No tracks found for '\(mood.title)'"
        }

        isLoading = false
    }
}
