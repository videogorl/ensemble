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

/// Centralizes the lightweight runtime values every native track list needs to
/// redraw visible rows for download and availability changes.
@MainActor
struct TrackListRuntimeObservationModifier: ViewModifier {
    @Binding var activeDownloadTrackIdentities: Set<String>
    @Binding var availabilityGeneration: UInt64

    private let offlineDownloadService = DependencyContainer.shared.offlineDownloadService
    private let trackAvailabilityResolver = DependencyContainer.shared.trackAvailabilityResolver

    func body(content: Content) -> some View {
        content
            .onReceive(offlineDownloadService.$activeDownloadTrackIdentities) { keys in
                if keys != activeDownloadTrackIdentities {
                    activeDownloadTrackIdentities = keys
                }
            }
            .onReceive(trackAvailabilityResolver.$availabilityGeneration) { generation in
                if generation != availabilityGeneration {
                    availabilityGeneration = generation
                }
            }
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
            .onReceive(nowPlayingVM.$currentTrack.map { $0?.playbackIdentity }.removeDuplicates()) { id in
                if id != currentTrackId {
                    currentTrackId = id
                }
            }
            .onReceive(nowPlayingVM.ratingProjection.$displayRatingsRevision.removeDuplicates()) { revision in
                if revision != displayRatingsRevision {
                    displayRatingsRevision = revision
                }
            }
            .onReceive(
                nowPlayingVM.$lastPlaylistTarget
                    .map { lastPlaylistProjection.value(from: $0) }
                    .removeDuplicates()
            ) { value in
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
    func trackListRuntimeObservation(
        activeDownloadTrackIdentities: Binding<Set<String>>,
        availabilityGeneration: Binding<UInt64>
    ) -> some View {
        modifier(
            TrackListRuntimeObservationModifier(
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                availabilityGeneration: availabilityGeneration
            )
        )
    }

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
