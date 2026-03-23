import AudioToolbox
import AVFoundation
import Combine

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
    /// Duration of the current file in seconds
    private(set) var fileDuration: TimeInterval = 0
    /// Frame offset from which the current segment was scheduled
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

    // MARK: - Generation Counter

    /// Incremented on each schedule/seek/stop to suppress stale completion callbacks.
    /// playerNode.stop() fires all pending completion handlers immediately --
    /// without this guard, every seek would trigger a spurious track advance.
    private var scheduleGeneration: UInt64 = 0

    // MARK: - Gapless FIFO Queue

    /// Files scheduled for gapless playback via scheduleSegment FIFO.
    /// Each entry tracks the file, track ID, and generation at schedule time.
    private var scheduledFiles: [(file: AVAudioFile, trackId: String, generation: UInt64)] = []

    // MARK: - Time Tracking

    /// Current playback time, updated at ~10Hz via DispatchSourceTimer
    let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private var timeUpdateTimer: DispatchSourceTimer?

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
    var onError: ((Error) -> Void)?


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

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Graph built (playerNode -> mixer -> output)")
        #endif
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

    /// Handle AVAudioEngine configuration changes (route switches like AirPlay, headphones).
    /// The engine stops itself on route change -- we must rebuild and reschedule.
    private func handleConfigurationChange() {
        let position = currentTime()
        let wasActive = wasPlaying

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Configuration change detected at \(String(format: "%.1f", position))s, wasPlaying=\(wasActive)")
        #endif

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

            // Re-schedule any queued gapless files
            for entry in scheduledFiles {
                let entryGen = scheduleGeneration
                playerNode.scheduleSegment(
                    entry.file,
                    startingFrame: 0,
                    frameCount: AVAudioFrameCount(entry.file.length),
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        self?.handleScheduledFileComplete(trackId: entry.trackId, generation: entryGen)
                    }
                }
            }

            if wasActive {
                playerNode.play()
                wasPlaying = true
                startTimeUpdates()
            }

            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] Route change recovery complete")
            #endif
        } catch {
            EnsembleLogger.error("[AudioEngine] Route change recovery failed: \(error.localizedDescription)")
            onError?(error)
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

        // Load the v0 neural network model for high-quality source separation.
        // Without the model, the AU does almost nothing.
        loadMusicModel(for: effect)

        engine.attach(effect)
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

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] AU format configured: \(format)")
        #endif
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
            #if DEBUG
            let checkedPaths = modelSearchPaths.map { $0.plist }
            EnsembleLogger.debug("[AudioEngine] No v0 model found — AU will use default (poor quality). Checked: \(checkedPaths)")
            #endif
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

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] v0 model loaded from: \(plistPath), base: \(basePath)")
        #endif
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

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Isolation \(enabled ? "enabled" : "disabled")")
        #endif
    }

    /// Wire the isolation effect into the audio graph for the first time.
    /// Requires stopping the player and rescheduling — only called once.
    private func wireIsolationIntoGraph() throws {
        let position = currentTime()
        let wasActive = wasPlaying || playerNode.isPlaying

        // Stop player to rebuild connections safely
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        playerNode.stop()
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
        for entry in scheduledFiles {
            let entryGen = scheduleGeneration
            playerNode.scheduleSegment(
                entry.file,
                startingFrame: 0,
                frameCount: AVAudioFrameCount(entry.file.length),
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleScheduledFileComplete(trackId: entry.trackId, generation: entryGen)
                }
            }
        }

        if wasActive {
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            wasPlaying = true
            startTimeUpdates()
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
        // With the v0 model loaded, 0.0 isolates the instrumental track.
        AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 0.0, 0)

        // Wet/Dry Mix: 100 = fully isolated, 0 = original (passthrough).
        // Use 95 instead of 100 to blend a small amount of original back in,
        // which smooths out separation artifacts in the vocal removal.
        let wetDryValue: AudioUnitParameterValue = isIsolationActive ? 95.0 : 0.0
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, wetDryValue, 0)

        #if DEBUG
        var wetDry: AudioUnitParameterValue = -999
        var isolate: AudioUnitParameterValue = -999
        AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &wetDry)
        AudioUnitGetParameter(au, 1, kAudioUnitScope_Global, 0, &isolate)
        EnsembleLogger.debug("[AudioEngine] Isolation params: wetDry=\(wetDry), soundToIsolate=\(isolate), active=\(isIsolationActive), bypass=\(bypass), modelLoaded=\(musicModelLoaded)")
        #endif
    }

    #if DEBUG
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
    #endif

    // MARK: - File Loading

    /// Load an audio file for playback. Reconnects the graph with the file's native format.
    /// Schedules the full file so it's ready for `resume()` without a separate `play(from:)` call.
    /// (`play(from:)` and `seek(to:)` call `playerNode.stop()` first, which clears this schedule.)
    func load(fileURL: URL, trackId: String) throws {
        let file = try AVAudioFile(forReading: fileURL)
        currentFile = file
        currentTrackId = trackId
        sampleRate = file.processingFormat.sampleRate
        fileDuration = Double(file.length) / sampleRate
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

        // Schedule the full file so resume() works without a prior play(from:).
        // This is critical for restore-to-paused: load() is called but play(from:)
        // is not, so without this the playerNode has nothing queued and resume()
        // would produce silence (or play prefetched gapless tracks instead).
        playerNode.scheduleSegment(
            file,
            startingFrame: 0,
            frameCount: AVAudioFrameCount(file.length),
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleSegmentComplete(generation: myGeneration)
            }
        }

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Loaded: \(fileURL.lastPathComponent), rate=\(sampleRate), frames=\(file.length), duration=\(String(format: "%.1f", fileDuration))s, trackId=\(trackId)")
        #endif
    }

    // MARK: - Gapless Scheduling

    /// Whether a track is already in the gapless schedule queue.
    func isTrackScheduled(_ trackId: String) -> Bool {
        scheduledFiles.contains { $0.trackId == trackId }
    }

    /// Schedule the next file for gapless playback. Uses AVAudioPlayerNode's FIFO queue --
    /// the segment plays immediately after the current segment finishes, with zero gap.
    /// Call this during prefetch to ensure seamless transitions.
    func scheduleNext(fileURL: URL, trackId: String) throws {
        let file = try AVAudioFile(forReading: fileURL)
        let frameCount = AVAudioFrameCount(file.length)

        // Don't bump scheduleGeneration here — that would invalidate the current
        // segment's completion handler. The generation counter only needs to change
        // when playerNode.stop() is called (which fires all pending callbacks as stale).
        // scheduleNext just appends to the FIFO queue; no stop, no stale callbacks.
        let myGeneration = scheduleGeneration

        // Schedule the entire file to play after current segment (at: nil = FIFO)
        playerNode.scheduleSegment(
            file,
            startingFrame: 0,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleScheduledFileComplete(trackId: trackId, generation: myGeneration)
            }
        }

        scheduledFiles.append((file: file, trackId: trackId, generation: myGeneration))

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Scheduled next: \(fileURL.lastPathComponent), trackId=\(trackId), queueDepth=\(scheduledFiles.count)")
        #endif
    }

    /// Remove all pending gapless files from the schedule.
    /// Called when the queue changes (skip, shuffle, etc.) to prevent stale transitions.
    func clearScheduledFiles() {
        // Bump generation so pending completion handlers are ignored
        scheduleGeneration &+= 1
        scheduledFiles.removeAll()

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Cleared scheduled files")
        #endif
    }

    // MARK: - Playback Control

    /// Schedule and start playback from the given time offset.
    func play(from time: TimeInterval = 0) throws {
        guard let file = currentFile else {
            throw AudioPlaybackEngineError.noFileLoaded
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
        playerTimeBaseOffset = 0
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

        // Re-apply isolation params after engine start (can reset AU state)
        applyIsolationParameters()

        playerNode.play()
        wasPlaying = true
        startTimeUpdates()

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Playing from \(String(format: "%.1f", time))s (frame \(startFrame)/\(totalFrames))")
        #endif
    }

    /// Pause playback (engine stays running to avoid restart latency).
    func pause() {
        playerNode.pause()
        wasPlaying = false
        stopTimeUpdates()
        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Paused")
        #endif
    }

    /// Resume playback after pause.
    func resume() throws {
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
        wasPlaying = true
        startTimeUpdates()
        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Resumed")
        #endif
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
        scheduledFiles.removeAll()
        currentTimeSubject.send(0)
        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Stopped")
        #endif
    }

    /// Seek to a new position within the current file.
    func seek(to time: TimeInterval) throws {
        guard let file = currentFile else { return }

        let wasPlayingBeforeSeek = wasPlaying || playerNode.isPlaying

        // Bump generation to suppress the completion callback from playerNode.stop()
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration

        playerNode.stop()
        playerTimeBaseOffset = 0

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

        // Re-schedule any gapless files that were cleared by playerNode.stop()
        for entry in scheduledFiles {
            let entryGen = scheduleGeneration
            playerNode.scheduleSegment(
                entry.file,
                startingFrame: 0,
                frameCount: AVAudioFrameCount(entry.file.length),
                at: nil
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleScheduledFileComplete(trackId: entry.trackId, generation: entryGen)
                }
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
        EnsembleLogger.debug("[AudioEngine] Seeked to \(String(format: "%.1f", time))s")
        #endif
    }

    // MARK: - Time Tracking

    /// Compute current playback time from player node render position.
    func currentTime() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return TimeInterval(seekFrameOffset) / sampleRate
        }
        // playerTime.sampleTime accumulates across gapless segments (playerNode never stops).
        // Subtract playerTimeBaseOffset to get frames within the current segment only.
        let framePosition = playerTime.sampleTime - playerTimeBaseOffset + seekFrameOffset
        return max(0, TimeInterval(framePosition) / sampleRate)
    }

    /// Start periodic time updates at ~10Hz.
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

    /// Stop periodic time updates.
    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    // MARK: - Completion Handling

    /// Handle completion of the primary (current) segment.
    /// If gapless files are queued, advance to the next one.
    /// If no files remain, fire onPlaybackComplete.
    private func handleSegmentComplete(generation: UInt64) {
        guard generation == scheduleGeneration else {
            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] Ignoring stale completion (gen \(generation) vs current \(scheduleGeneration))")
            #endif
            return
        }
        guard wasPlaying else { return }

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
            sampleRate = next.file.processingFormat.sampleRate
            fileDuration = Double(next.file.length) / sampleRate
            seekFrameOffset = 0

            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] Gapless advance to trackId=\(next.trackId), baseOffset=\(playerTimeBaseOffset)")
            #endif

            onTrackAdvance?(next.trackId)
        } else {
            // Queue exhausted
            wasPlaying = false
            stopTimeUpdates()
            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            #endif
            onPlaybackComplete?()
        }
    }

    /// Handle completion of a gapless-scheduled file.
    /// This fires after the scheduled file finishes playing (it was already advanced
    /// to by handleSegmentComplete). Used for chaining further gapless transitions.
    private func handleScheduledFileComplete(trackId: String, generation: UInt64) {
        // Stale check -- if generation doesn't match, this was from a cleared schedule
        guard generation == scheduleGeneration else { return }
        guard wasPlaying else { return }

        if let next = scheduledFiles.first {
            // Capture playerTime base for the next segment
            if let nodeTime = playerNode.lastRenderTime,
               let pt = playerNode.playerTime(forNodeTime: nodeTime) {
                playerTimeBaseOffset = pt.sampleTime
            }

            scheduledFiles.removeFirst()
            currentFile = next.file
            currentTrackId = next.trackId
            sampleRate = next.file.processingFormat.sampleRate
            fileDuration = Double(next.file.length) / sampleRate
            seekFrameOffset = 0

            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] Gapless advance to trackId=\(next.trackId), baseOffset=\(playerTimeBaseOffset)")
            #endif

            onTrackAdvance?(next.trackId)
        } else {
            // No more files
            wasPlaying = false
            stopTimeUpdates()
            #if DEBUG
            EnsembleLogger.debug("[AudioEngine] All segments complete -- queue exhausted")
            #endif
            onPlaybackComplete?()
        }
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
