import EnsembleCore
import SwiftUI

/// Centralizes the lightweight runtime values every native track list needs to
/// redraw visible rows for download and availability changes.
@MainActor
struct TrackListRuntimeObservationModifier: ViewModifier {
    @Binding var activeDownloadRatingKeys: Set<String>
    @Binding var availabilityGeneration: UInt64

    private let offlineDownloadService = DependencyContainer.shared.offlineDownloadService
    private let trackAvailabilityResolver = DependencyContainer.shared.trackAvailabilityResolver

    func body(content: Content) -> some View {
        content
            .onReceive(offlineDownloadService.$activeDownloadRatingKeys) { keys in
                if keys != activeDownloadRatingKeys {
                    activeDownloadRatingKeys = keys
                }
            }
            .onReceive(trackAvailabilityResolver.$availabilityGeneration) { generation in
                if generation != availabilityGeneration {
                    availabilityGeneration = generation
                }
            }
    }
}

extension View {
    @MainActor
    func trackListRuntimeObservation(
        activeDownloadRatingKeys: Binding<Set<String>>,
        availabilityGeneration: Binding<UInt64>
    ) -> some View {
        modifier(
            TrackListRuntimeObservationModifier(
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                availabilityGeneration: availabilityGeneration
            )
        )
    }
}
