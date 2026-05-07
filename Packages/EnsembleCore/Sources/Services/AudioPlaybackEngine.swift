import AudioToolbox
import AVFoundation
import Combine
import QuartzCore

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
/// playerNode -> mainMixer -> output
/// ```
///
/// Audio graph (isolation enabled):
/// ```
/// playerNode -> AUSoundIsolation(v0 model) -> mainMixer -> output
/// ```
public final class AudioPlaybackEngine {

    // MARK: - Core Engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

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

    // MARK: - Playback State

    /// The currently loaded audio file
    private var currentFile: AVAudioFile?
    /// Track ID of the currently playing file (for caller identification)
    private(set) var currentTrackId: String?
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

    // MARK: - Time Tracking

    /// Current playback time, updated at ~10Hz via DispatchSourceTimer.
    /// Sent from a dedicated background queue using wall-clock estimation to
    /// avoid any playerNode property access that could cause priority inversion
    /// with the audio render thread.
    let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
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
    var onPlaybackComplete: (() -> Void)?
    /// Fires when a gapless transition advances to the next scheduled track
    var onTrackAdvance: ((_ newTrackId: String) -> Void)?
    /// Fires on unrecoverable engine errors (route change failure, etc.)
    /// Parameters: (error, trackId or nil). When trackId is non-nil, the error
    /// originated from a gapless-scheduled track (not the currently playing one).
    var onError: ((Error, String?) -> Void)?


    // MARK: - Setup

    /// Initialize the audio engine graph.
    /// Call once before loading files. Isolation effect is created lazily on first toggle.
    func setup() throws {
        guard !isSetUp else { return }

        engine.attach(playerNode)

        // Connect playerNode directly to mixer (no effects yet)
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        engine.connect(playerNode, to: mainMixer, format: outputFormat)

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

        EnsembleLogger.debug("[AudioEngine] Graph built (playerNode -> mixer -> output)")
    }

    // MARK: - Graph Building

    /// Reconnect the audio graph, optionally inserting the isolation effect.
    /// Called during setup, isolation toggle, file load, and route change recovery.
    private func buildGraph(format: AVAudioFormat?) {
        let mainMixer = engine.mainMixerNode
        let connectFormat = format ?? mainMixer.outputFormat(forBus: 0)

        // Disconnect existing connections from playerNode
        engine.disconnectNodeOutput(playerNode)
        if let effect = isolationEffect {
            engine.disconnectNodeOutput(effect)
        }

        if let effect = isolationEffect {
            // playerNode -> isolation -> mixer
            // Effect stays in chain permanently; wetDryMix=0 acts as passthrough
            engine.connect(playerNode, to: effect, format: connectFormat)
            engine.connect(effect, to: mainMixer, format: connectFormat)
        } else {
            // No isolation effect created (or unavailable) — direct path
            engine.connect(playerNode, to: mainMixer, format: connectFormat)
        }
    }

    // MARK: - Route Change Recovery

    /// Capture the last stable playhead before AVAudioEngineConfigurationChange
    /// invalidates render timing during a route transition.
    func prepareForRouteChange() {
        guard currentFile != nil else { return }

        let renderClockPosition = currentRenderClockPosition()
        let observedPosition = currentTimeSubject.value
        let fallbackPosition = Self.resolvedPlaybackPosition(
            renderSampleTime: nil,
            playerTimeBaseOffset: playerTimeBaseOffset,
            seekFrameOffset: seekFrameOffset,
            sampleRate: sampleRate
        )
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
        let livePosition = currentTime()
        let position = Self.resolvedRouteRecoveryPosition(
            livePosition: livePosition,
            observedPosition: pendingRouteRecoveryPosition ?? currentTimeSubject.value,
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

            // Re-schedule any queued gapless files with correct content bounds
            rescheduleGaplessFiles()

            if wasActive {
                playerNode.play()
                wasPlaying = true
                startTimeUpdates(from: position)
            } else {
                // Stop the engine when not actively playing. iOS detects a running
                // engine's render cycle and overrides MPNowPlayingInfoCenter.playbackState
                // to .playing, causing the lock screen / Dynamic Island to show "playing"
                // even though audio is paused. Stopping here preserves the paused state
                // that the route-change handler already pushed to NowPlayingInfoCenter.
                engine.stop()
            }

            currentTimeSubject.send(position)

            EnsembleLogger.debug("[AudioEngine] Route change recovery complete (wasActive=\(wasActive))")
        } catch {
            EnsembleLogger.error("[AudioEngine] Route change recovery failed: \(error.localizedDescription)")
            onError?(error, nil)
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

        // Allow the AU to render up to 4096 frames per callback (matches the larger
        // IO buffer we request when isolation is active). Without this, the engine may
        // split large buffers into multiple smaller render passes, adding overhead that
        // makes deadline misses more likely under system load.
        effect.auAudioUnit.maximumFramesToRender = 4096

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
        // Default is 1156; 4096 reduces render call frequency and helps prevent overload dropouts.
        var maxFrames: UInt32 = 4096
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
        let wasActive = wasPlaying || playerNode.isPlaying

        // Stop player and engine to rebuild connections safely.
        // The engine must be fully stopped (not just the playerNode) so that
        // when it restarts, it picks up any pending IO buffer preference change
        // (e.g. the larger buffer requested for AUSoundIsolation headroom).
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        playerNode.stop()
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
            playerNode.play()
            wasPlaying = true
            startTimeUpdates(from: position)
        }

        currentTimeSubject.send(position)
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
        if let avUnit = isolationEffect, let tree = avUnit.auAudioUnit.parameterTree {
            for param in tree.allParameters {
                EnsembleLogger.debug("[AudioEngine]   Tree param: address=\(param.address), name='\(param.displayName)', min=\(param.minValue), max=\(param.maxValue), value=\(param.value)")
            }
        } else {
            EnsembleLogger.debug("[AudioEngine]   No AUParameterTree available")
        }
        EnsembleLogger.debug("[AudioEngine] === End parameter dump ===")
    }

    // MARK: - File Loading

    /// Load an audio file for playback. Reconnects the graph with the file's native format.
    /// Schedules the full file so it's ready for `resume()` without a separate `play(from:)` call.
    /// (`play(from:)` and `seek(to:)` call `playerNode.stop()` first, which clears this schedule.)
    func load(fileURL: URL, trackId: String) throws {
        let file = try AVAudioFile(forReading: fileURL)
        currentFile = file
        currentTrackId = trackId
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
        playerNode.scheduleSegment(
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

    // MARK: - Gapless Scheduling

    /// Re-schedule all queued gapless files on the playerNode after a stop/flush.
    /// Uses each entry's stored content bounds to preserve encoder delay trimming.
    /// Called from handleConfigurationChange(), wireIsolationIntoGraph(), and seek().
    private func rescheduleGaplessFiles() {
        for entry in scheduledFiles {
            let entryGen = scheduleGeneration
            playerNode.scheduleSegment(
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
        playerNode.scheduleSegment(
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
        let wasActive = wasPlaying || playerNode.isPlaying

        // Bump generation AFTER capturing position — this invalidates all pending
        // completion handlers (both primary segment and gapless entries)
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        // Flush the playerNode's entire FIFO (removes orphaned audio segments)
        playerNode.stop()
        playerTimeBaseOffset = 0

        // Re-schedule only the current track from the current position.
        // Convert user-visible time to file frame space by adding the content offset.
        let userFrame = AVAudioFramePosition(position * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            // Current track already at/past end — let natural completion handle it
            EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (track at end)")
            onPlaybackComplete?()
            return
        }

        seekFrameOffset = userFrame
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        playerNode.scheduleSegment(
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
            playerNode.play()
            wasPlaying = true
            startTimeUpdates(from: position)
        }

        EnsembleLogger.debug("[AudioEngine] Cleared scheduled files (flushed FIFO, re-anchored at \(String(format: "%.1f", position))s)")
    }

    // MARK: - Playback Control

    /// Schedule and start playback from the given time offset (in user-visible seconds).
    func play(from time: TimeInterval = 0) throws {
        guard let file = currentFile else {
            throw AudioPlaybackEngineError.noFileLoaded
        }
        pendingRouteRecoveryPosition = nil

        // Convert user-visible time to file frame space
        let userFrame = AVAudioFramePosition(time * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            onPlaybackComplete?()
            return
        }

        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        seekFrameOffset = userFrame
        playerTimeBaseOffset = 0
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        playerNode.stop()
        file.framePosition = fileFrame
        playerNode.scheduleSegment(
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

        playerNode.play()
        wasPlaying = true
        startTimeUpdates(from: time)

        EnsembleLogger.debug("[AudioEngine] Playing from \(String(format: "%.1f", time))s (frame \(fileFrame)/\(currentContentFrameCount))")
    }

    /// Pause playback and stop the engine.
    ///
    /// Stopping the engine is essential: while `playerNode.pause()` silences audio,
    /// the engine's render cycle continues pulling frames from CoreAudio. iOS detects
    /// this active render cycle and overrides `MPNowPlayingInfoCenter.playbackState`,
    /// causing the lock screen to show "playing" even though audio is paused.
    ///
    /// `engine.stop()` does NOT detach nodes or reset the player node's paused position.
    /// On resume, `engine.start()` + `playerNode.play()` picks up where we left off.
    func pause() {
        let position = snapshotPlaybackPositionBeforeStopping()
        playerNode.pause()
        wasPlaying = false
        stopTimeUpdates()
        if engine.isRunning {
            engine.stop()
        }
        EnsembleLogger.debug("[AudioEngine] Paused (engine stopped) at \(String(format: "%.1f", position))s")
    }

    /// Resume playback after pause.
    ///
    /// The engine may have been stopped during `pause()`, so we restart it here.
    /// Restarting the engine can reset AU state, so we re-apply isolation parameters.
    func resume() throws {
        if !engine.isRunning {
            try engine.start()
            // Engine restart can reset AU state — re-apply isolation parameters
            applyIsolationParameters()
        }
        let observedPosition = currentTimeSubject.value
        let resumePosition = Self.resolvedRouteRecoveryPosition(
            livePosition: currentTime(),
            observedPosition: observedPosition,
            duration: fileDuration,
            preferredSnapshot: observedPosition > 0 ? observedPosition : nil
        )
        playerNode.play()
        wasPlaying = true
        startTimeUpdates(from: resumePosition)
        currentTimeSubject.send(resumePosition)
        EnsembleLogger.debug("[AudioEngine] Resumed")
    }

    /// Stop playback, reset position, and stop the engine.
    func stop() {
        scheduleGeneration &+= 1
        stopTimeUpdates()
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        wasPlaying = false
        seekFrameOffset = 0
        playerTimeBaseOffset = 0
        currentContentStartFrame = 0
        currentContentFrameCount = 0
        pendingRouteRecoveryPosition = nil
        scheduledFiles.removeAll()
        currentTimeSubject.send(0)
        EnsembleLogger.debug("[AudioEngine] Stopped")
    }

    /// Seek to a new position within the current file (in user-visible seconds).
    func seek(to time: TimeInterval) throws {
        guard let file = currentFile else { return }
        pendingRouteRecoveryPosition = nil

        let wasPlayingBeforeSeek = wasPlaying || playerNode.isPlaying

        // Bump generation to suppress the completion callback from playerNode.stop()
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        playerNode.stop()
        playerTimeBaseOffset = 0

        // Convert user-visible time to file frame space
        let userFrame = AVAudioFramePosition(time * sampleRate)
        let fileFrame = userFrame + currentContentStartFrame
        let contentEnd = currentContentStartFrame + AVAudioFramePosition(currentContentFrameCount)
        guard fileFrame < contentEnd else {
            onPlaybackComplete?()
            return
        }

        seekFrameOffset = userFrame
        let frameCount = AVAudioFrameCount(contentEnd - fileFrame)

        file.framePosition = fileFrame
        playerNode.scheduleSegment(
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
            playerNode.play()
            wasPlaying = true
            startTimeUpdates(from: time)
        }

        // Update time immediately for responsive UI
        currentTimeSubject.send(time)
        EnsembleLogger.debug("[AudioEngine] Seeked to \(String(format: "%.1f", time))s")
    }

    // MARK: - Time Tracking

    /// Compute current playback time from player node render position.
    func currentTime() -> TimeInterval {
        guard let renderClockPosition = currentRenderClockPosition() else {
            return Self.resolvedPlaybackPosition(
                renderSampleTime: nil,
                playerTimeBaseOffset: playerTimeBaseOffset,
                seekFrameOffset: seekFrameOffset,
                sampleRate: sampleRate
            )
        }
        return renderClockPosition
    }

    /// Returns the current playhead from AVAudioPlayerNode's live render clock.
    /// This becomes unavailable during route transitions before our fallback state
    /// has been updated, so callers must handle `nil` explicitly.
    private func currentRenderClockPosition() -> TimeInterval? {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
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
            self.currentTimeSubject.send(max(0, estimated))
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
        timeBase = TimeBase(
            wallTime: CACurrentMediaTime(),
            position: position ?? currentTime(),
            duration: fileDuration
        )
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
            observedPosition: currentTimeSubject.value,
            duration: fileDuration
        )
        seekFrameOffset = AVAudioFramePosition(position * sampleRate)
        playerTimeBaseOffset = 0
        captureWallTimeBase(position: position)
        currentTimeSubject.send(position)
        pendingRouteRecoveryPosition = nil
        return position
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
            // Gapless advance: capture the current playerTime as the new base.
            // playerNode keeps running across gapless segments, so sampleTime
            // includes frames from all previous segments since the last stop().
            if let nodeTime = playerNode.lastRenderTime,
               let pt = playerNode.playerTime(forNodeTime: nodeTime) {
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

            onTrackAdvance?(next.trackId)
            currentTimeSubject.send(0)
        } else {
            // Queue exhausted
            wasPlaying = false
            stopTimeUpdates()
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            onPlaybackComplete?()
        }
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
            if let nodeTime = playerNode.lastRenderTime,
               let pt = playerNode.playerTime(forNodeTime: nodeTime) {
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

            onTrackAdvance?(next.trackId)
            currentTimeSubject.send(0)
        } else {
            // No more files
            wasPlaying = false
            stopTimeUpdates()
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            onPlaybackComplete?()
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
        playerNode.stop()
        engine.stop()
    }
}

// MARK: - Errors

public enum AudioPlaybackEngineError: Error, LocalizedError {
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
