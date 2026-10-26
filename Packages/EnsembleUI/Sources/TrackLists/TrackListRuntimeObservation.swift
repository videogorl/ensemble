import Combine
import EnsembleCore
import SwiftUI

private struct TrackListDisplayRatingsRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var trackListDisplayRatingsRevision: UInt64 {
        get { self[TrackListDisplayRatingsRevisionKey.self] }
        set { self[TrackListDisplayRatingsRevisionKey.self] = newValue }
    }
}

/// Centralizes Now Playing projections used by persistent track-list surfaces.
/// The modifier subscribes to narrow publishers without observing the whole
/// view model, so high-churn Now Playing state does not invalidate the caller.
@MainActor
private struct NowPlayingTrackListObservationModifier: ViewModifier {
    @Binding var currentTrackId: String?
    @State private var displayRatingsRevision: UInt64 = 0

    let nowPlayingVM: NowPlayingViewModel
    let lastPlaylistProjection: LastPlaylistProjection

    func body(content: Content) -> some View {
        content
            .environment(\.trackListDisplayRatingsRevision, displayRatingsRevision)
            .onChange(of: nowPlayingVM.currentTrack?.playbackIdentity, initial: true) { _, id in
                if id != currentTrackId {
                    currentTrackId = id
                }
            }
            .onChange(of: nowPlayingVM.ratingProjection.displayRatingsRevision, initial: true) { _, revision in
                if revision != displayRatingsRevision {
                    displayRatingsRevision = revision
                }
            }
            .onChange(of: lastPlaylistProjection.value(from: nowPlayingVM.lastPlaylistTarget), initial: true) { _, value in
                lastPlaylistProjection.update(value)
            }
    }
}

@MainActor
private enum LastPlaylistProjection {
    case title(Binding<String?>)
    case id(Binding<String?>)

    func value(from target: LastPlaylistTarget?) -> String? {
        switch self {
        case .title:
            return target?.title
        case .id:
            return target?.id
        }
    }

    func update(_ value: String?) {
        switch self {
        case .title(let binding), .id(let binding):
            if binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }
    }
}

extension View {
    @MainActor
    func nowPlayingTrackListObservation(
        nowPlayingVM: NowPlayingViewModel,
        currentTrackId: Binding<String?>,
        recentPlaylistTitle: Binding<String?>
    ) -> some View {
        modifier(
            NowPlayingTrackListObservationModifier(
                currentTrackId: currentTrackId,
                nowPlayingVM: nowPlayingVM,
                lastPlaylistProjection: .title(recentPlaylistTitle)
            )
        )
    }

    @MainActor
    func nowPlayingTrackListObservation(
        nowPlayingVM: NowPlayingViewModel,
        currentTrackId: Binding<String?>,
        lastPlaylistTargetId: Binding<String?>
    ) -> some View {
        modifier(
            NowPlayingTrackListObservationModifier(
                currentTrackId: currentTrackId,
                nowPlayingVM: nowPlayingVM,
                lastPlaylistProjection: .id(lastPlaylistTargetId)
            )
        )
    }
}
