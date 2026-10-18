import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared
import Foundation
import EnsembleDomain
import MediaPlayer
import Nuke
#if canImport(QuartzCore)
    import QuartzCore
#endif
#if canImport(UIKit)
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

// The Apple Music side of playback: MusicKit queue starts, stations, and boundary rules.
extension PlaybackService {
    nonisolated static func shouldInferAppleMusicPrevious(
        previousTime: TimeInterval,
        currentTime: TimeInterval,
        restartWasObserved: Bool
    ) -> Bool {
        restartWasObserved
            && previousTime <= previousRestartThreshold
            && currentTime <= 0.75
            && previousTime - currentTime >= 0.25
    }

    nonisolated static func appleMusicQueueItemIDNeedingSynchronization(
        queue: [QueueItem],
        currentQueueIndex: Int,
        playbackState: PlaybackState
    ) -> String? {
        guard queue.indices.contains(currentQueueIndex),
              queue[currentQueueIndex].track.isAppleMusic else { return nil }
        return switch playbackState {
        case .loading, .buffering, .playing, .paused: queue[currentQueueIndex].id
        case .stopped, .failed: nil
        }
    }

    /// At an Apple Music boundary with autoplay on, a station replaces the
    /// continuation and any already-fetched autoplay items (Q1). A Repeat All wrap
    /// is a queue item, not a continuation, so it never starts a station (Q2).
    nonisolated static func appleMusicStationReplacesAdvance(
        _ advance: EnsembleQueueAdvance,
        in queue: [QueueItem]
    ) -> Bool {
        switch advance {
        case .continuation:
            return true
        case let .item(index, wrapped):
            return !wrapped && queue.indices.contains(index) && queue[index].source == .autoplay
        case .repeatCurrent, .endOfQueue, .unavailable:
            return false
        }
    }

    @MainActor
    var isAppleMusicStationActive: Bool {
        #if os(iOS)
            return appleMusicPlaybackController?.isStationActive == true
        #else
            return false
        #endif
    }

    @MainActor
    func handleStationUpcomingChanged(_ tracks: [Track]) {
        guard isAppleMusicStationActive else { return }
        let futureStart = currentQueueIndex + 1
        if futureStart < queue.count { queue.removeSubrange(futureStart...) }
        queue.append(contentsOf: tracks.map { makeQueueItem(track: $0, source: .autoplay) })
        let removedTrackIDs = removeDuplicateFutureAutoplayItemsIfNeeded(
            shouldInvalidateGaplessSchedule: false
        )
        #if os(iOS)
            if #available(iOS 18, *) {
                for trackID in removedTrackIDs {
                    guard let catalogID = tracks.first(where: {
                        $0.playbackIdentity == trackID
                    })?.appleMusicCatalogID else { continue }
                    _ = appleMusicPlaybackController?.removeFirstUpcomingEntry(catalogID: catalogID)
                }
            }
        #endif
        autoplayTracks = queue.dropFirst(currentQueueIndex + 1).compactMap {
            $0.source == .autoplay ? $0.track : nil
        }
        savePlaybackState()
    }

    func synchronizeAppleMusicQueueAfterMutation() {
        #if os(iOS)
            guard #available(iOS 18, *),
                  let queueItemID = Self.appleMusicQueueItemIDNeedingSynchronization(
                      queue: queue,
                      currentQueueIndex: currentQueueIndex,
                      playbackState: playbackState
                  ) else { return }

            appleMusicQueueMutationGeneration &+= 1
            let mutationGeneration = appleMusicQueueMutationGeneration

            Task { @MainActor [weak self] in
                guard let self,
                      mutationGeneration == self.appleMusicQueueMutationGeneration,
                      self.queue.indices.contains(self.currentQueueIndex),
                      self.queue[self.currentQueueIndex].id == queueItemID,
                      self.currentTrack?.isAppleMusic == true else { return }

                if self.appleMusicPlaybackController?.discardUpcomingEntries() == true {
                    EnsembleLogger.debug(
                        "[MusicKitQueue] Discarded stale upcoming entries after logical queue mutation"
                    )
                    return
                }

                self.beginSession()
                self.appleMusicPlaybackController?.stop()
                switch self.playbackState {
                case .loading, .buffering, .playing:
                    await self.playCurrentQueueItem(
                        seekTo: self.currentTime,
                        caller: "queueMutation"
                    )
                case .paused, .stopped, .failed:
                    break
                }
            }
        #endif
    }

    @MainActor
    func startAppleMusicAutoplayStationIfPossible(seed: Track) async -> Bool {
        #if os(iOS)
            guard #available(iOS 18, *),
                  seed.isAppleMusic,
                  syncCoordinator.accountManager.isAppleMusicEnabled else { return false }
            beginSession()
            let generation = sessionGeneration
            let session = PlaybackSessionID(rawValue: generation)
            appleMusicEngineAdapter?.bind(session, startTime: 0)
            do {
                try await appleMusicPlaybackController?.startStation(
                    seed: seed,
                    smartMixEnabled: isSmartMixEnabled,
                    repeatOneEnabled: repeatMode == .one
                )
                guard generation == sessionGeneration,
                      appleMusicPlaybackController?.isStationActive == true,
                      appleMusicPlaybackController?.activeQueueGeneration != nil else { return false }
                recommendationsExhausted = false
                return true
            } catch {
                EnsembleLogger.error("Apple Music autoplay station failed: \(error.localizedDescription)")
                recommendationsExhausted = true
                return false
            }
        #else
            return false
        #endif
    }

    @MainActor
    func setupAppleMusicPlayback() {
        #if os(iOS)
            guard #available(iOS 18, *) else { return }
            guard appleMusicPlaybackController == nil else { return }
            let controller = AppleMusicPlaybackController()
            guard appleMusicPlaybackController == nil else { return }
            let adapter = AppleMusicEngineEventAdapter(controller: controller)
            adapter.onEvent = { [weak self] envelope in
                self?.handleEngineEvent(envelope)
            }
            appleMusicEngineAdapter = adapter
            appleMusicPlaybackController = controller
        #endif
    }

    #if os(iOS)
        @available(iOS 18, *)
        @MainActor
        func playCurrentAppleMusicTrack(
            startTime: TimeInterval?,
            generation: UInt64
        ) async {
            pendingPreBufferTime = nil
            guard queue.indices.contains(currentQueueIndex) else { return }
            let track = queue[currentQueueIndex].track
            guard track.isAppleMusic else { return }

            audioAnalyzer.pauseUpdates()
            currentTrack = track
            updatePlaybackTimes(rawTime: startTime ?? 0)
            waveformHeights = []
            frequencyBands = []
            playbackState = .loading
            updateNowPlayingInfo()

            do {
                setupAppleMusicPlayback()
                guard let controller = appleMusicPlaybackController else {
                    throw AppleMusicSourceError.musicKitPlaybackRequired
                }
                controller.stop()
                let session = PlaybackSessionID(rawValue: generation)
                appleMusicEngineAdapter?.bind(session, startTime: startTime)

                EnsembleLogger.debug(
                    "[ProviderHandoff] phase=beforeApplicationPlay generation=\(generation)"
                        + " track=\(track.playbackIdentity)"
                        + " route=\(currentAudioRouteDescription())"
                )
                try await controller.play(
                    track: track,
                    startTime: startTime,
                    repeatOneEnabled: repeatMode == .one
                )
                guard generation == sessionGeneration,
                      queue.indices.contains(currentQueueIndex),
                      queue[currentQueueIndex].track.playbackIdentity == track.playbackIdentity
                else { return }
                clearItemFailureMarkers()
                playbackState = .playing
                applyPendingSeek()
                updateNowPlayingInfo()
            } catch is CancellationError {
                guard generation == sessionGeneration else { return }
                appleMusicPlaybackController?.stop()
                audioEngine?.stop()
                playbackState = .failed("Apple Music playback was cancelled. Try again.")
                updateNowPlayingInfo()
                endTrackTransitionBackgroundTask(for: generation)
                return
            } catch {
                guard generation == sessionGeneration else { return }
                appleMusicPlaybackController?.stop()
                audioEngine?.stop()
                await handleItemFailure(error.localizedDescription, generation: generation)
            }
        }

    #endif
}
