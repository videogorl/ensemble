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
    /// Whether the music-quality v0 tuning model was accepted by the AU
    private var musicModelLoaded = false

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

    // MARK: - Undocumented AU Constants

    // Tuning mode parameters for AUSoundIsolation (discovered via QuietNow project)
    private let kUseTuningMode: AudioUnitParameterID = 0x17626   // 95782
    private let kTuningMode: AudioUnitParameterID = 0x17627      // 95783

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

        if isIsolationActive, let effect = isolationEffect {
            // playerNode -> isolation -> mixer
            engine.connect(playerNode, to: effect, format: connectFormat)
            engine.connect(effect, to: mainMixer, format: connectFormat)
        } else {
            // playerNode -> mixer (bypass isolation)
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

        // Re-apply isolation parameters if active (reconnection can reset AU state)
        if isIsolationActive {
            applyIsolationParameters()
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
        engine.attach(effect)
        isolationNodeCreated = true

        // Activate music tuning mode for better vocal separation
        loadMusicModel(for: effect)

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Isolation effect created (musicModel=\(musicModelLoaded))")
        #endif
    }

    /// Toggle vocal isolation on or off. Lazily creates the AU on first enable.
    /// Rebuilds the graph inline -- no engine restart needed, minimal audio gap.
    func setIsolationEnabled(_ enabled: Bool) throws {
        guard enabled != isIsolationActive else { return }

        if enabled && !isolationNodeCreated {
            try createIsolationEffect()
        }

        // Capture state before rebuilding
        let position = currentTime()
        let wasActive = wasPlaying || playerNode.isPlaying

        // Stop player to rebuild connections safely
        scheduleGeneration &+= 1
        let myGeneration = scheduleGeneration
        playerNode.stop()
        playerTimeBaseOffset = 0

        // Toggle and rebuild graph
        isIsolationActive = enabled
        buildGraph(format: currentFile?.processingFormat)

        // Apply isolation parameters when enabling
        if enabled {
            applyIsolationParameters()
        }

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

        if wasActive {
            if !engine.isRunning {
                try engine.start()
            }
            // Re-apply after engine start (can reset AU state)
            if enabled { applyIsolationParameters() }
            playerNode.play()
            wasPlaying = true
            startTimeUpdates()
        }

        currentTimeSubject.send(position)

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Isolation \(enabled ? "enabled" : "disabled") at \(String(format: "%.1f", position))s")
        #endif
    }

    // MARK: - Music Model Loading (from InstrumentalAudioEngine)

    /// Activate music-quality vocal separation via tuning mode parameters.
    private func loadMusicModel(for effect: AVAudioUnitEffect) {
        let au = effect.audioUnit

        AudioUnitSetParameter(au, kUseTuningMode, kAudioUnitScope_Global, 0, 1.0, 0)
        AudioUnitSetParameter(au, kTuningMode, kAudioUnitScope_Global, 0, 1.0, 0)

        var useTuning: AudioUnitParameterValue = 0
        var tuning: AudioUnitParameterValue = 0
        AudioUnitGetParameter(au, kUseTuningMode, kAudioUnitScope_Global, 0, &useTuning)
        AudioUnitGetParameter(au, kTuningMode, kAudioUnitScope_Global, 0, &tuning)
        musicModelLoaded = useTuning == 1.0 && tuning == 1.0

        #if DEBUG
        EnsembleLogger.debug("[AudioEngine] Tuning mode: useTuning=\(useTuning), tuning=\(tuning), accepted=\(musicModelLoaded)")
        #endif
    }

    /// Apply AUSoundIsolation parameters based on whether the music model is loaded.
    private func applyIsolationParameters(to effect: AVAudioUnitEffect? = nil) {
        let target = effect ?? isolationEffect
        guard let target else { return }
        let paramTree = target.auAudioUnit.parameterTree

        if musicModelLoaded {
            // With music model: wetDryMix is vocal attenuation (0=original, 100=instrumentals)
            paramTree?.parameter(withAddress: 1)?.value = 0.0    // HighQualityVoice (iOS 18+)
            paramTree?.parameter(withAddress: 0)?.value = 100.0  // Full vocal removal
        } else {
            // Fallback: phase-invert mix (output = dry + (-vocals) = instrumentals)
            paramTree?.parameter(withAddress: 1)?.value = 0.0
            paramTree?.parameter(withAddress: 0)?.value = -100.0
        }

        #if DEBUG
        let wetDry = paramTree?.parameter(withAddress: 0)?.value ?? -999
        let isolate = paramTree?.parameter(withAddress: 1)?.value ?? -999
        EnsembleLogger.debug("[AudioEngine] Isolation params: wetDry=\(wetDry), soundToIsolate=\(isolate), musicModel=\(musicModelLoaded)")
        #endif
    }

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
        if isIsolationActive {
            applyIsolationParameters()
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
        if isIsolationActive {
            applyIsolationParameters()
        }

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
