import Foundation

/// Routes playback timeline and scrobble calls through the exact source provider.
/// Playback reporting must not fall back to a different source because duplicate
/// rating keys can exist across Plex libraries or servers.
@MainActor
struct SyncPlaybackReportingController {
    func reportTimeline(
        track: Track,
        state: String,
        time: TimeInterval,
        providers: [String: MusicSourceSyncProvider]
    ) async throws {
        guard let provider = provider(for: track, providers: providers) else { return }

        try await provider.reportTimeline(
            ratingKey: track.id,
            key: "/library/metadata/\(track.id)",
            state: state,
            time: Self.milliseconds(from: time),
            duration: Self.milliseconds(from: track.duration)
        )
    }

    func scrobble(
        track: Track,
        providers: [String: MusicSourceSyncProvider]
    ) async throws {
        guard let provider = provider(for: track, providers: providers) else { return }

        try await provider.scrobble(ratingKey: track.id)
    }

    static func milliseconds(from seconds: TimeInterval) -> Int {
        Int(seconds * 1000)
    }

    private func provider(
        for track: Track,
        providers: [String: MusicSourceSyncProvider]
    ) -> MusicSourceSyncProvider? {
        SyncProviderResolver(providers: providers)
            .resolve(sourceKey: track.sourceCompositeKey, allowFallback: false)?
            .provider
    }
}
