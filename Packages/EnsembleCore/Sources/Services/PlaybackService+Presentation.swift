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

// Playback time, presentation latency, waveform, visualizer, and instrumental mode.
extension PlaybackService {
    nonisolated static func effectiveDuration(
        metadataDuration: TimeInterval,
        itemDuration: TimeInterval?
    ) -> TimeInterval {
        let baseDuration = max(0, metadataDuration)

        guard let itemDuration else { return baseDuration }
        guard itemDuration.isFinite else { return baseDuration }
        guard itemDuration > 0 else { return baseDuration }
        // Defensive bound for malformed media durations.
        guard itemDuration < 24 * 60 * 60 else { return baseDuration }

        // If metadata is available and AVPlayer reports significantly longer duration,
        // trust metadata. VBR MP3 files from PMS transcode cause AVPlayer to wildly
        // overestimate duration (e.g., 195s → 270s) due to missing XING/LAME headers.
        // Only allow AVPlayer to extend past metadata by up to 10%.
        if baseDuration > 0 && itemDuration > baseDuration * 1.1 {
            return baseDuration
        }

        // For small differences or when AVPlayer is shorter, take the max so the
        // scrubber doesn't complete early while audio is still playing.
        return max(baseDuration, itemDuration)
    }

    func visualizerPlan(
        for context: PlaybackLaunchCoordinator.VisualizerLoadContext
    ) -> PlaybackLaunchCoordinator.VisualizerPlan? {
        PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: isVisualizerEnabled,
            isInstrumentalModeActive: isInstrumentalModeActive,
            processorCount: processorCount,
            context: context
        )
    }

    func enqueueVisualizerTimelineLoad(
        track: Track,
        fileURL: URL,
        plan: PlaybackLaunchCoordinator.VisualizerPlan
    ) {
        let analyzer = audioAnalyzer
        let trackIdentity = track.playbackIdentity
        let startDelayNanoseconds = plan.startDelayNanoseconds

        EnsembleLogger.debug(
            "[Visualizer] Dispatching loadTimeline for '\(track.title)', url=\(fileURL.lastPathComponent), isFile=\(fileURL.isFileURL)"
        )
        Task.detached {
            if startDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: startDelayNanoseconds)
                guard !Task.isCancelled else { return }
            }
            await analyzer.loadTimeline(
                for: trackIdentity,
                fileURL: fileURL,
                priority: plan.priority,
                throttled: plan.throttled
            )
        }
    }

    func generateWaveform(for trackIdentity: String) {
        guard currentTrack?.isAppleMusic != true else {
            waveformHeights = []
            return
        }
        EnsembleLogger.debug("🎵 Generating waveform for track: \(trackIdentity)")

        // Generate fallback waveform immediately for instant feedback
        let fallbackWaveform = generateFallbackWaveform(for: trackIdentity)
        Task { @MainActor in
            self.waveformHeights = fallbackWaveform
            EnsembleLogger.debug("🎵 Using fallback waveform (\(fallbackWaveform.count) samples)")
        }

        // Try to fetch real waveform data from Plex server asynchronously (if sonic analysis has been performed)
        Task { @MainActor in
            guard let track = self.currentTrack else { return }

            // Skip waveform fetch if no stream ID — fallback waveform is already set above
            guard let streamId = track.streamId else { return }

            if let identity = MediaSourceIdentity.parse(track.sourceCompositeKey),
               let apiClient = self.syncCoordinator.accountManager.makeAPIClient(
                   accountId: identity.accountId,
                   serverId: identity.serverId
               ) {
                do {
                    // Attempt to fetch loudness timeline from Plex using correct endpoint
                    if let timeline = try await apiClient.getLoudnessTimeline(forStreamId: streamId, subsample: 128),
                       let loudness = timeline.loudness,
                       !loudness.isEmpty
                    {
                        // Normalize loudness values to 0.0-1.0 range for visualization
                        let normalizedHeights = self.normalizeLoudnessData(loudness)
                        self.waveformHeights = normalizedHeights
                        EnsembleLogger.debug("✅ Replaced fallback with real waveform data from Plex (\(normalizedHeights.count) samples)")
                        return
                    }
                } catch {
                    EnsembleLogger.debug("ℹ️ Could not fetch Plex waveform data (using fallback): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Normalize Plex loudness data to 0.0-1.0 range for visualization
    /// Applies aggressive contrast enhancement for dramatic Plexamp-style waveforms
    func normalizeLoudnessData(_ loudness: [Double]) -> [Double] {
        guard !loudness.isEmpty else { return [] }

        // Find min and max loudness values
        let minLoudness = loudness.min() ?? 0
        let maxLoudness = loudness.max() ?? 1
        let range = maxLoudness - minLoudness

        guard range > 0 else {
            // If all values are the same, return middle height
            return Array(repeating: 0.6, count: loudness.count)
        }

        // Normalize to 0.0-1.0 first
        let normalized = loudness.map { ($0 - minLoudness) / range }

        // Apply contrast enhancement using power curve
        // Exponent > 1.0 expands the range, making quiet sections quieter and loud sections stand out
        let contrastExponent = 1.5
        let enhanced = normalized.map { pow($0, contrastExponent) }

        // Map to 0.1-1.0 range for maximum visual impact
        // Lower floor allows for more dramatic height variation
        return enhanced.map { 0.1 + ($0 * 0.9) }
    }

    /// Generate fallback pseudo-random waveform when Plex data is unavailable
    func generateFallbackWaveform(for ratingKey: String) -> [Double] {
        // Simple seeded random to make it consistent for the same track
        var seed = UInt64(truncatingIfNeeded: Int64(ratingKey.hashValue))
        func nextRandom() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max)
        }

        // Generate ~120 samples for detail
        let count = 120
        var heights: [Double] = []

        // Generate a dramatic waveform with extreme variation (Plexamp-style)
        for i in 0 ..< count {
            let progress = Double(i) / Double(count)

            // Create multiple peaks throughout the track with more variation
            let primaryWave = sin(progress * .pi) // Main envelope
            let secondaryWave = sin(progress * .pi * 4.5) * 0.5 // Add variation
            let tertiaryWave = sin(progress * .pi * 12) * 0.3 // Add micro variation

            let envelope = max(0.1, primaryWave + secondaryWave + tertiaryWave)

            // Create dramatic height differences
            let base = 0.4 * envelope
            let variance = 0.6 * nextRandom() // High variance for more drama

            // Apply power curve for contrast similar to real data
            let raw = max(0.0, min(1.0, base + variance))
            let enhanced = pow(raw, 1.5) // Contrast enhancement

            heights.append(0.1 + (enhanced * 0.9)) // Match real data range
        }

        return heights
    }

    func presentationTime(for rawTime: TimeInterval) -> TimeInterval {
        Self.resolvedPresentationTime(
            rawTime: rawTime,
            playbackState: playbackState,
            effectiveLatency: effectivePresentationLatency
        )
    }

    func updatePlaybackTimes(rawTime: TimeInterval) {
        guard rawTime.isFinite else { return }
        if rawTime < currentTime { playbackTimelineRevision &+= 1 }
        let clampedRawTime = max(0, rawTime)
        currentTime = clampedRawTime
        presentationTime = presentationTime(for: clampedRawTime)
    }

    func refreshPresentationTime() {
        presentationTime = presentationTime(for: currentTime)
        let syncedPresentationTime = presentationTime
        Task { @MainActor [audioAnalyzer] in
            audioAnalyzer.updatePlaybackPosition(syncedPresentationTime)
        }
    }

    func refreshPresentationLatencyEstimate() {
        #if os(iOS) || os(tvOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            let hasAirPlay = outputs.contains { $0.portType == .airPlay }
            let hasBluetooth = outputs.contains {
                $0.portType == .bluetoothA2DP
                    || $0.portType == .bluetoothLE
                    || $0.portType == .bluetoothHFP
            }

            presentationRouteKind = Self.inferPresentationRouteKind(
                hasAirPlay: hasAirPlay,
                hasBluetooth: hasBluetooth,
                isScreenMirroringActive: isScreenMirroringActive
            )
            isExternalPlaybackActive = presentationRouteKind != .builtInOrWired
            effectivePresentationLatency = Self.estimatedPresentationLatency(
                routeKind: presentationRouteKind,
                reportedOutputLatency: session.outputLatency,
                ioBufferDuration: session.ioBufferDuration
            )
            refreshPresentationTime()
            EnsembleLogger.debug(
                "[Playback] presentation route=\(String(describing: presentationRouteKind)) "
                    + "latency=\(String(format: "%.3f", effectivePresentationLatency))s "
                    + "reported=\(String(format: "%.3f", session.outputLatency))s "
                    + "ioBuffer=\(String(format: "%.3f", session.ioBufferDuration))s"
            )
        #else
            presentationRouteKind = .builtInOrWired
            effectivePresentationLatency = 0
            isExternalPlaybackActive = false
            refreshPresentationTime()
        #endif
    }

    /// Toggle instrumental mode (vocal attenuation) via AudioPlaybackEngine's
    /// inline AUSoundIsolation effect. No engine switching needed — the effect
    /// is toggled in the existing audio graph.
    public func setInstrumentalMode(_ enabled: Bool) {
        guard InstrumentalModeCapability.isSupported else { return }
        guard enabled != isInstrumentalModeActive else { return }
        guard audioEngine != nil else { return }

        do {
            // Set IO buffer preference BEFORE toggling isolation. wireIsolationIntoGraph()
            // stops and restarts the engine, and the restart picks up the new buffer size.
            // A larger buffer gives AUSoundIsolation enough headroom to complete its
            // neural-network pass even when CPU is busy with SwiftUI layout.
            #if !os(macOS)
                let session = AVAudioSession.sharedInstance()
                let preferredDuration: TimeInterval = enabled
                    ? AudioPlaybackEngine.instrumentalIsolationPreferredIOBufferDuration
                    : AudioPlaybackEngine.standardPreferredIOBufferDuration
                try? session.setPreferredIOBufferDuration(preferredDuration)
            #endif

            try audioEngine?.setIsolationEnabled(enabled)
            isInstrumentalModeActive = enabled

            #if !os(macOS) && DEBUG
                EnsembleLogger.debug("[Playback] IO buffer duration: preferred=\(preferredDuration), actual=\(AVAudioSession.sharedInstance().ioBufferDuration)")
            #endif

            EnsembleLogger.playback("INSTRUMENTAL: \(enabled ? "enabled" : "disabled")")
        } catch {
            EnsembleLogger.playback("INSTRUMENTAL: toggle failed -- \(error.localizedDescription)")
        }
    }

    /// Bridge pre-computed frequency bands from the analyzer to the published property.
    /// Works during AirPlay since the visualizer is decoupled from the audio pipeline.
    func setupAudioAnalyzer() {
        audioAnalyzerCancellable = MainActor.assumeIsolated {
            audioAnalyzer.frequencyBandsPublisher
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] bands in
            self?.frequencyBands = bands
        }
    }

    /// React to visualizer setting changes without coupling UserDefaults
    /// observation to playback side effects.
    func handleVisualizerSettingChanged(_ isEnabled: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Keep the analyzer's timer gate in sync so it stops/starts the 30Hz timer
            self.audioAnalyzer.visualizationEnabled = isEnabled

            // Only act when toggled ON during active playback
            guard isEnabled, self.playbackState == .playing,
                  let track = self.currentTrack,
                  let fileURL = self.getCachedFileURL(for: track.playbackIdentity) else { return }

            EnsembleLogger.debug("[Visualizer] Setting toggled ON mid-song — loading timeline for '\(track.title)'")
            if let plan = self.visualizerPlan(for: .userVisibleToggle) {
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
            self.audioAnalyzer.activateTimeline(for: track.playbackIdentity)
            self.audioAnalyzer.resumeUpdates()
        }
    }

    /// Update the pre-computed visualizer's playback position.
    /// Called from scrubber drag gesture for instant visual feedback.
    @MainActor
    public func updateVisualizerPosition(_ time: TimeInterval) {
        audioAnalyzer.updatePlaybackPosition(time)
    }

    public func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool) {
        audioAnalyzer.setVisualizationConsumer(consumer, isVisible: isVisible)
    }
}
