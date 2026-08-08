import AudioToolbox
import AVFoundation
import Combine
import QuartzCore

struct StreamingRenderHealth {
    let recoveryThresholdFrames: AVAudioFramePosition
    private(set) var missingFrameCount: AVAudioFramePosition = 0
    private var didReportUnderrun = false

    init(recoveryThresholdFrames: AVAudioFramePosition) {
        self.recoveryThresholdFrames = recoveryThresholdFrames
    }

    mutating func observe(
        renderedFrames: Int,
        requestedFrames: AVAudioFrameCount,
        isComplete: Bool
    ) -> Bool {
        guard !didReportUnderrun, !isComplete else { return false }

        let missingFrames = max(0, Int64(requestedFrames) - Int64(renderedFrames))
        if missingFrames == 0 {
            missingFrameCount = 0
            return false
        }

        missingFrameCount += AVAudioFramePosition(missingFrames)
        guard missingFrameCount >= recoveryThresholdFrames else { return false }
        didReportUnderrun = true
        return true
    }
}

/// General-purpose AVAudioEngine wrapper for file-based audio playback.
/// Replaces AVQueuePlayer with direct PCM scheduling for gapless transitions,
/// inline audio effects (AUSoundIsolation for instrumental mode), and
/// frame-accurate time tracking.
///
/// Evolved from InstrumentalAudioEngine -- carries its proven patterns
/// (generation counter, scheduleSegment, time tracking) while adding
/// gapless FIFO scheduling, toggleable isolation, and route change recovery.
///
/// Audio graph (isolation disabled):
/// ```
/// primary deck: playerNode -> primaryTimePitch -> outgoingHighPassEQ -> deckMixer -> mainMixer -> output
/// SmartMix deck: smartMixPlayerNode -> incomingTimePitch -> smartMixHighPassEQ -> deckMixer -> mainMixer -> output
/// ```
///
/// Audio graph (isolation enabled):
/// ```
/// deckMixer -> AUSoundIsolation(v0 model) -> mainMixer -> output
/// ```
public final class AudioPlaybackEngine {

    // MARK: - Core Engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let smartMixPlayerNode = AVAudioPlayerNode()
    private var streamingSourceNode: AVAudioSourceNode?
    private let outgoingHighPassEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let smartMixHighPassEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let primaryTimePitch = AVAudioUnitTimePitch()
    private let incomingTimePitch = AVAudioUnitTimePitch()
    private let deckMixer = AVAudioMixerNode()

    // MARK: - Isolation Effect (lazy, toggleable)

    /// AUSoundIsolation effect node -- created lazily on first isolation toggle
    private var isolationEffect: AVAudioUnitEffect?
    /// Whether the isolation node has been created (lazy init guard)
    private var isolationNodeCreated = false
    /// Whether the isolation effect is currently in the signal chain
    private(set) var isIsolationActive = false
    /// Whether the v0 neural network model was successfully loaded
    private var musicModelLoaded = false
    /// Undocumented AU properties (from QuietNow + reverse engineering)
    private let kNeuralNetPlistPath: AudioUnitPropertyID = 30000
    private let kNeuralNetModelBasePath: AudioUnitPropertyID = 40000
    private let kDeverbPresetPathOverride: AudioUnitPropertyID = 50000
    static let instrumentalIsolationMaxFramesToRender: UInt32 = 8192
    static let instrumentalIsolationPreferredIOBufferDuration: TimeInterval = 0.128
    static let standardPreferredIOBufferDuration: TimeInterval = 0.023

    // MARK: - Playback State

    /// The currently loaded audio file
    private var currentFile: AVAudioFile?
    /// Track ID of the currently playing file (for caller identification)
    private(set) var currentTrackId: String?
    /// PlaybackService request that loaded the current source.
    private(set) var playbackRequestGeneration: UInt64 = 0
    /// Duration of the current file in seconds (content only, excludes encoder delay/padding)
    private(set) var fileDuration: TimeInterval = 0
    /// Frame offset from which the current segment was scheduled (in user-visible frame space,
    /// relative to content start — NOT the file's raw frame space)
    private var seekFrameOffset: AVAudioFramePosition = 0
    /// Cumulative playerTime.sampleTime at the start of the current segment.
    /// During gapless transitions the playerNode keeps running, so sampleTime
    /// accumulates across segments. We capture it at each transition so
    /// currentTime() can subtract the prior segments' contribution.
    private var playerTimeBaseOffset: AVAudioFramePosition = 0
    /// Sample rate of the currently loaded file
    private var sampleRate: Double = 44100
    /// Whether the engine was playing when last paused (for resume logic)
    private var wasPlaying = false
    private(set) var isProviderHandoffBridgeActive = false
    var isRunningForDiagnostics: Bool { engine.isRunning }
    private var streamingPipeline: StreamingAudioPipeline?
    var isStreamingSourceActive: Bool { streamingPipeline != nil }
    private var streamingStartTime: TimeInterval = 0
    private var streamingCompletionGeneration: UInt64 = 0
    private var streamingCompletionNotified = false

    // MARK: - Encoder Delay Compensation

    /// Encoder delay (priming frames) for the currently loaded file.
    /// Audio content begins at this frame offset in the file's raw frame space.
    /// For PCM/FLAC/ALAC this is 0. For MP3 (LAME) it's typically 576 frames (~13ms).
    private var currentContentStartFrame: AVAudioFramePosition = 0
    /// Total frames of actual audio content (excludes encoder delay and padding).
    /// For lossless formats this equals file.length. For MP3 it's shorter.
    private var currentContentFrameCount: AVAudioFrameCount = 0

    // MARK: - Generation Counter

    /// Incremented on each schedule/seek/stop to suppress stale completion callbacks.
    /// playerNode.stop() fires all pending completion handlers immediately --
    /// without this guard, every seek would trigger a spurious track advance.
    private var scheduleGeneration: UInt64 = 0

    // MARK: - Gapless FIFO Queue

    /// Files scheduled for gapless playback via scheduleSegment FIFO.
    /// Each entry tracks the file, track ID, generation, and encoder delay trim info.
    private var scheduledFiles: [(file: AVAudioFile, trackId: String, generation: UInt64, contentStartFrame: AVAudioFramePosition, contentFrameCount: AVAudioFrameCount)] = []

    // MARK: - SmartMix

    private enum PlaybackDeck: String {
        case primary
        case smartMix

        var opposite: PlaybackDeck {
            switch self {
            case .primary:
                return .smartMix
            case .smartMix:
                return .primary
            }
        }
    }

    private struct SmartMixEngineTransition {
        let file: AVAudioFile
        let trackId: String
        let outgoingDeck: PlaybackDeck
        let incomingDeck: PlaybackDeck
        let contentStartFrame: AVAudioFramePosition
        let contentFrameCount: AVAudioFrameCount
        let sampleRate: Double
        let duration: TimeInterval
        let incomingStartTime: TimeInterval
        let transitionDuration: TimeInterval
        let skipThreshold: TimeInterval
        let incomingPlaybackRate: Double
        let outgoingPlaybackRate: Double
        let highPassSweep: SmartMixHighPassSweep?
        let generation: UInt64
        let startedAtWallTime: TimeInterval
        var promoted = false

        var midpoint: TimeInterval {
            transitionDuration / 2
        }
    }

    private var smartMixTransition: SmartMixEngineTransition?
    private var activePlaybackDeck: PlaybackDeck = .primary
    private var smartMixFadeTimer: DispatchSourceTimer?

    // MARK: - Time Tracking

    /// Current playback time, updated at ~10Hz via DispatchSourceTimer.
    /// Sent from a dedicated background queue using wall-clock estimation to
    /// avoid any playerNode property access that could cause priority inversion
    /// with the audio render thread.
    let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    /// Last user-visible playhead. Unlike `seekFrameOffset`, this is playback
    /// truth when CoreAudio render timing disappears during route changes.
    private var durablePlaybackPosition: TimeInterval = 0
    private var timeUpdateTimer: DispatchSourceTimer?
    /// Dedicated queue for time updates. Uses wall-clock estimation (CACurrentMediaTime)
    /// instead of playerNode.lastRenderTime to avoid priority inversion between the
    /// audio render thread and the main thread during heavy SwiftUI layout passes.
    private let timeUpdateQueue = DispatchQueue(label: "com.ensemble.audioTimeUpdate", qos: .userInteractive)

    // Wall-clock time estimation: avoids polling playerNode.lastRenderTime which
    // acquires an internal AVAudioNode lock. If the timer thread holds that lock and
    // gets preempted by the main thread (doing heavy SwiftUI layout), the real-time
    // IO thread is blocked for the duration of the layout pass — classic unbounded
    // priority inversion. Instead we estimate time from CACurrentMediaTime().
    //
    // Packed into a value-type struct so the background timer reads a consistent
    // snapshot — struct assignment/read is a single pointer-width copy on arm64,
    // avoiding torn reads of (wallTime, position, duration) during gapless transitions.
    private struct TimeBase {
        var wallTime: TimeInterval = 0      // CACurrentMediaTime() at play/resume/seek
        var position: TimeInterval = 0      // Playback position at that moment
        var duration: TimeInterval = 0      // Duration of the current file
    }
    private var timeBase = TimeBase()
    /// Route-change notifications can arrive before AVAudioEngine tears down its
    /// render state. We capture the last stable playhead here so config-change
    /// recovery can ignore transient 0.0s reports during AirPlay switches.
    private var pendingRouteRecoveryPosition: TimeInterval?

    // MARK: - Route Change Recovery

    /// Observer for AVAudioEngine configuration change notifications (route changes)
    private var configChangeObserver: NSObjectProtocol?

    // MARK: - Setup State

    private var isSetUp = false

    // MARK: - Callbacks

    /// Fires when all scheduled segments complete (queue exhausted)
    var onPlaybackComplete: ((_ playbackGeneration: UInt64) -> Void)?
    /// Fires when a gapless transition advances to the next scheduled track
    var onTrackAdvance: ((_ newTrackId: String, _ playbackGeneration: UInt64) -> Void)?
    /// Fires when SmartMix crosses the transition midpoint and app metadata should promote.
    var onSmartMixPromote: ((_ newTrackId: String, _ playbackGeneration: UInt64) -> Void)?
    /// Fires when a SmartMix overlap starts or finishes for lightweight UI status.
    var onSmartMixTransitionActiveChanged: ((_ isActive: Bool, _ playbackGeneration: UInt64) -> Void)?
    /// Fires after the render path has produced PCM for the current track.
    var onFirstAudibleRender: ((_ trackId: String, _ playbackGeneration: UInt64) -> Void)?
    /// Fires as streaming decode advances far enough to draw loaded waveform regions.
    var onBufferedProgress: ((_ trackId: String, _ playbackGeneration: UInt64, _ progress: Double) -> Void)?
    /// Fires on unrecoverable engine errors (route change failure, etc.)
    /// Parameters: (error, trackId or nil). When trackId is non-nil, the error
    /// originated from a gapless-scheduled track (not the currently playing one).
    var onError: ((Error, String?, UInt64) -> Void)?


    // MARK: - Setup

    /// Initialize the audio engine graph.
    /// Call once before loading files. Isolation effect is created lazily on first toggle.
    func setup() throws {
        guard !isSetUp else { return }

        engine.attach(playerNode)
        engine.attach(smartMixPlayerNode)
        engine.attach(outgoingHighPassEQ)
        engine.attach(smartMixHighPassEQ)
        engine.attach(primaryTimePitch)
        engine.attach(incomingTimePitch)
        engine.attach(deckMixer)
        configureSmartMixEffectDefaults()

        // Keep deck effects in the graph and neutral by default so route rebuilds
        // do not need to insert nodes during an active transition.
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        engine.connect(playerNode, to: primaryTimePitch, format: outputFormat)
        engine.connect(primaryTimePitch, to: outgoingHighPassEQ, format: outputFormat)
        engine.connect(outgoingHighPassEQ, to: deckMixer, format: outputFormat)
        engine.connect(smartMixPlayerNode, to: incomingTimePitch, format: outputFormat)
        engine.connect(incomingTimePitch, to: smartMixHighPassEQ, format: outputFormat)
        engine.connect(smartMixHighPassEQ, to: deckMixer, format: outputFormat)
        engine.connect(deckMixer, to: mainMixer, format: outputFormat)

        // Register for route change notifications (AirPlay, headphone plug/unplug)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleConfigurationChange()
            }
        }

        isSetUp = true

        EnsembleLogger.debug("[AudioEngine] Graph built (deck effects -> mixer -> output)")
    }

    // MARK: - Graph Building

    /// Reconnect the audio graph, optionally inserting the isolation effect.
    /// Called during setup, isolation toggle, file load, and route change recovery.
    private func buildGraph(format: AVAudioFormat?) {
        let mainMixer = engine.mainMixerNode
        let connectFormat = format ?? mainMixer.outputFormat(forBus: 0)

        // Disconnect existing connections from deck sources
        engine.disconnectNodeOutput(playerNode)
        if let streamingSourceNode {
            engine.disconnectNodeOutput(streamingSourceNode)
        }
        engine.disconnectNodeOutput(smartMixPlayerNode)
        engine.disconnectNodeOutput(primaryTimePitch)
        engine.disconnectNodeOutput(outgoingHighPassEQ)
        engine.disconnectNodeOutput(incomingTimePitch)
        engine.disconnectNodeOutput(smartMixHighPassEQ)
        engine.disconnectNodeOutput(deckMixer)
        if let effect = isolationEffect {
            engine.disconnectNodeOutput(effect)
        }

        if let streamingSourceNode {
            engine.connect(streamingSourceNode, to: primaryTimePitch, format: connectFormat)
        } else {
            engine.connect(playerNode, to: primaryTimePitch, format: connectFormat)
        }
        engine.connect(primaryTimePitch, to: outgoingHighPassEQ, format: connectFormat)
        engine.connect(outgoingHighPassEQ, to: deckMixer, format: connectFormat)
        engine.connect(smartMixPlayerNode, to: incomingTimePitch, format: connectFormat)
        engine.connect(incomingTimePitch, to: smartMixHighPassEQ, format: connectFormat)
        engine.connect(smartMixHighPassEQ, to: deckMixer, format: connectFormat)

        if let effect = isolationEffect {
            // deckMixer -> isolation -> mixer
            // Effect stays in chain permanently; wetDryMix=0 acts as passthrough
            engine.connect(deckMixer, to: effect, format: connectFormat)
            engine.connect(effect, to: mainMixer, format: connectFormat)
        } else {
            // No isolation effect created (or unavailable) — direct deck path
            engine.connect(deckMixer, to: mainMixer, format: connectFormat)
        }
    }

    private func configureSmartMixEffectDefaults() {
        resetHighPass(for: .primary)
        resetHighPass(for: .smartMix)
        resetTimePitch(for: .primary)
        resetTimePitch(for: .smartMix)
    }

    private func resetHighPass(for deck: PlaybackDeck) {
        if let band = highPassEQ(for: deck).bands.first {
            band.filterType = .highPass
            band.frequency = SmartMixHighPassSweep.subtle.startFrequency
            band.bypass = true
        }
    }

    private func resetTimePitch(for deck: PlaybackDeck) {
        let timePitch = timePitchNode(for: deck)
        timePitch.pitch = 0
        timePitch.rate = 1
    }

    private func resetSmartMixEffects() {
        configureSmartMixEffectDefaults()
    }

    private func playerNode(for deck: PlaybackDeck) -> AVAudioPlayerNode {
        switch deck {
        case .primary:
            return playerNode
        case .smartMix:
            return smartMixPlayerNode
        }
    }

    private var activePlayerNode: AVAudioPlayerNode {
        playerNode(for: activePlaybackDeck)
    }

    private func timePitchNode(for deck: PlaybackDeck) -> AVAudioUnitTimePitch {
        switch deck {
        case .primary:
            return primaryTimePitch
        case .smartMix:
            return incomingTimePitch
        }
    }

    private func highPassEQ(for deck: PlaybackDeck) -> AVAudioUnitEQ {
        switch deck {
        case .primary:
            return outgoingHighPassEQ
        case .smartMix:
            return smartMixHighPassEQ
        }
    }

    private func setVolume(_ volume: Float, for deck: PlaybackDeck) {
        playerNode(for: deck).volume = volume
    }

    private func stopInactiveDeck() {
        let inactiveDeck = activePlaybackDeck.opposite
        playerNode(for: inactiveDeck).stop()
        setVolume(0, for: inactiveDeck)
        resetTimePitch(for: inactiveDeck)
        resetHighPass(for: inactiveDeck)
    }

    static func smartMixFormatsMatch(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    static func smartMixIncomingPosition(
        incomingStartTime: TimeInterval,
        elapsed: TimeInterval,
        incomingPlaybackRate: Double,
        duration: TimeInterval
    ) -> TimeInterval {
        let scaledElapsed = max(0, elapsed) * max(0, incomingPlaybackRate)
        return min(incomingStartTime + scaledElapsed, duration)
    }

    static func smartMixHighPassFrequency(
        progress: Double,
        sweep: SmartMixHighPassSweep,
        sampleRate: Double
    ) -> Float {
        let safeSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 44100
        let nyquistLimit = max(Float(20), Float(safeSampleRate / 2) - 1)
        let start = min(max(20, sweep.startFrequency), nyquistLimit)
        let end = min(max(start, sweep.endFrequency), nyquistLimit)
        guard progress > sweep.startProgress else { return start }

        let rampProgress = min(max((progress - sweep.startProgress) / max(0.001, 1 - sweep.startProgress), 0), 1)
        let easedProgress = smoothStep(rampProgress)
        return start + Float(easedProgress) * (end - start)
    }

    static func smartMixTempoRate(
        progress: Double,
        targetRate: Double,
        startProgress: Double = 0.15
    ) -> Float {
        guard targetRate.isFinite, targetRate > 0 else { return 1 }
        let clampedStart = min(max(startProgress, 0), 1)
        guard progress > clampedStart else { return 1 }

        let rampProgress = min(max((progress - clampedStart) / max(0.001, 1 - clampedStart), 0), 1)
        let easedProgress = smoothStep(rampProgress)
        return Float(1 + (targetRate - 1) * easedProgress)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    // MARK: - Route Change Recovery

    /// Capture the last stable playhead before AVAudioEngineConfigurationChange
    /// invalidates render timing during a route transition.
    func prepareForRouteChange() {
        guard currentFile != nil else { return }

        let renderClockPosition = currentRenderClockPosition()
        if let renderClockPosition {
            updateDurablePlaybackPosition(renderClockPosition, publish: false)
        }
        let observedPosition = durablePlaybackPosition
        let fallbackPosition = durablePlaybackPosition
        let position = Self.resolvedPreparedRouteRecoveryPosition(
            renderClockPosition: renderClockPosition,
            observedPosition: observedPosition,
            fallbackPosition: fallbackPosition,
            duration: fileDuration
        )
        pendingRouteRecoveryPosition = position
        let renderClockDescription = renderClockPosition.map { String($0) } ?? "nil"

        EnsembleLogger.debug(
            "[AudioEngine] Prepared route recovery snapshot at \(position)s"
            + " render=\(renderClockDescription)"
            + " observed=\(observedPosition)s"
            + " fallback=\(fallbackPosition)s"
        )
    }

    /// Handle AVAudioEngine configuration changes (route switches like AirPlay, headphones).
    /// The engine stops itself on route change -- we must rebuild and reschedule.
    private func handleConfigurationChange() {
        if smartMixTransition != nil {
            cancelSmartMixTransition(continueIncoming: hasPromotedSmartMixTransition)
        }
        let livePosition = currentTime()
        let position = Self.resolvedRouteRecoveryPosition(
            livePosition: livePosition,
            observedPosition: pendingRouteRecoveryPosition ?? durablePlaybackPosition,
            duration: fileDuration,
            preferredSnapshot: pendingRouteRecoveryPosition
        )
        let wasActive = wasPlaying
        pendingRouteRecoveryPosition = nil

        EnsembleLogger.debug(
            "[AudioEngine] Configuration change detected"
            + " live=\(livePosition)s"
            + " recover=\(position)s"
            + ", wasPlaying=\(wasActive)"
        )

        // Rebuild the graph with current file's format
        buildGraph(format: currentFile?.processingFormat)

        // Re-apply isolation parameters (reconnection can reset AU state)
        applyIsolationParameters()

        if isProviderHandoffBridgeActive {
            do {
                if !engine.isRunning { try engine.start() }
                EnsembleLogger.debug("[AudioEngine] Provider handoff bridge survived configuration change")
            } catch {
                isProviderHandoffBridgeActive = false
                EnsembleLogger.error("[AudioEngine] Provider handoff bridge restart failed: \(error.localizedDescription)")
                onError?(error, nil, playbackRequestGeneration)
            }
            return
        }

        // Reschedule from the current position if we have a file
        guard let file = currentFile else { return }

        do {
            try engine.start()

            let startFrame = AVAudioFramePosition(position * sampleRate)
            let totalFrames = file.length
            guard startFrame < totalFrames else { return }

            seekFrameOffset = startFrame
            playerTimeBaseOffset = 0
            let frameCount = AVAudioFrameCount(totalFrames - startFrame)

            scheduleGeneration &+= 1
            let myGeneration = scheduleGeneration

            activePlayerNode.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleSegmentComplete(generation: myGeneration)
                }
            }

            // Re-schedule any queued gapless files with correct content bounds
            rescheduleGaplessFiles()

            if wasActive {
                activePlayerNode.play()
                wasPlaying = true
                startTimeUpdates(from: position)
            } else {
                // Stop the engine when not actively playing. iOS detects a running
                // engine's render cycle and overrides the system playback state
                // to .playing, causing the lock screen / Dynamic Island to show "playing"
                // even though audio is paused. Stopping here preserves the paused state
                // that the route-change handler already pushed to Now Playing.
                engine.stop()
            }

            updateDurablePlaybackPosition(position)

            EnsembleLogger.debug("[AudioEngine] Route change recovery complete (wasActive=\(wasActive))")
        } catch {
            EnsembleLogger.error("[AudioEngine] Route change recovery failed: \(error.localizedDescription)")
            onError?(error, nil, playbackRequestGeneration)
        }
    }

    // MARK: - Isolation Effect (AUSoundIsolation)

    /// Lazily create the AUSoundIsolation effect node. Only called on first isolation toggle.
    ///
    /// Uses the DEFAULT built-in model (no model override). Per the QuietNow project maintainer,
    /// the default AUSoundIsolation already isolates background/instrumental audio from vocals.
    /// Loading the MediaPlaybackCore model CHANGES the behavior to isolate vocals instead
    /// Explicitly sets the stream format on the AU before attaching to prevent a channel
    /// assertion crash on iOS 26+ (the AU's neural network requires stereo I/O).
    /// Then loads the v0 neural network model for high-quality vocal isolation.
    private func createIsolationEffect() throws {
        guard !isolationNodeCreated else { return }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x766F6973, // 'vois' -- kAudioUnitSubType_AUSoundIsolation
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &desc) != nil else {
            throw AudioPlaybackEngineError.soundIsolationUnavailable
        }

        let effect = AVAudioUnitEffect(audioComponentDescription: desc)
        isolationEffect = effect

        // Set stream format BEFORE engine.attach() to prevent iOS 26 channel assertion crash.
        // (Ref: QuietNow sets format on input+output scopes before AudioUnitInitialize)
        configureAUFormat(for: effect)

        // Load the neural network model for source separation.
        // iOS: v0 model isolates instrumentals directly with positive wetDryMix.
        // macOS: AU always isolates vocals regardless of parameters or model. The
        //   high-quality-voice model (MIL2BNNS) produces cleaner vocal isolation than
        //   the v0 Espresso model, yielding better complementary instrumental output.
        #if os(macOS)
        loadHighQualityVoiceModel(for: effect)
        #else
        loadMusicModel(for: effect)
        #endif

        engine.attach(effect)

        // Allow the AU to render larger buffers per callback. AUSoundIsolation is a
        // neural-network effect; if AVAudioEngine must split a large hardware buffer
        // into several smaller AU render calls, deadline misses become much more
        // likely on device.
        #if os(macOS)
        if #available(macOS 13.0, *) {
            effect.auAudioUnit.maximumFramesToRender = Self.instrumentalIsolationMaxFramesToRender
        }
        #else
        effect.auAudioUnit.maximumFramesToRender = Self.instrumentalIsolationMaxFramesToRender
        #endif

        isolationNodeCreated = true

        #if DEBUG
        dumpAUParameters(au: effect.audioUnit, label: "after attach + model load")
        #endif
    }

    /// Set the stream format on the AU before initialization.
    /// Must be called BEFORE engine.attach() which triggers AU initialization.
    private func configureAUFormat(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit

        // The AU's neural network requires stereo (2-channel) I/O.
        let format: AVAudioFormat
        if let fileFormat = currentFile?.processingFormat {
            format = fileFormat
        } else {
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        }

        // Set stream format on both input and output scopes (matching QuietNow approach)
        var asbd = format.streamDescription.pointee
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, formatSize)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, formatSize)

        // Increase max frames per slice to give the neural network more headroom per render call.
        // Default is 1156; larger slices reduce render call frequency and help prevent dropouts.
        var maxFrames = Self.instrumentalIsolationMaxFramesToRender
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        EnsembleLogger.debug("[AudioEngine] AU format configured: \(format)")
    }

    /// Load the v0 neural network model into the AUSoundIsolation unit.
    ///
    /// The AU is nearly useless without a model — it needs the neural network to perform
    /// actual source separation. On iOS 26+, models moved from MediaPlaybackCore.framework to
    /// `/System/Library/Audio/Tunings/Generic/AU/SoundIsolation/`.
    ///
    /// Uses undocumented properties:
    /// - 30000: path to the neural network plist (model configuration)
    /// - 40000: base path for resolving relative model file paths in the plist
    /// - 50000: dereverb preset path (set to empty to disable)
    /// - Parameters 0x17626/0x17627: tuning mode (activates v0 model processing)
    private func loadMusicModel(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit

        // Search for the v0 model plist in known locations.
        // iOS 26+ moved models from MediaPlaybackCore.framework to Audio/Tunings/SoundIsolation.
        // The plist's ModelNetPath is relative to basePath (e.g., "Generic/AU/SoundIsolation/...").
        let modelSearchPaths: [(plist: String, basePath: String)] = [
            // iOS 26+: models in Audio/Tunings (real device)
            (
                "/System/Library/Audio/Tunings/Generic/AU/SoundIsolation/aufx-vois-appl-nnet-vi-v0.plist",
                "/System/Library/Audio/Tunings"
            ),
            // iOS 26+: might also be under AudioDSP.component resources
            (
                "/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings/Generic/AU/SoundIsolation/aufx-vois-appl-nnet-vi-v0.plist",
                "/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings"
            ),
            // Legacy (iOS 17-18): models inside MediaPlaybackCore.framework
            (
                "/System/Library/PrivateFrameworks/MediaPlaybackCore.framework/aufx-nnet-appl.plist",
                "/System/Library/PrivateFrameworks/MediaPlaybackCore.framework"
            ),
        ]

        var loadedPlistPath: String?
        var loadedBasePath: String?

        for candidate in modelSearchPaths {
            if FileManager.default.fileExists(atPath: candidate.plist) {
                loadedPlistPath = candidate.plist
                loadedBasePath = candidate.basePath
                break
            }
            // Also check subdirectories for the legacy path (iOS 17.4+ put models in subdirs)
            let baseURL = URL(fileURLWithPath: candidate.basePath)
            if let contents = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]) {
                for dir in contents where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let subPlist = dir.appendingPathComponent("aufx-nnet-appl.plist")
                    if FileManager.default.fileExists(atPath: subPlist.path) {
                        loadedPlistPath = subPlist.path
                        loadedBasePath = dir.path
                        break
                    }
                }
            }
            if loadedPlistPath != nil { break }
        }

        guard let plistPath = loadedPlistPath, let basePath = loadedBasePath else {
            let checkedPaths = modelSearchPaths.map { $0.plist }
            EnsembleLogger.debug("[AudioEngine] No v0 model found — AU will use default (poor quality). Checked: \(checkedPaths)")
            return
        }

        // Set model paths via undocumented AU properties (from QuietNow)
        setAUStringProperty(au, property: kNeuralNetPlistPath, value: plistPath)
        setAUStringProperty(au, property: kNeuralNetModelBasePath, value: basePath)

        // Disable dereverb network (empty path = disabled)
        setAUStringProperty(au, property: kDeverbPresetPathOverride, value: "")

        // Enable tuning mode to activate v0 model processing
        AudioUnitSetParameter(au, 0x17626, kAudioUnitScope_Global, 0, 1.0, 0)
        AudioUnitSetParameter(au, 0x17627, kAudioUnitScope_Global, 0, 1.0, 0)

        musicModelLoaded = true

        EnsembleLogger.debug("[AudioEngine] v0 model loaded from: \(plistPath), base: \(basePath)")
    }

    /// Load the high-quality-voice model for macOS vocal isolation.
    /// This model uses MIL2BNNS (vs Espresso for v0) and may produce cleaner vocal
    /// separation on macOS, improving the complementary instrumental output.
    private func loadHighQualityVoiceModel(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit
        let basePath = "/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings"
        let plistPath = basePath + "/Generic/AU/SoundIsolation/aufx-vois-appl-nnet-vi-high-quality-voice.plist"

        guard FileManager.default.fileExists(atPath: plistPath) else {
            EnsembleLogger.debug("[AudioEngine] macOS high-quality-voice model not found at: \(plistPath)")
            // Fall back to v0 model
            loadMusicModel(for: effect)
            return
        }

        setAUStringProperty(au, property: kNeuralNetPlistPath, value: plistPath)
        setAUStringProperty(au, property: kNeuralNetModelBasePath, value: basePath)

        // Enable dereverb network to clean up vocal reverb tails that bleed into
        // the complementary (instrumental) signal during loud vocal sections.
        let deverbPath = basePath + "/Generic/AU/SoundIsolation/aufx-vois-appl-drev.aupreset"
        if FileManager.default.fileExists(atPath: deverbPath) {
            setAUStringProperty(au, property: kDeverbPresetPathOverride, value: deverbPath)
            EnsembleLogger.debug("[AudioEngine] macOS: dereverb network enabled")
        } else {
            setAUStringProperty(au, property: kDeverbPresetPathOverride, value: "")
        }

        musicModelLoaded = true
        EnsembleLogger.debug("[AudioEngine] macOS: high-quality-voice model loaded from: \(plistPath)")
    }

    /// Set a CFString property on an AudioUnit, avoiding the UnsafeRawPointer warning.
    private func setAUStringProperty(_ au: AudioUnit, property: AudioUnitPropertyID, value: String) {
        var cfStr = value as CFString
        _ = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioUnitSetProperty(au, property, kAudioUnitScope_Global, 0,
                                 ptr, UInt32(MemoryLayout<CFString>.size))
        }
    }

    /// Toggle vocal isolation on or off. Lazily creates the AU on first enable.
    ///
    /// First enable: wires the effect into the graph (requires stop/rebuild/reschedule).
    /// Subsequent toggles: just changes wetDryMix parameter (0=passthrough, 100=isolated)
    /// — no graph rebuild, no audio gap.
    func setIsolationEnabled(_ enabled: Bool) throws {
        guard enabled != isIsolationActive else { return }

        if !isolationNodeCreated {
            // First time: create effect and wire it into the graph permanently.
            // This requires a full graph rebuild.
            try createIsolationEffect()
            try wireIsolationIntoGraph()
        }

        // Toggle by changing the wetDryMix parameter — no graph rebuild needed
        isIsolationActive = enabled
        applyIsolationParameters()

        EnsembleLogger.debug("[AudioEngine] Isolation \(enabled ? "enabled" : "disabled")")
    }

    /// Wire the isolation effect into the audio graph for the first time.
    /// Requires stopping the engine and rescheduling — only called once.
    private func wireIsolationIntoGraph() throws {
        let position = currentTime()
        let wasActive = wasPlaying || activePlayerNode.isPlaying

        // Stop player and engine to rebuild connections safely.
        // The engine must be fully stopped (not just the playerNode) so that
        // when it restarts, it picks up any pending IO buffer preference change
        // (e.g. the larger buffer requested for AUSoundIsolation headroom).
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        playerNode.stop()
        smartMixPlayerNode.stop()
        engine.stop()
        playerTimeBaseOffset = 0

        // Rebuild graph with effect permanently in the chain
        // (passthrough when disabled via wetDryMix=0)
        buildGraph(format: currentFile?.processingFormat)

        // Reschedule from captured position
        if let file = currentFile {
            let startFrame = AVAudioFramePosition(position * sampleRate)
            let totalFrames = file.length
            if startFrame < totalFrames {
                seekFrameOffset = startFrame
                let frameCount = AVAudioFrameCount(totalFrames - startFrame)

                activePlayerNode.scheduleSegment(
                    file,
                    startingFrame: startFrame,
                    frameCount: frameCount,
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        self?.handleSegmentComplete(generation: myGeneration)
                    }
                }
            }
        }

        // Re-schedule any gapless files that were flushed by playerNode.stop()
        rescheduleGaplessFiles()

        // Always restart the engine (we stopped it above for graph rebuild).
        // This ensures the IO buffer preference is applied.
        try engine.start()

        #if !os(macOS)
        let ioBufferFrames = engine.outputNode.outputFormat(forBus: 0).sampleRate *
            AVAudioSession.sharedInstance().ioBufferDuration
        EnsembleLogger.debug("[AudioEngine] Engine restarted after isolation wire-up, IO buffer: \(String(format: "%.1f", AVAudioSession.sharedInstance().ioBufferDuration * 1000))ms (\(Int(ioBufferFrames)) frames)")
        #endif

        if wasActive {
            activePlayerNode.play()
            wasPlaying = true
            startTimeUpdates(from: position)
        }

        updateDurablePlaybackPosition(position)
    }

    /// Apply AUSoundIsolation parameters based on current isIsolationActive state.
    ///
    /// With the v0 model loaded, the AU performs high-quality vocal/instrumental separation.
    /// We isolate vocals (address 1 = 1.0) then use negative wetDryMix (-100) to get the
    /// complementary signal (instrumentals = original minus vocals).
    ///
    /// The wetDryMix range is -100 to 100:
    /// - 100 = fully isolated signal (vocals only)
    /// - 0 = 50/50 blend of original and isolated
    /// - -100 = fully complementary signal (instrumentals only)
    ///
    /// When disabled, the AU is bypassed via kAudioUnitProperty_BypassEffect so the neural
    /// network doesn't run at all — just setting wetDryMix=0 still invokes the render callback.
    ///
    /// Uses the C API because AUSoundIsolation hides parameters from the AUParameterTree.
    private func applyIsolationParameters(to effect: AVAudioUnitEffect? = nil) {
        let target = effect ?? isolationEffect
        guard let target else { return }
        let au = target.audioUnit

        // Bypass the AU entirely when isolation is off. This skips the neural network
        // render callback, eliminating CPU overhead when the effect isn't needed.
        // (wetDryMix=0 still runs inference — bypass is the only way to fully skip it)
        var bypass: UInt32 = isIsolationActive ? 0 : 1
        AudioUnitSetProperty(au, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0,
                             &bypass, UInt32(MemoryLayout<UInt32>.size))

        // Sound to Isolate: 0.0 = background/instruments, 1.0 = vocals
        // iOS: v0 model with soundToIsolate=0.0 isolates instrumentals directly.
        // macOS: AU always isolates vocals; use soundToIsolate=1.0 for cleanest output,
        //   then negative wetDryMix to get the complement (instrumentals).
        #if os(macOS)
        AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 1.0, 0)
        #else
        AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 0.0, 0)
        #endif

        // Wet/Dry Mix: 100 = fully isolated, 0 = original, -100 = complementary.
        // iOS: positive wetDryMix outputs instrumentals directly from v0 model.
        // macOS: negative wetDryMix outputs complement of isolated vocals (= instrumentals).
        let wetDryValue: AudioUnitParameterValue
        if isIsolationActive {
            #if os(macOS)
            wetDryValue = -100.0
            #else
            wetDryValue = 92.5
            #endif
        } else {
            wetDryValue = 0.0
        }
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, wetDryValue, 0)

        var wetDry: AudioUnitParameterValue = -999
        var isolate: AudioUnitParameterValue = -999
        AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &wetDry)
        AudioUnitGetParameter(au, 1, kAudioUnitScope_Global, 0, &isolate)
        EnsembleLogger.debug("[AudioEngine] Isolation params: wetDry=\(wetDry), soundToIsolate=\(isolate), active=\(isIsolationActive), bypass=\(bypass), modelLoaded=\(musicModelLoaded)")
    }

    /// Dump all parameters exposed by the AU via both the C API and the AUParameterTree.
    private func dumpAUParameters(au: AudioUnit, label: String) {
        EnsembleLogger.debug("[AudioEngine] === Parameter dump (\(label)) ===")

        // Try C API: probe known parameter addresses
        let knownAddresses: [AudioUnitParameterID] = [0, 1, 2, 3, 0x17626, 0x17627]
        for addr in knownAddresses {
            var value: AudioUnitParameterValue = -999
            let status = AudioUnitGetParameter(au, addr, kAudioUnitScope_Global, 0, &value)
            if status == noErr {
                EnsembleLogger.debug("[AudioEngine]   C-API param addr=\(addr) (0x\(String(addr, radix: 16))): value=\(value)")
            }
        }

        // Try AUParameterTree (may be empty for this AU)
        #if os(macOS)
        if #available(macOS 13.0, *) {
            if let avUnit = isolationEffect, let tree = avUnit.auAudioUnit.parameterTree {
                for param in tree.allParameters {
                    EnsembleLogger.debug("[AudioEngine]   Tree param: address=\(param.address), name='\(param.displayName)', min=\(param.minValue), max=\(param.maxValue), value=\(param.value)")
                }
            } else {
                EnsembleLogger.debug("[AudioEngine]   No AUParameterTree available")
            }
        } else {
            EnsembleLogger.debug("[AudioEngine]   AUParameterTree unavailable before macOS 13")
        }
        #else
        if let avUnit = isolationEffect, let tree = avUnit.auAudioUnit.parameterTree {
            for param in tree.allParameters {
                EnsembleLogger.debug("[AudioEngine]   Tree param: address=\(param.address), name='\(param.displayName)', min=\(param.minValue), max=\(param.maxValue), value=\(param.value)")
            }
        } else {
            EnsembleLogger.debug("[AudioEngine]   No AUParameterTree available")
        }
        #endif
        EnsembleLogger.debug("[AudioEngine] === End parameter dump ===")
    }

    // MARK: - File Loading

    /// Load an audio file for playback. Reconnects the graph with the file's native format.
    /// Schedules the full file so it's ready for `resume()` without a separate `play(from:)` call.
    /// (`play(from:)` and `seek(to:)` call `playerNode.stop()` first, which clears this schedule.)
    func load(
        fileURL: URL,
        trackId: String,
        playbackGeneration: UInt64 = 0
    ) throws {
        clearStreamingPipeline()
        cancelSmartMixTransition()
        activePlaybackDeck = .primary
        smartMixPlayerNode.stop()
        setVolume(1, for: .primary)
        setVolume(0, for: .smartMix)
        let file = try AVAudioFile(forReading: fileURL)
        currentFile = file
        currentTrackId = trackId
        playbackRequestGeneration = playbackGeneration
        sampleRate = file.processingFormat.sampleRate
        pendingRouteRecoveryPosition = nil

        // Read encoder delay/padding for gapless-accurate scheduling.
        // MP3 files have priming frames (encoder delay, ~576 for LAME) at the start
        // and padding at the end. Without trimming, gapless transitions have an
        // audible silence gap of ~50ms at each boundary.
        let (contentStart, contentFrames) = Self.readContentBounds(for: fileURL, fileLength: file.length)
        currentContentStartFrame = contentStart
        currentContentFrameCount = contentFrames
        fileDuration = Double(contentFrames) / sampleRate
        seekFrameOffset = 0
        playerTimeBaseOffset = 0
        updateDurablePlaybackPosition(0)

        // Clear any previously scheduled gapless files
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        scheduledFiles.removeAll()

        // Reconnect graph with the file's native format for optimal quality
        buildGraph(format: file.processingFormat)

        // Re-apply isolation parameters (reconnection can reset AU state)
        applyIsolationParameters()

        // Schedule the content portion of the file (skipping encoder delay/padding)
        // so resume() works without a prior play(from:).
        // This is critical for restore-to-paused: load() is called but play(from:)
        // is not, so without this the playerNode has nothing queued and resume()
        // would produce silence (or play prefetched gapless tracks instead).
        activePlayerNode.scheduleSegment(
            file,
            startingFrame: AVAudioFramePosition(contentStart),
            frameCount: contentFrames,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        let trimmed = contentStart > 0 ? ", trim=\(contentStart)+\(Int64(file.length) - Int64(contentStart) - Int64(contentFrames))" : ""
        EnsembleLogger.debug("[AudioEngine] Loaded: \(fileURL.lastPathComponent), rate=\(sampleRate), frames=\(contentFrames)/\(file.length)\(trimmed), duration=\(String(format: "%.1f", fileDuration))s, trackId=\(trackId)")
    }

    @MainActor
    func load(
        source: PlaybackSource,
        trackId: String,
        playbackGeneration: UInt64 = 0
    ) async throws {
        switch source {
        case let .localFile(url), let .cachedFile(url, _):
            try load(
                fileURL: url,
                trackId: trackId,
                playbackGeneration: playbackGeneration
            )
        case let .directHTTP(request, metadata), let .transcodedHTTP(request, metadata):
            try await loadStreamingSource(
                request: request,
                metadata: metadata,
                trackId: trackId,
                playbackGeneration: playbackGeneration
            )
        }
    }

    @MainActor
    private func loadStreamingSource(
        request: URLRequest,
        metadata: PlaybackSourceMetadata,
        trackId: String,
        playbackGeneration: UInt64
    ) async throws {
        cancelSmartMixTransition()
        clearStreamingPipeline()
        activePlaybackDeck = .primary
        smartMixPlayerNode.stop()
        setVolume(1, for: .primary)
        setVolume(0, for: .smartMix)
        currentFile = nil
        currentTrackId = trackId
        playbackRequestGeneration = playbackGeneration
        pendingRouteRecoveryPosition = nil
        seekFrameOffset = 0
        streamingStartTime = 0
        playerTimeBaseOffset = 0
        currentContentStartFrame = 0
        currentContentFrameCount = 0
        scheduledFiles.removeAll()
        updateDurablePlaybackPosition(0)

        let cacheURL = PlaybackStreamCacheIdentity.streamCacheDirectory
            .appendingPathComponent(PlaybackStreamCacheIdentity.fileName(
                for: trackId,
                pathExtension: metadata.cacheFileExtension
            ))
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: request,
            fileExtension: metadata.cacheFileExtension,
            cacheURL: cacheURL,
            duration: metadata.duration
        ))
        streamingPipeline = pipeline

        let format: AVAudioFormat
        do {
            format = try await startStreamingPipeline(
                pipeline,
                trackId: trackId,
                startTime: metadata.startTime,
                duration: metadata.duration,
                playbackGeneration: playbackGeneration,
                requiresCurrentPipeline: true
            )
        } catch {
            if streamingPipeline === pipeline {
                clearStreamingPipeline()
            }
            throw error
        }
        guard streamingPipeline === pipeline else { throw CancellationError() }
        sampleRate = format.sampleRate
        fileDuration = metadata.duration ?? 0
        streamingStartTime = Self.clampedPlaybackPosition(metadata.startTime, duration: fileDuration)
        seekFrameOffset = AVAudioFramePosition(streamingStartTime * sampleRate)
        currentContentFrameCount = AVAudioFrameCount(max(0, fileDuration * sampleRate))
        streamingCompletionNotified = false
        scheduleGeneration &+= 1
        streamingCompletionGeneration = scheduleGeneration
        let completionGeneration = streamingCompletionGeneration

        var didLogFirstAudibleRender = false
        var renderHealth = StreamingRenderHealth(
            recoveryThresholdFrames: AVAudioFramePosition(max(1, format.sampleRate))
        )
        let sourceNode = AVAudioSourceNode(format: format) { [weak self, weak pipeline] _, _, frameCount, audioBufferList in
            guard let self, let pipeline else { return noErr }
            let read = pipeline.render(into: audioBufferList, frameCount: frameCount)
            if read > 0, !didLogFirstAudibleRender {
                didLogFirstAudibleRender = true
                DispatchQueue.main.async { [weak self, weak pipeline] in
                    guard let self, let pipeline, self.streamingPipeline === pipeline else { return }
                    PlaybackJourneyLogger.mark("firstAudibleRender", trackId: trackId)
                    self.onFirstAudibleRender?(trackId, playbackGeneration)
                }
            }
            let isComplete = pipeline.isComplete
            if renderHealth.observe(
                renderedFrames: read,
                requestedFrames: frameCount,
                isComplete: isComplete
            ) {
                let missingFrames = renderHealth.missingFrameCount
                DispatchQueue.main.async { [weak self, weak pipeline] in
                    guard let self, let pipeline, self.streamingPipeline === pipeline else { return }
                    EnsembleLogger.error(
                        "[StreamingPipeline] PCM underrun trackId=\(trackId)"
                            + " missingFrames=\(missingFrames)"
                            + " \(pipeline.diagnostics().summary)"
                    )
                    self.onError?(
                        AudioPlaybackEngineError.streamingUnderrun,
                        nil,
                        playbackGeneration
                    )
                }
            }
            if read == 0, isComplete {
                DispatchQueue.main.async { [weak self, weak pipeline] in
                    guard let self, let pipeline, self.streamingPipeline === pipeline else { return }
                    self.handleStreamingComplete(generation: completionGeneration)
                }
            }
            return noErr
        }
        streamingSourceNode = sourceNode
        engine.attach(sourceNode)
        buildGraph(format: format)
        applyIsolationParameters()

        EnsembleLogger.debug(
            "[AudioEngine] Loaded streaming source trackId=\(trackId)"
            + " rate=\(sampleRate)"
            + " duration=\(String(format: "%.1f", fileDuration))s"
            + " start=\(String(format: "%.1f", streamingStartTime))s"
            + " ext=\(metadata.cacheFileExtension)"
        )
    }

    @MainActor
    func startStreamingPipeline(
        _ pipeline: StreamingAudioPipeline,
        trackId: String,
        startTime: TimeInterval,
        duration: TimeInterval?,
        playbackGeneration: UInt64 = 0,
        requiresCurrentPipeline: Bool = false
    ) async throws -> AVAudioFormat {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            let resumeOnce: (Result<AVAudioFormat, Error>) -> Void = { result in
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                lock.unlock()
                continuation.resume(with: result)
            }
            pipeline.onFirstByte = {
                PlaybackJourneyLogger.mark("firstResponseByte", trackId: trackId)
                EnsembleLogger.debug("[StreamingPipeline] first byte trackId=\(trackId)")
            }
            pipeline.onFirstPacket = {
                PlaybackJourneyLogger.mark("firstParsedPacket", trackId: trackId)
                EnsembleLogger.debug("[StreamingPipeline] first packet trackId=\(trackId)")
            }
            pipeline.onFirstPCM = {
                PlaybackJourneyLogger.mark("firstDecodedPCMFrame", trackId: trackId)
                EnsembleLogger.debug("[StreamingPipeline] first PCM trackId=\(trackId)")
            }
            pipeline.onBufferedProgress = { [weak self, weak pipeline] progress in
                let absoluteProgress = Self.absoluteStreamingBufferedProgress(
                    progress,
                    startTime: startTime,
                    duration: duration
                )
                DispatchQueue.main.async { [weak self, weak pipeline] in
                    guard let self, let pipeline,
                          !requiresCurrentPipeline || self.streamingPipeline === pipeline else { return }
                    self.onBufferedProgress?(
                        trackId,
                        playbackGeneration,
                        absoluteProgress
                    )
                }
            }
            pipeline.onFormatReady = { format in
                resumeOnce(.success(format))
            }
            pipeline.onFailure = { [weak self, weak pipeline] error in
                let nsError = error as NSError
                lock.lock()
                let didStart = didResume
                lock.unlock()
                if didStart {
                    guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else {
                        return
                    }
                    DispatchQueue.main.async { [weak self, weak pipeline] in
                        guard let self, let pipeline,
                              !requiresCurrentPipeline || self.streamingPipeline === pipeline else { return }
                        EnsembleLogger.error("[StreamingPipeline] failed after startup trackId=\(trackId): \(error.localizedDescription)")
                        self.onError?(error, nil, playbackGeneration)
                    }
                } else {
                    resumeOnce(.failure(error))
                }
            }
            pipeline.start()
        }
    }

    static func absoluteStreamingBufferedProgress(
        _ streamProgress: Double,
        startTime: TimeInterval,
        duration: TimeInterval?
    ) -> Double {
        let boundedStreamProgress = min(max(streamProgress, 0), 1)
        guard
            let duration,
            duration.isFinite,
            duration > 0,
            startTime.isFinite,
            startTime > 0
        else {
            return boundedStreamProgress
        }

        let startProgress = min(max(startTime / duration, 0), 1)
        return min(max(startProgress + boundedStreamProgress, startProgress), 1)
    }

    private func clearStreamingPipeline() {
        streamingPipeline?.cancel()
        streamingPipeline = nil
        streamingStartTime = 0
        if let streamingSourceNode {
            engine.disconnectNodeOutput(streamingSourceNode)
            engine.detach(streamingSourceNode)
        }
        streamingSourceNode = nil
        streamingCompletionNotified = false
    }

    // MARK: - Gapless Scheduling

    /// Re-schedule all queued gapless files on the playerNode after a stop/flush.
    /// Uses each entry's stored content bounds to preserve encoder delay trimming.
    /// Called from handleConfigurationChange(), wireIsolationIntoGraph(), and seek().
    private func rescheduleGaplessFiles() {
        for entry in scheduledFiles {
            let entryGen = scheduleGeneration
            activePlayerNode.scheduleSegment(
                entry.file,
                startingFrame: AVAudioFramePosition(entry.contentStartFrame),
                frameCount: entry.contentFrameCount,
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleScheduledFileComplete(trackId: entry.trackId, generation: entryGen)
                }
            }
        }
    }

    /// Whether a track is already in the gapless schedule queue.
    func isTrackScheduled(_ trackId: String) -> Bool {
        scheduledFiles.contains { $0.trackId == trackId }
    }

    /// IDs of all tracks currently in the gapless schedule queue.
    var scheduledTrackIds: Set<String> {
        Set(scheduledFiles.map(\.trackId))
    }

    /// IDs of tracks in the player node's gapless FIFO, preserving playback order.
    var scheduledTrackIdsInOrder: [String] {
        scheduledFiles.map(\.trackId)
    }

    var isSmartMixTransitionActive: Bool {
        smartMixTransition != nil
    }

    var smartMixIncomingTrackId: String? {
        smartMixTransition?.trackId
    }

    var smartMixTransitionElapsed: TimeInterval {
        guard let transition = smartMixTransition else { return 0 }
        return max(0, CACurrentMediaTime() - transition.startedAtWallTime)
    }

    var smartMixSkipThreshold: TimeInterval {
        smartMixTransition?.skipThreshold ?? 0
    }

    var hasPromotedSmartMixTransition: Bool {
        smartMixTransition?.promoted == true
    }

    /// Schedule the next file for gapless playback. Uses AVAudioPlayerNode's FIFO queue --
    /// the segment plays immediately after the current segment finishes, with zero gap.
    /// Reads the file's packet table to trim encoder delay/padding for seamless transitions.
    /// Call this during prefetch to ensure seamless transitions.
    func scheduleNext(fileURL: URL, trackId: String) throws {
        let file = try AVAudioFile(forReading: fileURL)

        // Read encoder delay/padding so the gapless boundary is sample-accurate
        let (contentStart, contentFrames) = Self.readContentBounds(for: fileURL, fileLength: file.length)

        // Don't bump scheduleGeneration here — that would invalidate the current
        // segment's completion handler. The generation counter only needs to change
        // when playerNode.stop() is called (which fires all pending callbacks as stale).
        // scheduleNext just appends to the FIFO queue; no stop, no stale callbacks.
        let myGeneration = scheduleGeneration

        // Schedule only the content portion (skipping encoder delay/padding)
        activePlayerNode.scheduleSegment(
            file,
            startingFrame: AVAudioFramePosition(contentStart),
            frameCount: contentFrames,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleScheduledFileComplete(trackId: trackId, generation: myGeneration)
            }
        }

        scheduledFiles.append((file: file, trackId: trackId, generation: myGeneration, contentStartFrame: contentStart, contentFrameCount: contentFrames))

        let scheduledDuration = Double(contentFrames) / file.processingFormat.sampleRate
        let trimInfo = contentStart > 0 ? ", trim=\(contentStart)+\(Int64(file.length) - Int64(contentStart) - Int64(contentFrames))" : ""
        EnsembleLogger.debug("[AudioEngine] Scheduled next: \(fileURL.lastPathComponent), trackId=\(trackId), frames=\(contentFrames)/\(file.length), duration=\(String(format: "%.1f", scheduledDuration))s, queueDepth=\(scheduledFiles.count)\(trimInfo)")
    }

    func scheduleSmartMixNext(fileURL: URL, trackId: String, plan: SmartMixPlan) throws {
        guard smartMixTransition == nil else { return }
        guard currentFile != nil, wasPlaying else {
            try scheduleNext(fileURL: fileURL, trackId: trackId)
            return
        }

        let primaryDeckFormat = currentFile?.processingFormat
        let file = try AVAudioFile(forReading: fileURL)
        guard Self.smartMixFormatsMatch(primaryDeckFormat, file.processingFormat) else {
            EnsembleLogger.debug(
                "[AudioEngine] SmartMix fallback: deck formats differ"
                + " current=\(String(describing: primaryDeckFormat))"
                + " incoming=\(file.processingFormat)"
            )
            try scheduleNext(fileURL: fileURL, trackId: trackId)
            return
        }

        let incomingRate = file.processingFormat.sampleRate
        let (contentStart, contentFrames) = Self.readContentBounds(for: fileURL, fileLength: file.length)
        let incomingStartFrame = contentStart + AVAudioFramePosition(plan.incomingStartTime * incomingRate)
        let contentEnd = contentStart + AVAudioFramePosition(contentFrames)
        guard incomingStartFrame < contentEnd else {
            try scheduleNext(fileURL: fileURL, trackId: trackId)
            return
        }

        smartMixFadeTimer?.cancel()
        smartMixFadeTimer = nil
        scheduledFiles.removeAll()
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        let outgoingDeck = activePlaybackDeck
        let incomingDeck = outgoingDeck.opposite
        let incomingPlayer = playerNode(for: incomingDeck)

        resetSmartMixEffects()
        timePitchNode(for: incomingDeck).rate = Float(plan.incomingPlaybackRate)
        timePitchNode(for: outgoingDeck).rate = 1
        incomingPlayer.stop()
        setVolume(0, for: incomingDeck)
        setVolume(1, for: outgoingDeck)

        incomingPlayer.scheduleSegment(
            file,
            startingFrame: incomingStartFrame,
            frameCount: AVAudioFrameCount(contentEnd - incomingStartFrame),
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSmartMixIncomingComplete(generation: myGeneration)
            }
        }

        if !engine.isRunning {
            try engine.start()
            applyIsolationParameters()
        }

        incomingPlayer.play()
        smartMixTransition = SmartMixEngineTransition(
            file: file,
            trackId: trackId,
            outgoingDeck: outgoingDeck,
            incomingDeck: incomingDeck,
            contentStartFrame: contentStart,
            contentFrameCount: contentFrames,
            sampleRate: incomingRate,
            duration: Double(contentFrames) / incomingRate,
            incomingStartTime: plan.incomingStartTime,
            transitionDuration: plan.transitionDuration,
            skipThreshold: plan.skipToIncomingThreshold,
            incomingPlaybackRate: plan.incomingPlaybackRate,
            outgoingPlaybackRate: plan.outgoingPlaybackRate,
            highPassSweep: plan.outgoingHighPassSweep,
            generation: myGeneration,
            startedAtWallTime: CACurrentMediaTime()
        )
        onSmartMixTransitionActiveChanged?(true, playbackRequestGeneration)
        startSmartMixFadeTimer()

        EnsembleLogger.debug(
            "[AudioEngine] SmartMix started trackId=\(trackId)"
            + " transition=\(String(format: "%.1f", plan.transitionDuration))s"
            + " incomingStart=\(String(format: "%.1f", plan.incomingStartTime))s"
            + " rate=\(String(format: "%.3f", plan.incomingPlaybackRate))"
            + " outgoingRate=\(String(format: "%.3f", plan.outgoingPlaybackRate))"
            + " tempoMatched=\(plan.tempoMatched)"
            + " outgoingDeck=\(outgoingDeck.rawValue)"
            + " incomingDeck=\(incomingDeck.rawValue)"
        )
    }

    func acceptSmartMixIncomingTrack() {
        guard smartMixTransition != nil else { return }
        promoteSmartMixIfNeeded()
        finishSmartMixTransition(continueAt: currentSmartMixIncomingTime())
    }

    func cancelSmartMixTransition(continueIncoming: Bool = false) {
        guard smartMixTransition != nil else {
            stopInactiveDeck()
            setVolume(1, for: activePlaybackDeck)
            resetSmartMixEffects()
            return
        }
        if continueIncoming {
            promoteSmartMixIfNeeded()
            finishSmartMixTransition(continueAt: currentSmartMixIncomingTime())
            return
        }

        smartMixFadeTimer?.cancel()
        smartMixFadeTimer = nil
        if let transition = smartMixTransition {
            playerNode(for: transition.incomingDeck).stop()
            setVolume(0, for: transition.incomingDeck)
            setVolume(1, for: transition.outgoingDeck)
        }
        resetSmartMixEffects()
        smartMixTransition = nil
        onSmartMixTransitionActiveChanged?(false, playbackRequestGeneration)
        EnsembleLogger.debug("[AudioEngine] SmartMix cancelled")
    }

    private func startSmartMixFadeTimer() {
        smartMixFadeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timeUpdateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.updateSmartMixFade()
            }
        }
        timer.resume()
        smartMixFadeTimer = timer
    }

    private func updateSmartMixFade() {
        guard let transition = smartMixTransition else { return }
        let elapsed = smartMixTransitionElapsed
        let progress = min(max(elapsed / max(transition.transitionDuration, 0.001), 0), 1)
        setVolume(Float(cos(progress * .pi / 2)), for: transition.outgoingDeck)
        setVolume(Float(sin(progress * .pi / 2)), for: transition.incomingDeck)
        applySmartMixHighPass(progress: progress, transition: transition)
        applySmartMixTempoRamp(progress: progress, transition: transition)

        if elapsed >= transition.midpoint {
            promoteSmartMixIfNeeded()
        }

        if elapsed >= transition.transitionDuration {
            finishSmartMixTransition(continueAt: currentSmartMixIncomingTime())
        }
    }

    private func applySmartMixHighPass(progress: Double, transition: SmartMixEngineTransition) {
        guard let sweep = transition.highPassSweep,
              let band = highPassEQ(for: transition.outgoingDeck).bands.first
        else {
            resetHighPass(for: transition.outgoingDeck)
            return
        }

        band.bypass = false
        band.frequency = Self.smartMixHighPassFrequency(
            progress: progress,
            sweep: sweep,
            sampleRate: sampleRate
        )
    }

    private func applySmartMixTempoRamp(progress: Double, transition: SmartMixEngineTransition) {
        timePitchNode(for: transition.outgoingDeck).rate = Self.smartMixTempoRate(
            progress: progress,
            targetRate: transition.outgoingPlaybackRate
        )
    }

    private func promoteSmartMixIfNeeded() {
        guard var transition = smartMixTransition, !transition.promoted else { return }
        let incomingPosition = currentSmartMixIncomingTime()
        transition.promoted = true
        smartMixTransition = transition
        currentTrackId = transition.trackId
        currentFile = transition.file
        currentContentStartFrame = transition.contentStartFrame
        currentContentFrameCount = transition.contentFrameCount
        sampleRate = transition.sampleRate
        fileDuration = transition.duration
        seekFrameOffset = AVAudioFramePosition(incomingPosition * transition.sampleRate)
        playerTimeBaseOffset = 0
        captureWallTimeBase(position: incomingPosition)
        updateDurablePlaybackPosition(incomingPosition)
        onSmartMixPromote?(transition.trackId, playbackRequestGeneration)
        EnsembleLogger.debug("[AudioEngine] SmartMix promoted trackId=\(transition.trackId)")
    }

    private func finishSmartMixTransition(continueAt position: TimeInterval) {
        guard smartMixTransition != nil else { return }
        promoteSmartMixIfNeeded()
        smartMixFadeTimer?.cancel()
        smartMixFadeTimer = nil

        guard let transition = smartMixTransition else { return }
        let clampedPosition = min(max(0, position), max(0, transition.duration - 0.05))

        currentFile = transition.file
        currentTrackId = transition.trackId
        currentContentStartFrame = transition.contentStartFrame
        currentContentFrameCount = transition.contentFrameCount
        sampleRate = transition.sampleRate
        fileDuration = transition.duration
        scheduledFiles.removeAll()
        activePlaybackDeck = transition.incomingDeck
        seekFrameOffset = AVAudioFramePosition(clampedPosition * transition.sampleRate)
        if let nodeTime = activePlayerNode.lastRenderTime,
           let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) {
            playerTimeBaseOffset = playerTime.sampleTime
        } else {
            playerTimeBaseOffset = 0
        }
        setVolume(0, for: transition.outgoingDeck)
        setVolume(1, for: transition.incomingDeck)
        playerNode(for: transition.outgoingDeck).stop()
        resetHighPass(for: transition.outgoingDeck)
        resetTimePitch(for: transition.outgoingDeck)
        resetTimePitch(for: transition.incomingDeck)
        smartMixTransition = nil
        onSmartMixTransitionActiveChanged?(false, playbackRequestGeneration)

        wasPlaying = true
        startTimeUpdates(from: clampedPosition)
        updateDurablePlaybackPosition(clampedPosition)

        EnsembleLogger.debug(
            "[AudioEngine] SmartMix deck handoff complete"
            + " trackId=\(transition.trackId)"
            + " activeDeck=\(activePlaybackDeck.rawValue)"
            + " position=\(String(format: "%.1f", clampedPosition))s"
        )
    }

    private func currentSmartMixIncomingTime() -> TimeInterval {
        guard let transition = smartMixTransition else { return currentTimeSubject.value }
        let elapsed = max(0, CACurrentMediaTime() - transition.startedAtWallTime)
        return Self.smartMixIncomingPosition(
            incomingStartTime: transition.incomingStartTime,
            elapsed: elapsed,
            incomingPlaybackRate: transition.incomingPlaybackRate,
            duration: transition.duration
        )
    }

    private func handleSmartMixIncomingComplete(generation: UInt64) {
        guard let transition = smartMixTransition else {
            handleSegmentComplete(generation: generation)
            return
        }
        guard transition.generation == generation else { return }
        promoteSmartMixIfNeeded()
        finishSmartMixTransition(continueAt: transition.duration)
    }

    /// Remove a single scheduled track by ID (e.g. when a gapless-scheduled file fails to decode).
    /// Only removes it from the tracking array — the playerNode's FIFO segment cannot be surgically
    /// removed, but its completion callback will find no matching entry and be ignored.
    func removeScheduledTrack(_ trackId: String) {
        if let idx = scheduledFiles.firstIndex(where: { $0.trackId == trackId }) {
            scheduledFiles.remove(at: idx)
            EnsembleLogger.debug("[AudioEngine] Removed scheduled track \(trackId), queueDepth=\(scheduledFiles.count)")
        }
    }

    /// Remove all pending gapless files from the schedule.
    /// Called when the queue changes (skip, shuffle, etc.) to prevent stale transitions.
    ///
    /// This flushes the playerNode's actual FIFO queue (via stop + re-schedule) so
    /// that orphaned audio segments don't play after our tracking array is cleared.
    /// Without the flush, a desync between the FIFO and `scheduledFiles` causes the
    /// primary segment's completion handler to be silently ignored (stale generation),
    /// leaving the UI one track behind the audio.
    func clearScheduledFiles() {
        cancelSmartMixTransition()
        let hadScheduledFiles = !scheduledFiles.isEmpty
        scheduledFiles.removeAll()

        // If nothing was scheduled, return WITHOUT bumping the generation.
        // Bumping the generation here would invalidate the currently playing
        // segment's completion handler, preventing gapless advance when the
        // track finishes. This was the root cause of "audio advances but UI
        // stays on old track" — queue mutations (autoplay add/trim, playNext,
        // etc.) that call clearScheduledFiles when no gapless files are queued
        // would silently kill the current segment's callback.
        guard hadScheduledFiles else {
            EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (nothing queued, gen unchanged=\(scheduleGeneration))")
            return
        }

        // Had scheduled files but no current file — unusual state.
        // Bump generation to invalidate the orphaned handlers, but we can't
        // flush the FIFO since there's no track to re-schedule.
        guard let file = currentFile else {
            scheduleGeneration &+= 1
            EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (no current file, bumped gen=\(scheduleGeneration))")
            return
        }

        // Capture position before stopping so we can re-anchor seamlessly
        let position = currentTime()
        let wasActive = wasPlaying || activePlayerNode.isPlaying

        // Bump generation AFTER capturing position — this invalidates all pending
        // completion handlers (both primary segment and gapless entries)
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        // Flush the active deck's FIFO (removes orphaned audio segments)
        activePlayerNode.stop()
        playerTimeBaseOffset = 0

        // Re-schedule only the current track from the current position.
        // Convert user-visible time to file frame space by adding the content offset.
        let userFrame = AVAudioFramePosition(position * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            // Current track already at/past end — let natural completion handle it
            EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (track at end)")
            onPlaybackComplete?(playbackRequestGeneration)
            return
        }

        seekFrameOffset = userFrame
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        activePlayerNode.scheduleSegment(
            file,
            startingFrame: fileFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        // Resume playback if it was active — the gap is imperceptible (microseconds)
        if wasActive {
            if !engine.isRunning {
                try? engine.start()
                applyIsolationParameters()
            }
            activePlayerNode.play()
            wasPlaying = true
            startTimeUpdates(from: position)
        }

        EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (flushed FIFO, re-anchored at \(String(format: "%.1f", position))s)")
    }

    // MARK: - Playback Control

    /// Starts the output graph without a player node so an already-active,
    /// mixable session can span a short MusicKit-to-native provider boundary.
    func startProviderHandoffBridge(playbackGeneration: UInt64) throws {
        stop()
        playbackRequestGeneration = playbackGeneration
        currentFile = nil
        currentTrackId = nil
        fileDuration = 0
        buildGraph(format: nil)
        applyIsolationParameters()
        isProviderHandoffBridgeActive = true
        do {
            try engine.start()
        } catch {
            isProviderHandoffBridgeActive = false
            throw error
        }
        EnsembleLogger.debug("[AudioEngine] Provider handoff bridge started")
    }

    func adoptPlaybackGeneration(_ playbackGeneration: UInt64) {
        playbackRequestGeneration = playbackGeneration
    }

    /// Schedule and start playback from the given time offset (in user-visible seconds).
    func play(from time: TimeInterval = 0) throws {
        let wasProviderHandoffBridgeActive = isProviderHandoffBridgeActive
        cancelSmartMixTransition()
        if streamingPipeline != nil {
            pendingRouteRecoveryPosition = nil
            let startPosition = time > 0 ? time : streamingStartTime
            seekFrameOffset = AVAudioFramePosition(startPosition * sampleRate)
            playerTimeBaseOffset = 0
            if !engine.isRunning {
                try engine.start()
            }
            applyIsolationParameters()
            wasPlaying = true
            isProviderHandoffBridgeActive = false
            startTimeUpdates(from: startPosition)
            EnsembleLogger.debug(
                "[ProviderHandoff] native claim track=\(currentTrackId ?? "none")"
                    + " wasBridgeActive=\(wasProviderHandoffBridgeActive)"
                    + " running=\(engine.isRunning) bridgeActive=\(isProviderHandoffBridgeActive)"
            )
            EnsembleLogger.debug("[AudioEngine] Streaming play from \(String(format: "%.1f", startPosition))s")
            return
        }
        guard let file = currentFile else {
            throw AudioPlaybackEngineError.noFileLoaded
        }
        pendingRouteRecoveryPosition = nil

        // Convert user-visible time to file frame space
        let userFrame = AVAudioFramePosition(time * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            onPlaybackComplete?(playbackRequestGeneration)
            return
        }

        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        seekFrameOffset = userFrame
        playerTimeBaseOffset = 0
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        activePlayerNode.stop()
        file.framePosition = fileFrame
        activePlayerNode.scheduleSegment(
            file,
            startingFrame: fileFrame,
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

        // Re-apply isolation params after engine start (can reset AU state)
        applyIsolationParameters()

        activePlayerNode.play()
        wasPlaying = true
        isProviderHandoffBridgeActive = false
        startTimeUpdates(from: time)
        EnsembleLogger.debug(
            "[ProviderHandoff] native claim track=\(currentTrackId ?? "none")"
                + " wasBridgeActive=\(wasProviderHandoffBridgeActive)"
                + " running=\(engine.isRunning) bridgeActive=\(isProviderHandoffBridgeActive)"
        )
        if let currentTrackId {
            PlaybackJourneyLogger.mark("firstAudibleRender", trackId: currentTrackId, detail: "fileBacked")
            onFirstAudibleRender?(currentTrackId, playbackRequestGeneration)
        }

        EnsembleLogger.debug("[AudioEngine] Playing from \(String(format: "%.1f", time))s (frame \(fileFrame)/\(currentContentFrameCount))")
    }

    /// Pause playback and suspend the engine.
    ///
    /// Suspending the engine is essential: while `playerNode.pause()` silences audio,
    /// the engine's render cycle continues pulling frames from CoreAudio. iOS detects
    /// this active render cycle and overrides the system playback state,
    /// causing the lock screen to show "playing" even though audio is paused.
    ///
    /// Streaming keeps its prepared render graph so AirPlay can resume the source node
    /// without rebuilding released engine resources. File playback retains the full
    /// stop used by its player-node resume path.
    func pause() {
        isProviderHandoffBridgeActive = false
        cancelSmartMixTransition(continueIncoming: hasPromotedSmartMixTransition)
        let position = snapshotPlaybackPositionBeforeStopping()
        playerNode.pause()
        smartMixPlayerNode.pause()
        wasPlaying = false
        stopTimeUpdates()
        if engine.isRunning {
            if streamingPipeline != nil {
                engine.pause()
            } else {
                engine.stop()
            }
        }
        let suspension = streamingPipeline == nil ? "stopped" : "paused"
        EnsembleLogger.debug("[AudioEngine] Paused (engine \(suspension)) at \(String(format: "%.1f", position))s")
    }

    /// Resume playback after pause.
    ///
    /// The engine may have been paused or stopped during `pause()`, so we restart it here.
    /// Restarting a stopped engine can reset AU state, so re-apply isolation parameters.
    func resume() throws {
        let wasProviderHandoffBridgeActive = isProviderHandoffBridgeActive
        if !engine.isRunning {
            try engine.start()
            // Engine restart can reset AU state — re-apply isolation parameters
            applyIsolationParameters()
        }
        if isProviderHandoffBridgeActive, currentTrackId == nil {
            EnsembleLogger.debug(
                "[ProviderHandoff] provider bridge resumed generation=\(playbackRequestGeneration)"
            )
            return
        }
        if streamingPipeline != nil {
            let observedPosition = currentTimeSubject.value
            wasPlaying = true
            isProviderHandoffBridgeActive = false
            startTimeUpdates(from: observedPosition)
            updateDurablePlaybackPosition(observedPosition)
            EnsembleLogger.debug(
                "[ProviderHandoff] native resume claim track=\(currentTrackId ?? "none")"
                    + " wasBridgeActive=\(wasProviderHandoffBridgeActive)"
                    + " running=\(engine.isRunning) bridgeActive=\(isProviderHandoffBridgeActive)"
            )
            EnsembleLogger.debug("[AudioEngine] Streaming resumed")
            return
        }
        let observedPosition = currentTimeSubject.value
        let resumePosition = Self.resolvedRouteRecoveryPosition(
            livePosition: currentTime(),
            observedPosition: observedPosition,
            duration: fileDuration,
            preferredSnapshot: observedPosition > 0 ? observedPosition : nil
        )
        activePlayerNode.play()
        if let transition = smartMixTransition {
            playerNode(for: transition.incomingDeck).play()
        }
        wasPlaying = true
        isProviderHandoffBridgeActive = false
        startTimeUpdates(from: resumePosition)
        updateDurablePlaybackPosition(resumePosition)
        EnsembleLogger.debug(
            "[ProviderHandoff] native resume claim track=\(currentTrackId ?? "none")"
                + " wasBridgeActive=\(wasProviderHandoffBridgeActive)"
                + " running=\(engine.isRunning) bridgeActive=\(isProviderHandoffBridgeActive)"
        )
        EnsembleLogger.debug("[AudioEngine] Resumed")
    }

    /// Stop playback, reset position, and stop the engine.
    func stop() {
        isProviderHandoffBridgeActive = false
        cancelSmartMixTransition()
        scheduleGeneration &+= 1
        stopTimeUpdates()
        playerNode.stop()
        smartMixPlayerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        clearStreamingPipeline()
        wasPlaying = false
        playbackRequestGeneration = 0
        streamingStartTime = 0
        seekFrameOffset = 0
        playerTimeBaseOffset = 0
        currentContentStartFrame = 0
        currentContentFrameCount = 0
        pendingRouteRecoveryPosition = nil
        scheduledFiles.removeAll()
        updateDurablePlaybackPosition(0)
        EnsembleLogger.debug("[AudioEngine] Stopped")
    }

    /// Seek to a new position within the current file (in user-visible seconds).
    func seek(to time: TimeInterval) throws {
        cancelSmartMixTransition(continueIncoming: hasPromotedSmartMixTransition)
        if streamingPipeline != nil {
            throw AudioPlaybackEngineError.streamingSeekUnavailable
        }
        guard let file = currentFile else { return }
        pendingRouteRecoveryPosition = nil

        let wasPlayingBeforeSeek = wasPlaying || activePlayerNode.isPlaying

        // Bump generation to suppress the completion callback from playerNode.stop()
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        activePlayerNode.stop()
        playerTimeBaseOffset = 0

        // Convert user-visible time to file frame space
        let userFrame = AVAudioFramePosition(time * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            onPlaybackComplete?(playbackRequestGeneration)
            return
        }

        seekFrameOffset = userFrame
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        file.framePosition = fileFrame
        activePlayerNode.scheduleSegment(
            file,
            startingFrame: fileFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        // Re-schedule any gapless files that were cleared by playerNode.stop()
        rescheduleGaplessFiles()

        if wasPlayingBeforeSeek {
            if !engine.isRunning {
                try engine.start()
            }
            activePlayerNode.play()
            wasPlaying = true
            startTimeUpdates(from: time)
        }

        // Update time immediately for responsive UI
        updateDurablePlaybackPosition(time)
        EnsembleLogger.debug("[AudioEngine] Seeked to \(String(format: "%.1f", time))s")
    }

    // MARK: - Time Tracking

    /// Compute current playback time from player node render position.
    func currentTime() -> TimeInterval {
        if smartMixTransition?.promoted == true {
            return updateDurablePlaybackPosition(currentSmartMixIncomingTime(), publish: false)
        }
        guard let renderClockPosition = currentRenderClockPosition() else {
            return Self.resolvedCurrentPlaybackPosition(
                renderClockPosition: nil,
                durablePlaybackPosition: durablePlaybackPosition,
                duration: fileDuration
            )
        }
        return updateDurablePlaybackPosition(renderClockPosition, publish: false)
    }

    /// Returns the current playhead from AVAudioPlayerNode's live render clock.
    /// This becomes unavailable during route transitions before our fallback state
    /// has been updated, so callers must handle `nil` explicitly.
    private func currentRenderClockPosition() -> TimeInterval? {
        guard let nodeTime = activePlayerNode.lastRenderTime,
              let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }

        return Self.resolvedPlaybackPosition(
            renderSampleTime: playerTime.sampleTime,
            playerTimeBaseOffset: playerTimeBaseOffset,
            seekFrameOffset: seekFrameOffset,
            sampleRate: sampleRate
        )
    }

    /// Start periodic time updates at ~10Hz using wall-clock estimation.
    /// Uses CACurrentMediaTime() to estimate playback position without touching
    /// playerNode.lastRenderTime, which would acquire the AVAudioNode render lock
    /// and risk priority inversion with the IO thread.
    ///
    /// - Parameter position: Known playback position to anchor from. If nil,
    ///   reads from `currentTime()` (only safe when called from a discrete user
    ///   action, never from a periodic timer).
    private func startTimeUpdates(from position: TimeInterval? = nil) {
        stopTimeUpdates()
        captureWallTimeBase(position: position)
        let timer = DispatchSource.makeTimerSource(queue: timeUpdateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Read the struct once — value copy gives a consistent snapshot even
            // if the main thread updates it mid-read during a gapless transition.
            let base = self.timeBase
            let elapsed = CACurrentMediaTime() - base.wallTime
            let estimated = min(base.position + elapsed, base.duration)
            self.updateDurablePlaybackPosition(max(0, estimated))
            if self.streamingPipeline != nil,
               base.duration > 0,
               estimated >= base.duration,
               self.wasPlaying,
               !self.streamingCompletionNotified {
                let generation = self.streamingCompletionGeneration
                DispatchQueue.main.async { [weak self] in
                    self?.handleStreamingComplete(generation: generation)
                }
            }
        }
        timer.resume()
        timeUpdateTimer = timer
    }

    /// Capture the current wall clock and playback position for time estimation.
    /// Called at play, resume, seek, and gapless transitions to re-anchor.
    ///
    /// - Parameter position: Known position to use. Pass this when the exact
    ///   position is already known (seek, play) to avoid calling currentTime()
    ///   which accesses playerNode.lastRenderTime.
    private func captureWallTimeBase(position: TimeInterval? = nil) {
        let basePosition = position ?? currentTime()
        timeBase = TimeBase(
            wallTime: CACurrentMediaTime(),
            position: basePosition,
            duration: fileDuration
        )
        updateDurablePlaybackPosition(basePosition, publish: false)
    }

    @discardableResult
    private func updateDurablePlaybackPosition(_ position: TimeInterval, publish: Bool = true) -> TimeInterval {
        let clamped = Self.clampedPlaybackPosition(position, duration: fileDuration)
        durablePlaybackPosition = clamped
        if publish {
            currentTimeSubject.send(clamped)
        }
        return clamped
    }

    /// Stop periodic time updates.
    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    /// Persist the current user-visible playhead before stopping the engine.
    /// Route changes often pause first and deliver the config-change callback later,
    /// after `lastRenderTime` is gone. Updating `seekFrameOffset` here gives route
    /// recovery and resume a durable source of truth for the paused position.
    private func snapshotPlaybackPositionBeforeStopping() -> TimeInterval {
        let position = Self.resolvedRouteRecoveryPosition(
            livePosition: currentTime(),
            observedPosition: durablePlaybackPosition,
            duration: fileDuration,
            preferredSnapshot: pendingRouteRecoveryPosition
        )
        seekFrameOffset = AVAudioFramePosition(position * sampleRate)
        playerTimeBaseOffset = 0
        captureWallTimeBase(position: position)
        updateDurablePlaybackPosition(position)
        pendingRouteRecoveryPosition = nil
        return position
    }

    static func resolvedCurrentPlaybackPosition(
        renderClockPosition: TimeInterval?,
        durablePlaybackPosition: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        if let renderClockPosition {
            return clampedPlaybackPosition(renderClockPosition, duration: duration)
        }

        return clampedPlaybackPosition(durablePlaybackPosition, duration: duration)
    }

    static func resolvedRouteRecoveryPosition(
        livePosition: TimeInterval,
        observedPosition: TimeInterval,
        duration: TimeInterval,
        preferredSnapshot: TimeInterval? = nil
    ) -> TimeInterval {
        let upperBound = duration > 0 ? duration : max(livePosition, observedPosition)
        let clampedLive = min(max(livePosition, 0), upperBound)
        let clampedObserved = min(max(observedPosition, 0), upperBound)
        let clampedSnapshot = preferredSnapshot.map { min(max($0, 0), upperBound) }

        if let clampedSnapshot {
            return clampedSnapshot
        }

        // Route changes can transiently zero the engine's render position while
        // the wall-clock observer still has the correct in-flight playhead.
        if clampedLive <= 0.25, clampedObserved > 1.0 {
            return clampedObserved
        }

        if clampedLive > 0 {
            return clampedLive
        }

        return clampedObserved
    }

    static func resolvedPreparedRouteRecoveryPosition(
        renderClockPosition: TimeInterval?,
        observedPosition: TimeInterval,
        fallbackPosition: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        if let renderClockPosition {
            return resolvedRouteRecoveryPosition(
                livePosition: renderClockPosition,
                observedPosition: observedPosition,
                duration: duration
            )
        }

        let upperBound = duration > 0 ? duration : max(observedPosition, fallbackPosition)
        let clampedObserved = min(max(observedPosition, 0), upperBound)
        if clampedObserved > 0.25 {
            return clampedObserved
        }

        return min(max(fallbackPosition, 0), upperBound)
    }

    private static func clampedPlaybackPosition(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let lowerBounded = max(position, 0)
        guard duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    static func resolvedPlaybackPosition(
        renderSampleTime: AVAudioFramePosition?,
        playerTimeBaseOffset: AVAudioFramePosition,
        seekFrameOffset: AVAudioFramePosition,
        sampleRate: Double
    ) -> TimeInterval {
        guard let renderSampleTime else {
            return max(0, TimeInterval(seekFrameOffset) / sampleRate)
        }

        // playerTime.sampleTime accumulates across gapless segments (playerNode never stops).
        // Subtract playerTimeBaseOffset to get frames within the current segment only.
        let framePosition = renderSampleTime - playerTimeBaseOffset + seekFrameOffset
        return max(0, TimeInterval(framePosition) / sampleRate)
    }

    // MARK: - Completion Handling

    /// Handle completion of the primary (current) segment.
    /// If gapless files are queued, advance to the next one.
    /// If no files remain, fire onPlaybackComplete.
    private func handleSegmentComplete(generation: UInt64) {
        guard generation == scheduleGeneration else {
            EnsembleLogger.debug("[AudioEngine] Ignoring stale segment completion (gen \(generation) vs current \(scheduleGeneration))")
            return
        }
        guard wasPlaying else {
            EnsembleLogger.debug("[AudioEngine] Segment complete ignored — wasPlaying=false")
            return
        }

        if let next = scheduledFiles.first {
            let previousTrackId = currentTrackId
            // Gapless advance: capture the current playerTime as the new base.
            // playerNode keeps running across gapless segments, so sampleTime
            // includes frames from all previous segments since the last stop().
            if let nodeTime = activePlayerNode.lastRenderTime,
               let pt = activePlayerNode.playerTime(forNodeTime: nodeTime) {
                playerTimeBaseOffset = pt.sampleTime
            }

            scheduledFiles.removeFirst()
            currentFile = next.file
            currentTrackId = next.trackId
            currentContentStartFrame = next.contentStartFrame
            currentContentFrameCount = next.contentFrameCount
            sampleRate = next.file.processingFormat.sampleRate
            fileDuration = Double(next.contentFrameCount) / sampleRate
            seekFrameOffset = 0

            // Re-anchor wall-clock estimation for the new track (position ≈ 0)
            captureWallTimeBase(position: 0)

            EnsembleLogger.debug("[AudioEngine] Gapless advance to trackId=\(next.trackId), baseOffset=\(playerTimeBaseOffset)")

            if let previousTrackId {
                PlaybackJourneyLogger.finish("currentTrackEndedAdvanced", trackId: previousTrackId, detail: "next=\(next.trackId)")
            }
            PlaybackJourneyLogger.mark("currentTrackAdvanced", trackId: next.trackId, detail: "gapless")
            onTrackAdvance?(next.trackId, playbackRequestGeneration)
            updateDurablePlaybackPosition(0)
        } else {
            // Queue exhausted
            wasPlaying = false
            stopTimeUpdates()
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            if let currentTrackId {
                PlaybackJourneyLogger.finish("currentTrackEndedAdvanced", trackId: currentTrackId, detail: "queueExhausted")
            }
            onPlaybackComplete?(playbackRequestGeneration)
        }
    }

    private func handleStreamingComplete(generation: UInt64) {
        guard generation == streamingCompletionGeneration else { return }
        guard wasPlaying, !streamingCompletionNotified else { return }
        streamingCompletionNotified = true
        wasPlaying = false
        stopTimeUpdates()
        EnsembleLogger.debug("[AudioEngine] Streaming source complete -- queue exhausted")
        if let currentTrackId {
            PlaybackJourneyLogger.finish("currentTrackEndedAdvanced", trackId: currentTrackId, detail: "streaming queueExhausted")
        }
        onPlaybackComplete?(playbackRequestGeneration)
    }

    /// Handle completion of a gapless-scheduled file.
    /// This fires after the scheduled file finishes playing (it was already advanced
    /// to by handleSegmentComplete). Used for chaining further gapless transitions.
    private func handleScheduledFileComplete(trackId: String, generation: UInt64) {
        // Stale check -- if generation doesn't match, this was from a cleared schedule
        guard generation == scheduleGeneration else {
            EnsembleLogger.debug("[AudioEngine] Ignoring stale gapless completion for trackId=\(trackId) (gen \(generation) vs current \(scheduleGeneration))")
            return
        }
        guard wasPlaying else {
            EnsembleLogger.debug("[AudioEngine] Gapless completion ignored — wasPlaying=false, trackId=\(trackId)")
            return
        }

        if let next = scheduledFiles.first {
            // Capture playerTime base for the next segment
            if let nodeTime = activePlayerNode.lastRenderTime,
               let pt = activePlayerNode.playerTime(forNodeTime: nodeTime) {
                playerTimeBaseOffset = pt.sampleTime
            }

            scheduledFiles.removeFirst()
            currentFile = next.file
            currentTrackId = next.trackId
            currentContentStartFrame = next.contentStartFrame
            currentContentFrameCount = next.contentFrameCount
            sampleRate = next.file.processingFormat.sampleRate
            fileDuration = Double(next.contentFrameCount) / sampleRate
            seekFrameOffset = 0

            // Re-anchor wall-clock estimation for the new track (position ≈ 0)
            captureWallTimeBase(position: 0)

            EnsembleLogger.debug("[AudioEngine] Gapless advance to trackId=\(next.trackId), baseOffset=\(playerTimeBaseOffset)")

            onTrackAdvance?(next.trackId, playbackRequestGeneration)
            updateDurablePlaybackPosition(0)
        } else {
            // No more files
            wasPlaying = false
            stopTimeUpdates()
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            onPlaybackComplete?(playbackRequestGeneration)
        }
    }

    // MARK: - Encoder Delay Detection

    /// Read audio content boundaries from the file's packet table.
    /// Compressed formats (MP3, AAC) encode silence at the start (encoder delay / priming)
    /// and end (padding / remainder) of the file. For gapless playback, these must be
    /// trimmed to avoid audible gaps at track boundaries.
    ///
    /// Uses AudioToolbox's `kAudioFilePropertyPacketTableInfo` which provides:
    /// - `mPrimingFrames`: encoder delay at the start (e.g. 576 for LAME MP3)
    /// - `mRemainderFrames`: padding at the end to fill the last codec frame
    /// - `mNumberValidFrames`: total real audio frames (content only)
    ///
    /// Falls back to LAME/Xing header parsing for MP3 files where the packet table
    /// is unavailable (common with FFmpeg streaming transcodes used by Plex).
    ///
    /// Returns (0, file.length) for formats without a packet table (PCM, FLAC, ALAC).
    private static func readContentBounds(
        for url: URL,
        fileLength: AVAudioFramePosition
    ) -> (contentStartFrame: AVAudioFramePosition, contentFrameCount: AVAudioFrameCount) {
        var audioFileID: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFileID)
        guard status == noErr, let fileID = audioFileID else {
            return (0, AVAudioFrameCount(fileLength))
        }
        defer { AudioFileClose(fileID) }

        var packetTable = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let ptStatus = AudioFileGetProperty(
            fileID, kAudioFilePropertyPacketTableInfo, &size, &packetTable
        )

        let ext = url.pathExtension.lowercased()
        let isMp3 = ext == "mp3" || ext == "audio"

        if ptStatus == noErr, packetTable.mNumberValidFrames > 0 {
            let priming = max(0, AVAudioFramePosition(packetTable.mPrimingFrames))
            let validFrames = AVAudioFrameCount(packetTable.mNumberValidFrames)

            // Sanity check: priming + valid frames shouldn't exceed file length
            guard priming + AVAudioFramePosition(validFrames) <= fileLength else {
                return (0, AVAudioFrameCount(fileLength))
            }

            // For MP3 files, if the packet table reports 0 priming frames, don't
            // trust it — FFmpeg transcodes (used by Plex's /start.mp3) write a
            // technically-valid packet table but set mPrimingFrames = 0 even though
            // the actual LAME encoder delay (576 frames, ~13ms) is present.
            // Fall through to the LAME header / default delay check below.
            if isMp3 && priming == 0 {
                EnsembleLogger.debug("[AudioEngine] readContentBounds: packet table reports 0 priming for MP3 — cross-checking with LAME header")
            } else {
                return (priming, validFrames)
            }
        }

        // Fallback for MP3 files: parse the Xing/Info + LAME header directly.
        // FFmpeg's streaming transcode (used by Plex's /start.mp3) often omits the
        // Xing header, or writes one without the fields Apple needs for PacketTableInfo.
        if isMp3 {
            if let gapless = parseLAMEGaplessInfo(url: url, fileLength: fileLength) {
                return gapless
            }

            // Last resort: apply standard LAME encoder delay (576 samples).
            // libmp3lame always adds a 576-sample priming delay. Without trimming,
            // each track boundary accumulates ~13ms of silence (at 44.1kHz).
            let defaultDelay: AVAudioFramePosition = 576
            if fileLength > defaultDelay * 2 {
                let trimmedFrames = AVAudioFrameCount(fileLength - defaultDelay)
                EnsembleLogger.debug("[AudioEngine] readContentBounds: no packet table or LAME header for MP3, applying default 576-sample encoder delay")
                return (defaultDelay, trimmedFrames)
            }
        }

        return (0, AVAudioFrameCount(fileLength))
    }

    /// Parse LAME/Xing header from an MP3 file to extract encoder delay and padding.
    ///
    /// MP3 gapless metadata lives in the first frame's Xing/Info VBR header:
    ///   [Xing|Info] [flags:4] [frames?:4] [bytes?:4] [TOC?:100] [quality?:4]
    ///   [encoder_version:9] [...LAME extension:12+] including delay/padding at +21
    ///
    /// Delay and padding are encoded as two 12-bit values in 3 bytes:
    ///   byte0 = delay[11:4], byte1 = delay[3:0]|padding[11:8], byte2 = padding[7:0]
    private static func parseLAMEGaplessInfo(
        url: URL,
        fileLength: AVAudioFramePosition
    ) -> (contentStartFrame: AVAudioFramePosition, contentFrameCount: AVAudioFrameCount)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read first 4KB — the Xing/Info header is always in the first MP3 frame
        guard let data = try? handle.read(upToCount: 4096), data.count > 200 else { return nil }

        // Find "Xing" or "Info" marker in the data
        let xingBytes: [UInt8] = [0x58, 0x69, 0x6E, 0x67] // "Xing"
        let infoBytes: [UInt8] = [0x49, 0x6E, 0x66, 0x6F] // "Info"

        var markerOffset: Int?
        for i in 0..<(data.count - 4) {
            if (data[i] == xingBytes[0] && data[i+1] == xingBytes[1] && data[i+2] == xingBytes[2] && data[i+3] == xingBytes[3])
                || (data[i] == infoBytes[0] && data[i+1] == infoBytes[1] && data[i+2] == infoBytes[2] && data[i+3] == infoBytes[3]) {
                markerOffset = i
                break
            }
        }

        guard let xingStart = markerOffset else { return nil }

        // Read flags at Xing+4
        let flagsOffset = xingStart + 4
        guard flagsOffset + 4 <= data.count else { return nil }
        let flags = (UInt32(data[flagsOffset]) << 24) | (UInt32(data[flagsOffset+1]) << 16)
            | (UInt32(data[flagsOffset+2]) << 8) | UInt32(data[flagsOffset+3])

        // Skip past optional fields to reach the encoder version string
        var offset = flagsOffset + 4
        if flags & 0x01 != 0 { offset += 4 }   // frame count
        if flags & 0x02 != 0 { offset += 4 }   // byte count
        if flags & 0x04 != 0 { offset += 100 }  // TOC entries
        if flags & 0x08 != 0 { offset += 4 }   // quality indicator

        // Encoder delay/padding is at offset +21 from the encoder version string start
        let delayPaddingOffset = offset + 21
        guard delayPaddingOffset + 3 <= data.count else { return nil }

        // Decode the 12-bit encoder delay and 12-bit padding
        let byte0 = UInt16(data[delayPaddingOffset])
        let byte1 = UInt16(data[delayPaddingOffset + 1])
        let byte2 = UInt16(data[delayPaddingOffset + 2])

        let encoderDelay = Int((byte0 << 4) | (byte1 >> 4))
        let encoderPadding = Int(((byte1 & 0x0F) << 8) | byte2)

        // Sanity check: typical LAME delay is 576, padding is 0-2000
        guard encoderDelay > 0, encoderDelay <= 3000,
              encoderPadding >= 0, encoderPadding <= 3000 else {
            return nil
        }

        let priming = AVAudioFramePosition(encoderDelay)
        let totalTrim = AVAudioFramePosition(encoderDelay + encoderPadding)
        guard totalTrim < fileLength else { return nil }

        let validFrames = AVAudioFrameCount(fileLength - totalTrim)

        // Log the encoder version for diagnostics
        let versionEnd = min(offset + 9, data.count)
        let versionString = String(bytes: data[offset..<versionEnd], encoding: .ascii) ?? "?"
        EnsembleLogger.debug("[AudioEngine] readContentBounds: LAME header found (encoder='\(versionString)', delay=\(encoderDelay), padding=\(encoderPadding))")

        return (priming, validFrames)
    }

    // MARK: - Cleanup

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopTimeUpdates()
        smartMixFadeTimer?.cancel()
        playerNode.stop()
        smartMixPlayerNode.stop()
        engine.stop()
    }
}

// MARK: - Errors

public enum AudioPlaybackEngineError: Error, LocalizedError {
    case soundIsolationUnavailable
    case noFileLoaded
    case streamingSeekUnavailable
    case streamingUnderrun

    public var errorDescription: String? {
        switch self {
        case .soundIsolationUnavailable:
            return "AUSoundIsolation audio unit is not available on this device"
        case .noFileLoaded:
            return "No audio file has been loaded"
        case .streamingSeekUnavailable:
            return "Seeking is not available until the current stream is seekable"
        case .streamingUnderrun:
            return "The audio stream stopped producing decoded frames"
        }
    }
}
