import Foundation

#if os(iOS)
    /// Turns `AppleMusicPlaybackControlling` callbacks into session-stamped engine events.
    ///
    /// The controller stamps callbacks with its own queue generation; only those from
    /// its active queue pass, and they carry the session the service bound before it
    /// started that queue. MusicKit consumes the system Previous command, so the
    /// adapter infers it from an observed restart and reports `externalPrevious`
    /// instead of a plain rewind. It never reports stalls or buffering, which
    /// MusicKit does not expose.
    @MainActor
    final class AppleMusicEngineEventAdapter {
        private let controller: AppleMusicPlaybackControlling
        private var session: PlaybackSessionID?
        private var lastPosition: TimeInterval = 0
        private var restartObservedGeneration: UInt64?
        var onEvent: ((PlaybackEngineEventEnvelope) -> Void)?

        init(controller: AppleMusicPlaybackControlling) {
            self.controller = controller
            wire()
        }

        /// Whether MusicKit will continue into another item without a service load.
        var hasContinuousSuccessor: Bool {
            controller.isStationActive || controller.hasQueuedSuccessor || controller.isRepeatOneEnabled
        }

        /// Called right before the controller starts a queue for `session`.
        func bind(_ session: PlaybackSessionID, startTime: TimeInterval?) {
            self.session = session
            lastPosition = startTime ?? 0
            restartObservedGeneration = nil
        }

        /// A seek is not a restart; forget any half-observed Previous.
        func noteSeek(to time: TimeInterval) {
            lastPosition = time
            restartObservedGeneration = nil
        }

        private func deliver(_ event: PlaybackEngineEvent, queueGeneration: UInt64) {
            guard let session, controller.activeQueueGeneration == queueGeneration else { return }
            onEvent?(PlaybackEngineEventEnvelope(session: session, engine: .appleMusic, event: event))
        }

        private func wire() {
            controller.onTrackChanged = { [weak self] identity, generation in
                self?.lastPosition = 0
                self?.deliver(.itemChanged(trackID: identity, via: .engineOwned), queueGeneration: generation)
            }
            controller.onTimeChanged = { [weak self] time, generation in
                self?.observe(time: time, queueGeneration: generation)
            }
            controller.onEnded = { [weak self] generation in
                self?.deliver(.ended, queueGeneration: generation)
            }
            controller.onPaused = { [weak self] generation in
                self?.deliver(.externallyPaused, queueGeneration: generation)
            }
            controller.onResumed = { [weak self] generation in
                self?.deliver(.externallyResumed, queueGeneration: generation)
            }
            controller.onDynamicTrack = { [weak self] track, generation in
                self?.lastPosition = 0
                self?.deliver(
                    .itemChanged(trackID: track.playbackIdentity, via: .station(track)),
                    queueGeneration: generation
                )
            }
            controller.onTrackMetadataChanged = { [weak self] track, generation in
                self?.deliver(.metadataChanged(track), queueGeneration: generation)
            }
            controller.onDynamicQueueChanged = { [weak self] tracks, generation in
                self?.deliver(.upcomingChanged(tracks), queueGeneration: generation)
            }
        }

        private func observe(time: TimeInterval, queueGeneration: UInt64) {
            guard time.isFinite, time >= 0,
                  session != nil,
                  controller.activeQueueGeneration == queueGeneration else { return }
            let threshold = PlaybackService.previousRestartThreshold
            let hasSuccessor = hasContinuousSuccessor
            if hasSuccessor || time > threshold {
                restartObservedGeneration = nil
            }
            if !hasSuccessor, lastPosition > threshold, time <= 0.75 {
                restartObservedGeneration = queueGeneration
            }
            if !hasSuccessor,
               PlaybackService.shouldInferAppleMusicPrevious(
                   previousTime: lastPosition,
                   currentTime: time,
                   restartWasObserved: restartObservedGeneration == queueGeneration
               ) {
                restartObservedGeneration = nil
                EnsembleLogger.debug("[Handoff] inferred Apple Music previous command")
                deliver(.externalPrevious, queueGeneration: queueGeneration)
                return
            }
            lastPosition = time
            deliver(.progress(trackID: nil, position: time), queueGeneration: queueGeneration)
        }
    }
#endif
