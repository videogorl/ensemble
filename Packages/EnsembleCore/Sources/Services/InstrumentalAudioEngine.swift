import AudioToolbox
import AVFoundation
import Combine

/// Isolated AVAudioEngine wrapper that removes vocals via vocal subtraction.
/// Completely separate from the AVQueuePlayer path -- used only when instrumental mode is active.
///
/// Vocal subtraction technique:
///   AUSoundIsolation extracts vocals (soundToIsolate=1, wetDry=100).
///   We mix the original audio with the phase-inverted vocal extraction.
///   original + (-vocals) = instrumentals.
///
/// Audio graph:
/// ```
///                    ┌──> AUSoundIsolation ──> vocalsMixer (volume = -1) ──┐
/// playerNode ──split─┤                                                     ├──> mainMixer ──> output
///                    └──> originalMixer (volume = 1) ─────────────────────┘
/// ```
public final class InstrumentalAudioEngine {
    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isolationEffect: AVAudioUnitEffect?
    /// Mixer node for the phase-inverted vocal path (volume = -1)
    private let vocalsMixer = AVAudioMixerNode()
    /// Mixer node for the original (unprocessed) audio path
    private let originalMixer = AVAudioMixerNode()
    private var audioFile: AVAudioFile?

    /// Frame offset from which the current segment was scheduled
    private var seekFrameOffset: AVAudioFramePosition = 0
    /// Whether the engine was playing when last paused (for resume logic)
    private var wasPlaying = false
    /// Generation counter incremented on each schedule -- suppresses stale completions
    /// from playerNode.stop() during seek/stop (which fires all pending completion handlers)
    private var scheduleGeneration: UInt64 = 0

    /// Current playback time, updated at ~10Hz
    let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private var timeUpdateTimer: DispatchSourceTimer?

    /// Fires when the scheduled audio segment finishes (for auto-advance)
    var onPlaybackComplete: (() -> Void)?

    private var isSetUp = false
    private var sampleRate: Double = 44100

    // MARK: - Setup

    /// Build the dual-path vocal subtraction audio graph
    func setup() throws {
        guard !isSetUp else { return }

        // Create AUSoundIsolation effect
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x766F6973, // 'vois' -- kAudioUnitSubType_AUSoundIsolation
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &desc) != nil else {
            throw InstrumentalEngineError.soundIsolationUnavailable
        }

        let effect = AVAudioUnitEffect(audioComponentDescription: desc)
        isolationEffect = effect

        // Configure AUSoundIsolation to output isolated vocals:
        //   Address 0 "Wet/Dry Mix": 100 = fully processed (vocals only)
        //   Address 1 "Sound to Isolate": 1.0 = isolate vocals
        let paramTree = effect.auAudioUnit.parameterTree
        paramTree?.parameter(withAddress: 0)?.value = 100.0
        paramTree?.parameter(withAddress: 1)?.value = 1.0

        // Attach all nodes
        engine.attach(playerNode)
        engine.attach(effect)
        engine.attach(vocalsMixer)
        engine.attach(originalMixer)

        // Build the dual-path graph using the default engine format initially.
        // load() will reconnect with the file's actual format.
        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        connectGraph(format: format)

        // Phase-invert the vocals path: original + (-vocals) = instrumentals
        vocalsMixer.outputVolume = -1.0
        originalMixer.outputVolume = 1.0

        isSetUp = true

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Vocal subtraction graph built (original - vocals = instrumentals)")
        #endif
    }

    /// Connect (or reconnect) the dual-path graph with the given audio format
    private func connectGraph(format: AVAudioFormat) {
        guard let effect = isolationEffect else { return }
        let mainMixer = engine.mainMixerNode

        // Disconnect everything first to avoid duplicate connections
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(effect)
        engine.disconnectNodeOutput(vocalsMixer)
        engine.disconnectNodeOutput(originalMixer)

        // Split playerNode output to two paths:
        //   Bus 0 -> effect (vocal isolation) -> vocalsMixer (inverted) -> mainMixer bus 0
        //   Bus 0 -> originalMixer (original audio) -> mainMixer bus 1
        let toEffect = AVAudioConnectionPoint(node: effect, bus: 0)
        let toOriginal = AVAudioConnectionPoint(node: originalMixer, bus: 0)
        engine.connect(playerNode, to: [toEffect, toOriginal], fromBus: 0, format: format)

        // Vocal path: effect -> vocalsMixer -> mainMixer bus 0
        engine.connect(effect, to: vocalsMixer, format: format)
        engine.connect(vocalsMixer, to: mainMixer, fromBus: 0, toBus: 0, format: format)

        // Original path: originalMixer -> mainMixer bus 1
        engine.connect(originalMixer, to: mainMixer, fromBus: 0, toBus: 1, format: format)

        // Ensure isolation parameters are set after reconnection
        applyIsolationParameters()
    }

    /// Apply the AUSoundIsolation parameters. Called after any reconnection
    /// that might reset the AU's internal state.
    private func applyIsolationParameters() {
        guard let effect = isolationEffect else { return }
        let paramTree = effect.auAudioUnit.parameterTree

        // Isolate vocals (we'll phase-invert and subtract them)
        paramTree?.parameter(withAddress: 1)?.value = 1.0   // Sound to Isolate = vocals
        paramTree?.parameter(withAddress: 0)?.value = 100.0  // Wet/Dry = fully processed

        #if DEBUG
        let wetDry = paramTree?.parameter(withAddress: 0)?.value ?? -999
        let isolate = paramTree?.parameter(withAddress: 1)?.value ?? -999
        EnsembleLogger.debug("[InstrumentalEngine] Parameters applied -- wetDry=\(wetDry), soundToIsolate=\(isolate)")
        #endif
    }

    // MARK: - File Loading

    /// Load an audio file for playback
    func load(fileURL: URL) throws {
        let file = try AVAudioFile(forReading: fileURL)
        audioFile = file
        sampleRate = file.processingFormat.sampleRate

        // Reconnect the graph with the file's actual format
        connectGraph(format: file.processingFormat)

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Loaded file: \(fileURL.lastPathComponent), sampleRate=\(sampleRate), frames=\(file.length)")
        #endif
    }

    // MARK: - Playback Control

    /// Schedule and start playback from the given time offset
    func play(from time: TimeInterval = 0) throws {
        guard let file = audioFile else {
            throw InstrumentalEngineError.noFileLoaded
        }

        let startFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = file.length
        guard startFrame < totalFrames else {
            onPlaybackComplete?()
            return
        }

        // Bump generation so any in-flight completion from the previous schedule is ignored
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        seekFrameOffset = startFrame
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)

        playerNode.stop()
        file.framePosition = startFrame
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        if !engine.isRunning {
            try engine.start()
        }

        // Re-apply parameters after engine start in case it resets AU state
        applyIsolationParameters()

        playerNode.play()
        wasPlaying = true
        startTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Playing from \(String(format: "%.1f", time))s (frame \(startFrame)/\(totalFrames))")
        #endif
    }

    /// Pause playback (engine stays running to avoid restart latency)
    func pause() {
        playerNode.pause()
        wasPlaying = false
        stopTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Paused")
        #endif
    }

    /// Resume playback after pause
    func resume() throws {
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
        wasPlaying = true
        startTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Resumed")
        #endif
    }

    /// Stop playback and clean up
    func stop() {
        // Bump generation so any in-flight completion callbacks are ignored
        scheduleGeneration &+= 1
        stopTimeUpdates()
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        wasPlaying = false
        seekFrameOffset = 0
        currentTimeSubject.send(0)

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Stopped")
        #endif
    }

    /// Seek to a new position
    func seek(to time: TimeInterval) throws {
        guard let file = audioFile else { return }

        let wasPlayingBeforeSeek = wasPlaying || playerNode.isPlaying

        // Bump generation so the old segment's completion callback is ignored
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        playerNode.stop()

        let startFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = file.length
        guard startFrame < totalFrames else {
            onPlaybackComplete?()
            return
        }

        seekFrameOffset = startFrame
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)

        file.framePosition = startFrame
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        if wasPlayingBeforeSeek {
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            wasPlaying = true
            startTimeUpdates()
        }

        // Update time immediately for responsive UI
        currentTimeSubject.send(time)

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Seeked to \(String(format: "%.1f", time))s")
        #endif
    }

    // MARK: - Time Tracking

    /// Compute current playback time from player node render position
    func currentTime() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return TimeInterval(seekFrameOffset) / sampleRate
        }
        let framePosition = playerTime.sampleTime + seekFrameOffset
        return TimeInterval(framePosition) / sampleRate
    }

    /// Start periodic time updates at ~10Hz
    private func startTimeUpdates() {
        stopTimeUpdates()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let time = self.currentTime()
            self.currentTimeSubject.send(time)
        }
        timer.resume()
        timeUpdateTimer = timer
    }

    /// Stop periodic time updates
    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    // MARK: - Completion Handling

    /// Only trigger track advance if this completion matches the current generation
    private func handleSegmentComplete(generation: UInt64) {
        guard generation == scheduleGeneration else {
            #if DEBUG
            EnsembleLogger.debug("[InstrumentalEngine] Ignoring stale completion (gen \(generation) vs current \(scheduleGeneration))")
            #endif
            return
        }
        guard wasPlaying else { return }
        wasPlaying = false
        stopTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Segment complete -- triggering track advance")
        #endif

        onPlaybackComplete?()
    }

    // MARK: - Cleanup

    deinit {
        stopTimeUpdates()
        playerNode.stop()
        engine.stop()
    }
}

// MARK: - Errors

public enum InstrumentalEngineError: Error, LocalizedError {
    case soundIsolationUnavailable
    case noFileLoaded

    public var errorDescription: String? {
        switch self {
        case .soundIsolationUnavailable:
            return "AUSoundIsolation audio unit is not available on this device"
        case .noFileLoaded:
            return "No audio file has been loaded"
        }
    }
}
