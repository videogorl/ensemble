import AudioToolbox
import AVFoundation
import Combine

/// Isolated AVAudioEngine wrapper that removes vocals using AUSoundIsolation.
/// Completely separate from the AVQueuePlayer path -- used only when instrumental mode is active.
///
/// AUSoundIsolation parameters (discovered via runtime enumeration):
///   Address 0: "Wet/Dry Mix" (range -100.0 to 100.0)
///   Address 1: "Sound to Isolate" (range 0.0 to 1.0)
///
/// Strategy: isolate vocals (soundToIsolate=1) then use negative wetDryMix (-100)
/// to phase-invert the vocal extraction and mix it with the original signal internally.
/// This cancels the vocals, leaving only instrumentals -- all within the AU itself.
///
/// Audio graph:
/// ```
/// AVAudioPlayerNode -> AVAudioUnitEffect(AUSoundIsolation) -> mainMixerNode -> outputNode
/// ```
public final class InstrumentalAudioEngine {
    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isolationEffect: AVAudioUnitEffect?
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

    /// Build the audio graph: playerNode -> AUSoundIsolation -> mixer -> output
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

        #if DEBUG
        if let tree = effect.auAudioUnit.parameterTree {
            for param in tree.allParameters {
                EnsembleLogger.debug("[InstrumentalEngine] Parameter: address=\(param.address), identifier='\(param.identifier)', name='\(param.displayName)', min=\(param.minValue), max=\(param.maxValue), value=\(param.value)")
            }
        }
        #endif

        // Configure AUSoundIsolation:
        //   soundToIsolate = 1.0 (isolate vocals)
        //   wetDryMix = -100.0 (phase-invert the isolated vocals and mix with original)
        //   Result: original + (-vocals) = instrumentals, all within the AU
        applyIsolationParameters(to: effect)

        // Attach nodes
        engine.attach(playerNode)
        engine.attach(effect)

        // Simple linear graph: playerNode -> effect -> mainMixer -> output
        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        engine.connect(playerNode, to: effect, format: format)
        engine.connect(effect, to: mainMixer, format: format)

        isSetUp = true

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Graph: playerNode -> AUSoundIsolation(wetDry=-100, isolate=vocals) -> mixer")
        #endif
    }

    /// Apply vocal removal parameters to the AUSoundIsolation effect
    private func applyIsolationParameters(to effect: AVAudioUnitEffect? = nil) {
        let target = effect ?? isolationEffect
        guard let target else { return }
        let paramTree = target.auAudioUnit.parameterTree

        // Isolate vocals, then phase-invert via negative wet/dry mix
        paramTree?.parameter(withAddress: 1)?.value = 1.0     // Sound to Isolate = vocals
        paramTree?.parameter(withAddress: 0)?.value = -100.0   // Negative = invert isolated + mix with dry

        #if DEBUG
        let wetDry = paramTree?.parameter(withAddress: 0)?.value ?? -999
        let isolate = paramTree?.parameter(withAddress: 1)?.value ?? -999
        EnsembleLogger.debug("[InstrumentalEngine] Parameters: wetDry=\(wetDry), soundToIsolate=\(isolate)")
        #endif
    }

    // MARK: - File Loading

    /// Load an audio file for playback
    func load(fileURL: URL) throws {
        let file = try AVAudioFile(forReading: fileURL)
        audioFile = file
        sampleRate = file.processingFormat.sampleRate

        // Reconnect with the file's format
        if let effect = isolationEffect {
            engine.connect(playerNode, to: effect, format: file.processingFormat)
            engine.connect(effect, to: engine.mainMixerNode, format: file.processingFormat)
        }

        // Re-apply parameters after reconnection
        applyIsolationParameters()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Loaded: \(fileURL.lastPathComponent), rate=\(sampleRate), frames=\(file.length)")
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

        // Re-apply after engine start
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

    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    // MARK: - Completion Handling

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
es - startFrame)

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
