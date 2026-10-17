import Foundation
import Combine

/// Turns `AudioPlaybackEngine` callbacks into session-stamped engine events.
///
/// The engine stamps each callback with the generation it was given at load,
/// which the service sets to the session's raw value, so the stamp is the
/// session. Events are always delivered asynchronously on the main queue, so an
/// engine command can never re-enter the service. Native-only side channels
/// (buffer pressure, completed stream files) stay on the engine.
final class NativePlaybackEngineAdapter {
    private let engine: AudioPlaybackEngine
    private var progressCancellable: AnyCancellable?
    /// The last item this adapter reported as current, for the polling backstop.
    private var reportedTrackID: String?
    var onEvent: ((PlaybackEngineEventEnvelope) -> Void)?

    init(engine: AudioPlaybackEngine) {
        self.engine = engine
        wire()
    }

    /// Called right before an item is loaded under `session`.
    func willLoad(trackID: String) {
        reportedTrackID = trackID
    }

    private func deliver(_ event: PlaybackEngineEvent, generation: UInt64) {
        guard generation != 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(PlaybackEngineEventEnvelope(
                session: PlaybackSessionID(rawValue: generation),
                engine: .native,
                event: event
            ))
        }
    }

    private func reportItemChange(_ trackID: String, via kind: PlaybackEngineAdvanceKind, generation: UInt64) {
        reportedTrackID = trackID
        deliver(.itemChanged(trackID: trackID, via: kind), generation: generation)
    }

    private func wire() {
        engine.onPlaybackComplete = { [weak self] generation in
            self?.deliver(.ended, generation: generation)
        }
        engine.onTrackAdvance = { [weak self] trackID, generation in
            self?.reportItemChange(trackID, via: .gapless, generation: generation)
        }
        engine.onSmartMixPromote = { [weak self] trackID, generation in
            self?.reportItemChange(trackID, via: .crossfade, generation: generation)
        }
        engine.onSmartMixTransitionActiveChanged = { [weak self] isActive, generation in
            self?.deliver(.transitionActive(isActive), generation: generation)
        }
        engine.onFirstAudibleRender = { [weak self] trackID, generation in
            self?.deliver(.started(trackID: trackID), generation: generation)
        }
        engine.onStreamingRebufferingChanged = { [weak self] isRebuffering, generation in
            self?.deliver(.stalled(isRebuffering), generation: generation)
        }
        engine.onBufferedProgress = { [weak self] trackID, generation, fraction in
            self?.deliver(.buffered(trackID: trackID, fraction: fraction), generation: generation)
        }
        engine.onError = { [weak self] error, _, generation in
            self?.deliver(.failed(error), generation: generation)
        }
        progressCancellable = engine.currentTimeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self, self.engine.isCurrentProgress(progress) else { return }
                self.reconcileCurrentItem(generation: progress.generation)
                self.onEvent?(PlaybackEngineEventEnvelope(
                    session: PlaybackSessionID(rawValue: progress.generation),
                    engine: .native,
                    event: .progress(trackID: progress.trackID, position: progress.time)
                ))
            }
    }

    /// Backstop for a missed advance callback: the engine's own current item is
    /// the truth, so report it once if it differs from what was last reported.
    private func reconcileCurrentItem(generation: UInt64) {
        if engine.hasPromotedSmartMixTransition,
           let incoming = engine.smartMixIncomingTrackId,
           incoming != reportedTrackID {
            reportItemChange(incoming, via: .crossfade, generation: generation)
            return
        }
        guard !engine.isSmartMixTransitionActive,
              let current = engine.currentTrackId,
              let reportedTrackID,
              current != reportedTrackID else { return }
        reportItemChange(current, via: .gapless, generation: generation)
    }
}
