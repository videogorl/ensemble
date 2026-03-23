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
    /// Undocumented property to disable the dereverb neural network (from QuietNow)
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
    /// (for karaoke / Apple Music Sing), which is the opposite of what we want.
    ///
    /// Explicitly sets the stream format on the AU before attaching to prevent a channel
    /// assertion crash on iOS 26+ (the AU's neural network requires stereo I/O).
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

        // Explicitly set stream format on the AU BEFORE engine.attach() triggers initialization.
        // This prevents the iOS 26 channel assertion crash in CreateProcessingGraph.
        // The AU's neural network requires matching input/output channel counts (stereo).
        // (Ref: QuietNow sets format on input+output scopes before AudioUnitInitialize)
        configureAUFormat(for: effect)

        engine.attach(effect)
        isolationNodeCreated = true

        #if DEBUG
        // Dump all parameters the AU exposes (helps understand what the default model supports)
        dumpAUParameters(au: effect.audioUnit, label: "after attach")
        #endif
    }

    /// Set the stream format and disable dereverb on the AU before initialization.
    /// Must be called BEFORE engine.attach() which triggers AU initialization.
    private func configureAUFormat(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit

        // Use the current file's format, or fall back to a standard stereo format.
        // The AU's neural network requires stereo (2-channel) I/O.
        let format: AVAudioFormat
        if let fileFormat = currentFile?.processingFormat {
            format = fileFormat
        } else {
            // Standard stereo PCM format as fallback
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        }

        // Set stream format on both input and output scopes (matching QuietNow approach)
        var asbd = format.streamDescription.pointee
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, formatSize)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, formatSize)

        // Disable dereverb neural network (property 50000, from QuietNow)
        var emptyStr = "" as CFString
        AudioUnitSetProperty(au, kDeverbPresetPathOverride, kAudioUnitScope_Global, 0,
                             &emptyStr, UInt32(MemoryLayout<CFString>.size))

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] AU format configured: \(format)")
        #endif
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
    /// Strategy: tell the AU to isolate VOCALS (address 1 = 1.0), then INVERT the output
    /// (address 0 = -100.0) to subtract vocals from the mix, leaving only instrumentals.
    /// This is the phase-cancellation approach: Original - Vocals = Instrumentals.
    ///
    /// Uses the C API because AUSoundIsolation hides parameters from the AUParameterTree.
    private func applyIsolationParameters(to effect: AVAudioUnitEffect? = nil) {
        let target = effect ?? isolationEffect
        guard let target else { return }
        let au = target.audioUnit

        // Sound to Isolate: 1.0 = vocals (we isolate vocals so we can subtract them)
        AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 1.0, 0)

        // Wet/Dry Mix: -100 = inverted isolation (subtracts isolated signal from original = instrumentals)
        //              0 = passthrough (normal audio, no effect)
        let wetDryValue: AudioUnitParameterValue = isIsolationActive ? -100.0 : 0.0
        AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, wetDryValue, 0)

        #if DEBUG
        var wetDry: AudioUnitParameterValue = -999
        var isolate: AudioUnitParameterValue = -999
        AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &wetDry)
        AudioUnitGetParameter(au, 1, kAudioUnitScope_Global, 0, &isolate)
        EnsembleLogger.debug("[AudioEngine] Isolation params: wetDry=\(wetDry), soundToIsolate=\(isolate), active=\(isIsolationActive)")
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
    func load(fileURL: URL, trackId: String) throws {
        let file = try AVAudioFile(forReading: fileURL)
        currentFile = file
        currentTrackId = trackId
        sampleRate = file.processingFormat.sampleRate
        fileDuration = Double(file.length) / sampleRate
        seekFrameOffset = 0

        // Clear any previously scheduled gapless files
        scheduledFiles.removeAll()

        // Reconnect graph with the file's native format for optimal quality
        buildGraph(format: file.processingFormat)

        // Re-apply isolation parameters (reconnection can reset AU state)
        applyIsolationParameters()

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
