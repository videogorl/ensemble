import AudioToolbox
import AVFoundation
import Combine

/// Isolated AVAudioEngine wrapper that removes vocals using AUSoundIsolation with
/// the Apple Music Sing neural network model for music-quality vocal separation.
/// Completely separate from the AVQueuePlayer path -- used only when instrumental mode is active.
///
/// Key insight: AUSoundIsolation ships with three models:
///   - vi-voice: Standard voice isolation (FaceTime quality) -- default for soundToIsolate=1
///   - vi-high-quality-voice: Better voice isolation (iOS 18+) -- default for soundToIsolate=0
///   - vi-v0: Music vocal separation model (Espresso, 2.3MB) -- must be loaded explicitly
///
/// Without the v0 model, the AU only does FaceTime-grade voice isolation.
/// With the v0 model loaded via NeuralNetPlistPathOverride, wetDryMix becomes
/// a vocal attenuation control: 0 = no effect, 100 = full vocal removal (instrumentals).
///
/// Audio graph:
/// ```
/// playerNode -> AUSoundIsolation(v0 model, wetDry=100) -> mainMixer -> output
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
    private var scheduleGeneration: UInt64 = 0

    /// Current playback time, updated at ~10Hz
    let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private var timeUpdateTimer: DispatchSourceTimer?

    /// Fires when the scheduled audio segment finishes (for auto-advance)
    var onPlaybackComplete: (() -> Void)?

    private var isSetUp = false
    private var sampleRate: Double = 44100
    /// Whether the music-quality v0 model was successfully loaded
    private var musicModelLoaded = false

    // MARK: - Undocumented AU Constants

    // Neural net model override properties (discovered via QuietNow project)
    private let kNeuralNetPlistPathOverride: AudioUnitPropertyID = 30000
    private let kNeuralNetModelNetPathBaseOverride: AudioUnitPropertyID = 40000
    private let kDeverbPresetPathOverride: AudioUnitPropertyID = 50000

    // Tuning mode parameters
    private let kUseTuningMode: AudioUnitParameterID = 0x17626   // 95782
    private let kTuningMode: AudioUnitParameterID = 0x17627      // 95783

    // MARK: - Setup

    /// Build the audio graph with music-quality vocal separation
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

        // Try to load the music-quality v0 neural network model
        loadMusicModel(for: effect)

        // Configure parameters
        applyIsolationParameters(to: effect)

        // Attach nodes
        engine.attach(playerNode)
        engine.attach(effect)

        // Connect graph. When the v0 model is loaded, the AU expects 24kHz mono input
        // (per its plist). Passing nil for format lets AVAudioEngine negotiate and insert
        // format converters automatically between nodes.
        let mainMixer = engine.mainMixerNode
        if musicModelLoaded {
            engine.connect(playerNode, to: effect, format: nil)
            engine.connect(effect, to: mainMixer, format: nil)
        } else {
            let format = mainMixer.outputFormat(forBus: 0)
            engine.connect(playerNode, to: effect, format: format)
            engine.connect(effect, to: mainMixer, format: format)
        }

        isSetUp = true

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Graph built (musicModel=\(musicModelLoaded))")
        #endif
    }

    // MARK: - Music Model Loading

    /// Load the Apple Music Sing neural network model (v0) for music-quality vocal separation.
    /// Without this, the AU uses its default voice isolation model (FaceTime quality).
    private func loadMusicModel(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit

        // The v0 music model plist and weights live in the system audio tunings directory.
        // The AU framework can access system paths that our app sandbox cannot,
        // so we skip FileManager.exists checks and just set the properties.
        let tuningsBase = "/System/Library/Audio/Tunings"
        let v0PlistPath = "\(tuningsBase)/Generic/AU/SoundIsolation/aufx-vois-appl-nnet-vi-v0.plist"

        // Enable tuning mode so the AU accepts model overrides
        AudioUnitSetParameter(au, kUseTuningMode, kAudioUnitScope_Global, 0, 1.0, 0)
        AudioUnitSetParameter(au, kTuningMode, kAudioUnitScope_Global, 0, 1.0, 0)

        // Override neural net model to the v0 music model
        let plistOK = setAUStringProperty(au, propertyID: kNeuralNetPlistPathOverride, value: v0PlistPath)
        let baseOK = setAUStringProperty(au, propertyID: kNeuralNetModelNetPathBaseOverride, value: tuningsBase)

        // Leave dereverb enabled (default) -- helps clean up vocal reverb tails

        musicModelLoaded = plistOK && baseOK

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Music model load: plist=\(plistOK), base=\(baseOK), loaded=\(musicModelLoaded)")

        // Log all parameters after model load
        if let tree = effect.auAudioUnit.parameterTree {
            for param in tree.allParameters {
                EnsembleLogger.debug("[InstrumentalEngine] Param: addr=\(param.address), name='\(param.displayName)', range=\(param.minValue)..\(param.maxValue), value=\(param.value)")
            }
        }

        // Check tuning mode params via C API
        var useTuning: AudioUnitParameterValue = 0
        var tuning: AudioUnitParameterValue = 0
        AudioUnitGetParameter(au, kUseTuningMode, kAudioUnitScope_Global, 0, &useTuning)
        AudioUnitGetParameter(au, kTuningMode, kAudioUnitScope_Global, 0, &tuning)
        EnsembleLogger.debug("[InstrumentalEngine] TuningMode params: useTuning=\(useTuning), tuning=\(tuning)")
        #endif
    }

    /// Set a CFString property on a raw AudioUnit. Returns true on success.
    @discardableResult
    private func setAUStringProperty(_ au: AudioUnit, propertyID: AudioUnitPropertyID, value: String) -> Bool {
        var cfString = value as CFString
        let status = AudioUnitSetProperty(
            au, propertyID, kAudioUnitScope_Global, 0,
            &cfString, UInt32(MemoryLayout<CFString>.size)
        )
        #if DEBUG
        if status != noErr {
            EnsembleLogger.debug("[InstrumentalEngine] Failed to set property \(propertyID): OSStatus \(status)")
        }
        #endif
        return status == noErr
    }

    /// Apply the AUSoundIsolation parameters
    private func applyIsolationParameters(to effect: AVAudioUnitEffect? = nil) {
        let target = effect ?? isolationEffect
        guard let target else { return }
        let paramTree = target.auAudioUnit.parameterTree

        if musicModelLoaded {
            // With the v0 music model, wetDryMix is a vocal attenuation control:
            //   0 = no effect (original audio)
            //   100 = full vocal removal (instrumentals)
            paramTree?.parameter(withAddress: 1)?.value = 0.0    // HighQualityVoice (iOS 18+)
            paramTree?.parameter(withAddress: 0)?.value = 100.0  // Full vocal removal
        } else {
            // Fallback without music model: use negative wetDryMix for internal subtraction
            //   output = dry + (-wet) = original + (-vocals) = instrumentals
            paramTree?.parameter(withAddress: 1)?.value = 0.0     // Voice isolation (clean)
            paramTree?.parameter(withAddress: 0)?.value = -100.0  // Phase-invert and mix
        }

        #if DEBUG
        let wetDry = paramTree?.parameter(withAddress: 0)?.value ?? -999
        let isolate = paramTree?.parameter(withAddress: 1)?.value ?? -999
        EnsembleLogger.debug("[InstrumentalEngine] Parameters: wetDry=\(wetDry), soundToIsolate=\(isolate), musicModel=\(musicModelLoaded)")
        #endif
    }

    // MARK: - File Loading

    func load(fileURL: URL) throws {
        let file = try AVAudioFile(forReading: fileURL)
        audioFile = file
        sampleRate = file.processingFormat.sampleRate

        // Reconnect -- use nil format when music model is loaded to let
        // AVAudioEngine handle the 44.1kHz→24kHz conversion automatically
        if let effect = isolationEffect {
            if musicModelLoaded {
                engine.connect(playerNode, to: effect, format: nil)
                engine.connect(effect, to: engine.mainMixerNode, format: nil)
            } else {
                engine.connect(playerNode, to: effect, format: file.processingFormat)
                engine.connect(effect, to: engine.mainMixerNode, format: file.processingFormat)
            }
        }
        applyIsolationParameters()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Loaded: \(fileURL.lastPathComponent), rate=\(sampleRate), frames=\(file.length)")
        #endif
    }

    // MARK: - Playback Control

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

        // Re-apply after engine start (engine start can reset AU state)
        applyIsolationParameters()

        playerNode.play()
        wasPlaying = true
        startTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Playing from \(String(format: "%.1f", time))s (frame \(startFrame)/\(totalFrames))")
        #endif
    }

    func pause() {
        playerNode.pause()
        wasPlaying = false
        stopTimeUpdates()
        #if DEBUG
        EnsembleLogger.debug("[InstrumentalEngine] Paused")
        #endif
    }

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
            self.currentTimeSubject.send(self.currentTime())
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
