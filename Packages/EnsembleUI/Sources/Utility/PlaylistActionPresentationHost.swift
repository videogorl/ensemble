import EnsembleCore
import SwiftUI

/// Request model for presenting the shared playlist picker from any media surface.
public struct PlaylistActionPresentationRequest: Identifiable {
    public let id = UUID()
    public let tracks: [Track]
    public let title: String
    public let createsPlaylistAcrossSources: Bool

    public init?(
        tracks: [Track],
        title: String = "Add to Playlist",
        createsPlaylistAcrossSources: Bool = false
    ) {
        guard !tracks.isEmpty else { return nil }
        self.tracks = tracks
        self.title = title
        self.createsPlaylistAcrossSources = createsPlaylistAcrossSources
    }
}

/// Shared presentation and quick-action helpers for add-to-playlist flows.
@MainActor
public enum PlaylistActionPresentationHost {
    public static func request(
        for tracks: [Track],
        title: String = "Add to Playlist",
        createsPlaylistAcrossSources: Bool = false
    ) -> PlaylistActionPresentationRequest? {
        PlaylistActionPresentationRequest(
            tracks: tracks,
            title: title,
            createsPlaylistAcrossSources: createsPlaylistAcrossSources
        )
    }

    public static func recentPlaylistTitle(
        for tracks: [Track],
        nowPlayingVM: NowPlayingViewModel
    ) -> String? {
        guard let target = nowPlayingVM.lastPlaylistTarget else { return nil }
        return nowPlayingVM.compatibleTrackCount(
            tracks,
            forServerSourceKey: target.sourceCompositeKey
        ) > 0 ? target.title : nil
    }

    public static func recentPlaylistTitle(
        for tracks: [Track],
        target: Playlist?,
        nowPlayingVM: NowPlayingViewModel
    ) -> String? {
        guard let target else { return nil }
        return nowPlayingVM.compatibleTrackCount(tracks, for: target) > 0 ? target.title : nil
    }

    public static func resolveRecentPlaylistTarget(
        for tracks: [Track],
        nowPlayingVM: NowPlayingViewModel
    ) async -> Playlist? {
        await nowPlayingVM.resolveLastPlaylistTarget(for: tracks)
    }

    public static func addToRecentPlaylist(
        _ tracks: [Track],
        nowPlayingVM: NowPlayingViewModel
    ) {
        guard recentPlaylistTitle(for: tracks, nowPlayingVM: nowPlayingVM) != nil else { return }
        Task {
            guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: tracks) else { return }
            _ = try? await nowPlayingVM.addTracks(tracks, to: playlist)
        }
    }

    public static func addToRecentPlaylist(
        _ tracks: [Track],
        target: Playlist?,
        nowPlayingVM: NowPlayingViewModel
    ) {
        guard recentPlaylistTitle(for: tracks, target: target, nowPlayingVM: nowPlayingVM) != nil,
              let target else { return }
        Task {
            _ = try? await nowPlayingVM.addTracks(tracks, to: target)
        }
    }
}

private struct PlaylistActionPresentationModifier: ViewModifier {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @Binding var request: PlaylistActionPresentationRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { request in
                PlaylistPickerSheet(
                    nowPlayingVM: nowPlayingVM,
                    tracks: request.tracks,
                    title: request.title,
                    createsPlaylistAcrossSources: request.createsPlaylistAcrossSources
                )
            }
    }
}

private struct RecentPlaylistTargetObservationModifier: ViewModifier {
    let nowPlayingVM: NowPlayingViewModel
    let tracks: [Track]
    let isEnabled: Bool
    @Binding var target: Playlist?
    @State private var lastPlaylistTargetID: String?

    private var refreshKey: String {
        let trackIDs = tracks.map(\.playbackIdentity).joined(separator: "|")
        return "\(isEnabled):\(trackIDs)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: refreshKey) {
                lastPlaylistTargetID = nowPlayingVM.lastPlaylistTarget?.id
                await refreshTarget()
            }
            .onReceive(nowPlayingVM.lastPlaylistTargetPublisher) { playlistTarget in
                guard playlistTarget?.id != lastPlaylistTargetID else { return }
                lastPlaylistTargetID = playlistTarget?.id
                Task { @MainActor in await refreshTarget() }
            }
    }

    @MainActor
    private func refreshTarget() async {
        guard isEnabled, !tracks.isEmpty else {
            target = nil
            return
        }
        target = await PlaylistActionPresentationHost.resolveRecentPlaylistTarget(
            for: tracks,
            nowPlayingVM: nowPlayingVM
        )
    }
}

public extension View {
    func playlistActionPresentation(
        request: Binding<PlaylistActionPresentationRequest?>,
        nowPlayingVM: NowPlayingViewModel
    ) -> some View {
        modifier(
            PlaylistActionPresentationModifier(
                nowPlayingVM: nowPlayingVM,
                request: request
            )
        )
    }

    func recentPlaylistTargetObservation(
        nowPlayingVM: NowPlayingViewModel,
        tracks: [Track],
        isEnabled: Bool = true,
        target: Binding<Playlist?>
    ) -> some View {
        modifier(
            RecentPlaylistTargetObservationModifier(
                nowPlayingVM: nowPlayingVM,
                tracks: tracks,
                isEnabled: isEnabled,
                target: target
            )
        )
    }
}
