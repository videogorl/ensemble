import Accelerate
import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.felicity.Ensemble", category: "AudioAnalyzer")

public enum VisualizationConsumer: String, CaseIterable, Sendable {
    case phoneOverlay
    case nowPlayingSheet
    case nowPlayingViewport
    case stageFlow
    case externalDisplay
    case rootBackdrop
}

// MARK: - Audio Analyzer Protocol

/// Protocol for pre-computed frequency analysis decoupled from the audio pipeline.
/// Timelines are analyzed from audio files on disk, then played back in sync with
/// AVPlayer's current time via an adaptive display timer.
@MainActor
public protocol AudioAnalyzerProtocol: AnyObject {
    /// Current frequency bands (24 bands from 60Hz to 16kHz)
    var frequencyBands: [Double] { get }

    /// Publisher for frequency band updates.
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }

    /// Pre-compute frequency data for a track (call during prefetch or item creation).
    /// Loads from sidecar file if available, otherwise runs FFT analysis on background thread.
    /// Use `.userInitiated` priority for the current track, `.utility` for prefetch.
    /// When `throttled`, analysis pauses between keyframes to reduce CPU cache contention.
    @MainActor func loadTimeline(for trackId: String, fileURL: URL, priority: TaskPriority, throttled: Bool) async

    /// Activate a loaded timeline as the current display source.
    /// Starts the 30Hz display timer.
    @MainActor func activateTimeline(for trackId: String)

    /// Activate a timeline at a known playback position.
    @MainActor func activateTimeline(for trackId: String, at time: TimeInterval)

    /// Remove a track's cached timeline from memory.
    @MainActor func evictTimeline(for trackId: String)

    /// Update the playback position (drives band lookup from timeline).
    /// Called from the periodic time observer (~0.5s) and scrubber drag.
    @MainActor func updatePlaybackPosition(_ time: TimeInterval)

    /// Stop analysis and clear all state.
    @MainActor func stopAnalysis()

    /// Pause frequency band updates (shows silent bands).
    @MainActor func pauseUpdates()

    /// Resume frequency band updates.
    @MainActor func resumeUpdates()

    /// Pause the display timer when the app enters background.
    /// Unlike pauseUpdates(), this does not set the music-pause flag — it only stops the
    /// timer so it doesn't burn main-thread CPU during background audio playback.
    /// exitBackground() restarts the timer only if music is actively playing.
    @MainActor func enterBackground()

    /// Restart the display timer when the app foregrounds, if music was actively playing.
    @MainActor func exitBackground()

    /// Whether aurora visualization is enabled. When false, the 30Hz display timer
    /// is not started, saving CPU on low-end devices.
    @MainActor var visualizationEnabled: Bool { get set }

    /// Registers whether a visualization surface is currently onscreen.
    @MainActor func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool)
}

// MARK: - Frequency Snapshot

/// One frame of frequency data: 24 bands as UInt8 (0-255)
public struct FrequencySnapshot {
    public let bands: [UInt8] // 24 values
}

// MARK: - Frequency Timeline

/// Time-indexed frequency data for an entire track.
/// Stored as keyframes (10fps) with interpolation at lookup time.
/// A 5-min song at 10fps = ~3000 frames × 24 bytes = ~72KB.
///
/// `analyzedDuration` tracks how far analysis has reached for progressive loading.
/// For complete timelines (sidecar-loaded or fully analyzed), it equals `duration`.
public struct FrequencyTimeline {
    public let snapshots: [FrequencySnapshot]
    public let framesPerSecond: Double
    public let duration: TimeInterval
    /// How much of the track has been analyzed (for progressive loading)
    public let analyzedDuration: TimeInterval

    /// Look up bands at a playback position, normalized to 0.0-1.0.
    /// Clamps to the last analyzed frame if playback is ahead of analysis,
    /// so the visualizer holds the last known data instead of going blank.
    /// Linearly interpolates between adjacent keyframes for smooth 30Hz display.
    public func bands(at time: TimeInterval) -> [Double] {
        guard !snapshots.isEmpty, analyzedDuration > 0 else {
            return Array(repeating: 0, count: 24)
        }

        let clampedTime = min(time, analyzedDuration)
        let fractionalIndex = (clampedTime / analyzedDuration) * Double(snapshots.count)
        let lo = max(0, min(snapshots.count - 1, Int(fractionalIndex)))
        let hi = min(lo + 1, snapshots.count - 1)
        let frac = fractionalIndex - Double(lo)

        // Fast path: exact frame or last frame
        if lo == hi || frac < 0.001 {
            return snapshots[lo].bands.map { Double($0) / 255.0 }
        }

        // Interpolate between adjacent keyframes
        let a = snapshots[lo].bands
        let b = snapshots[hi].bands
        return (0..<a.count).map { i in
            let val = Double(a[i]) * (1.0 - frac) + Double(b[i]) * frac
            return val / 255.0
        }
    }
}

// MARK: - Frequency Timeline Persistence

/// Binary sidecar format for persisting pre-computed timelines alongside downloaded tracks.
/// Format: 16-byte header (magic, version, count, fps as UInt16, duration as Float32)
///         + count × 24 bytes of UInt8 band data.
public struct FrequencyTimelinePersistence {
    /// Magic bytes: "FREQ"
    private static let magic: UInt32 = 0x46524551
    private static let version: UInt16 = 1
    private static let bandCount: Int = 24

    /// Save a timeline to a binary sidecar file
    public static func save(_ timeline: FrequencyTimeline, to url: URL) throws {
        var data = Data()
        // Header: magic (4) + version (2) + count (4) + fps (2) + duration (4) = 16 bytes
        var m = magic; data.append(Data(bytes: &m, count: 4))
        var v = version; data.append(Data(bytes: &v, count: 2))
        var count = UInt32(timeline.snapshots.count); data.append(Data(bytes: &count, count: 4))
        var fps = UInt16(timeline.framesPerSecond); data.append(Data(bytes: &fps, count: 2))
        var dur = Float32(timeline.duration); data.append(Data(bytes: &dur, count: 4))

        // Band data: count × 24 UInt8
        for snapshot in timeline.snapshots {
            data.append(contentsOf: snapshot.bands)
        }

        try data.write(to: url, options: .atomic)
    }

    /// Load a timeline from a binary sidecar file
    public static func load(from url: URL) throws -> FrequencyTimeline {
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { throw FrequencyAnalysisError.invalidSidecar }

        // Parse header (use loadUnaligned — Data's buffer isn't guaranteed aligned)
        let m = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard m == magic else { throw FrequencyAnalysisError.invalidSidecar }

        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        guard v == version else { throw FrequencyAnalysisError.invalidSidecar }

        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt32.self) })
        let fps = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt16.self) })
        let dur = TimeInterval(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Float32.self) })

        let expectedSize = 16 + count * bandCount
        guard data.count >= expectedSize else { throw FrequencyAnalysisError.invalidSidecar }

        // Parse band data
        var snapshots: [FrequencySnapshot] = []
        snapshots.reserveCapacity(count)
        for i in 0..<count {
            let offset = 16 + i * bandCount
            let bands = Array(data[offset..<(offset + bandCount)])
            snapshots.append(FrequencySnapshot(bands: bands))
        }

        return FrequencyTimeline(snapshots: snapshots, framesPerSecond: fps, duration: dur, analyzedDuration: dur)
    }
}

// MARK: - Frequency Analysis Error

public enum FrequencyAnalysisError: Error {
    case cannotOpenFile
    case invalidSidecar
}

// MARK: - Frequency Analysis Service

/// Pre-computed frequency analyzer. Reads audio files on a background thread, runs FFT
/// to produce time-indexed frequency snapshots, and drives an adaptive display timer synced
/// to AVPlayer's current playback position. Completely decoupled from the audio pipeline.
@MainActor
public final class FrequencyAnalysisService: AudioAnalyzerProtocol {

    // MARK: - Configuration

    private let bandCount = 24
    private let fftSize = 1024
    private let highTargetFPS: Double = 30.0

    // MARK: - Display State

    private let frequencyBandsSubject = CurrentValueSubject<[Double], Never>(
        Array(repeating: 0.0, count: 24)
    )

    public var frequencyBands: [Double] {
        frequencyBandsSubject.value
    }

    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
        frequencyBandsSubject.eraseToAnyPublisher()
    }

    // MARK: - Internal State

    /// Cached timelines keyed by trackId (max 3: current + 2 prefetched)
    private var timelines: [String: FrequencyTimeline] = [:]

    /// Which timeline is currently being displayed
    private var activeTrackId: String?

    /// 30Hz display timer
    private var displayTimer: Timer?
    private var activeDisplayFPS: Double?

    /// Last known playback position (set by updatePlaybackPosition)
    private var currentPlaybackTime: TimeInterval = 0

    /// Wall-clock time when playback position was last updated (for interpolation)
    private var positionUpdateWallTime: TimeInterval = 0

    /// Whether updates are paused
    private var isPaused: Bool = false

    /// Whether the aurora visualizer is enabled in settings.
    /// When false, the 30Hz display timer is not started — saving significant CPU
    /// on dual-core devices (A9). Synced from PlaybackService's UserDefaults observer.
    public var visualizationEnabled: Bool = true {
        didSet {
            guard visualizationEnabled != oldValue else { return }
            updateDisplayTimerState(trigger: "visualizationEnabled")
        }
    }

    /// True while the app is in the background. Stops the 30Hz display timer without
    /// disturbing the music-pause (isPaused) flag, so exitBackground() can correctly
    /// restart the timer only when music was actively playing.
    private var isBackgrounded = false

    /// In-flight analysis tasks (to avoid duplicate work)
    private var analysisTasks: [String: Task<Void, Never>] = [:]
    private var visibleVisualizationConsumers = Set<VisualizationConsumer>()

    // MARK: - Init

    public init() {
        logger.debug("FrequencyAnalysisService initialized (pre-computed, no audio tap)")
    }

    deinit {
        displayTimer?.invalidate()
        for task in analysisTasks.values { task.cancel() }
    }

    // MARK: - Timeline Loading

    public func loadTimeline(for trackId: String, fileURL: URL, priority: TaskPriority = .utility, throttled: Bool = false) async {
        logger.debug("loadTimeline called isFile=\(fileURL.isFileURL)")

        // Already cached or loading
        if timelines[trackId] != nil || analysisTasks[trackId] != nil {
            logger.debug("loadTimeline skipped cached=\(self.timelines[trackId] != nil), loading=\(self.analysisTasks[trackId] != nil)")
            return
        }

        // Only analyze local files (not remote stream URLs)
        guard fileURL.isFileURL else {
            logger.debug("loadTimeline skipped: not a file URL")
            return
        }

        // Check for sidecar file first
        let sidecarURL = fileURL.appendingPathExtension("freq")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let timeline = try FrequencyTimelinePersistence.load(from: sidecarURL)
                timelines[trackId] = timeline
                logger.debug("Loaded sidecar timeline frames=\(timeline.snapshots.count)")
                return
            } catch {
                logger.debug("Failed to load sidecar for \(trackId), will re-analyze: \(error)")
            }
        }

        // Serialize analysis: only one analysis at a time to avoid CPU contention
        // on dual-core devices (A9). High-priority (current track) cancels existing
        // tasks. Low-priority (prefetch) is skipped if anything is already running.
        if priority == .userInitiated {
            for (existingId, existingTask) in analysisTasks {
                existingTask.cancel()
                logger.debug("Cancelled analysis for \(existingId) to prioritize \(trackId)")
            }
            analysisTasks.removeAll()
        } else if !analysisTasks.isEmpty {
            logger.debug("Skipping prefetch analysis for \(trackId): another analysis is running")
            return
        }

        // Analyze on background thread with progressive updates.
        // Every ~50 keyframes (~5s of audio at 10fps), a partial timeline
        // is published so the visualizer starts almost immediately (~0.7s)
        // while analysis continues in background.
        let capturedFileURL = fileURL
        let capturedPriority = priority
        let capturedThrottled = throttled
        let service = self
        let analysisTask = Task { [service] in
            let timeline = await Self.analyzeInBackground(
                fileURL: capturedFileURL,
                priority: capturedPriority,
                throttled: capturedThrottled
            ) { partialSnapshots, fps, analyzedDur, totalDur in
                // Progressive update: publish partial timeline to main actor
                Task { @MainActor [service] in
                    guard !Task.isCancelled else { return }
                    service.timelines[trackId] = FrequencyTimeline(
                        snapshots: partialSnapshots,
                        framesPerSecond: fps,
                        duration: totalDur,
                        analyzedDuration: analyzedDur
                    )
                }
            }
            guard !Task.isCancelled else { return }

            if let timeline {
                service.timelines[trackId] = timeline

                // Save sidecar for downloaded files (not temp/cache files)
                // Downloaded files live in the app's Documents/Downloads directory
                if capturedFileURL.path.contains("Downloads") {
                    Task.detached(priority: .utility) {
                        try? FrequencyTimelinePersistence.save(timeline, to: sidecarURL)
                    }
                }

                logger.debug("Analyzed timeline for \(trackId): \(timeline.snapshots.count) frames, \(String(format: "%.1f", timeline.duration))s")
            } else {
                logger.debug("Analysis returned nil for \(trackId) — file may be unsupported")
            }

            service.analysisTasks.removeValue(forKey: trackId)
        }
        analysisTasks[trackId] = analysisTask
        // Only await if this task hasn't been replaced by a higher-priority one.
        // If another loadTimeline() cancels our task, we return immediately.
        await withTaskCancellationHandler {
            await analysisTask.value
        } onCancel: {
            analysisTask.cancel()
        }
    }

    // MARK: - Timeline Activation

    public func activateTimeline(for trackId: String) {
        activateTimeline(for: trackId, at: 0)
    }

    public func activateTimeline(for trackId: String, at time: TimeInterval) {
        activeTrackId = trackId
        isPaused = true  // Start paused — timer won't interpolate until resumeUpdates() on confirmed playback
        currentPlaybackTime = max(0, time)
        positionUpdateWallTime = CACurrentMediaTime()

        // Clear bands immediately so stale data from the previous track doesn't persist
        publishFrequencyBands(Array(repeating: 0.0, count: bandCount), force: true)

        updateDisplayTimerState(trigger: "activateTimeline")

        let hasTimeline = timelines[trackId] != nil
        let vizEnabled = visualizationEnabled
        logger.debug("Activated timeline for \(trackId), hasData=\(hasTimeline), vizEnabled=\(vizEnabled)")
    }

    // MARK: - Eviction

    public func evictTimeline(for trackId: String) {
        timelines.removeValue(forKey: trackId)
        analysisTasks[trackId]?.cancel()
        analysisTasks.removeValue(forKey: trackId)

        // If we evicted the active timeline, clear the display
        if activeTrackId == trackId {
            activeTrackId = nil
            updateDisplayTimerState(trigger: "evictTimeline")
            publishFrequencyBands(Array(repeating: 0.0, count: bandCount), force: true)
        }
    }

    // MARK: - Playback Position

    public func updatePlaybackPosition(_ time: TimeInterval) {
        currentPlaybackTime = time
        positionUpdateWallTime = CACurrentMediaTime()
    }

    // MARK: - Lifecycle

    public func stopAnalysis() {
        stopDisplayTimer(reason: "stopAnalysis")
        activeTrackId = nil
        isPaused = false
        timelines.removeAll()
        for task in analysisTasks.values { task.cancel() }
        analysisTasks.removeAll()
        publishFrequencyBands(Array(repeating: 0.0, count: bandCount), force: true)

        logger.debug("Frequency analysis stopped")
    }

    public func pauseUpdates() {
        isPaused = true
        updateDisplayTimerState(trigger: "pauseUpdates")

        logger.debug("Frequency updates paused (timer stopped)")
    }

    public func resumeUpdates() {
        guard isPaused else { return }
        isPaused = false
        positionUpdateWallTime = CACurrentMediaTime()
        updateDisplayTimerState(trigger: "resumeUpdates")

        logger.debug("Frequency updates resumed (timer restarted)")
    }

    // MARK: - App Lifecycle

    /// Stop the display timer when the app backgrounds. Does not touch isPaused so
    /// the music-pause state is preserved for when the app returns to foreground.
    public func enterBackground() {
        isBackgrounded = true
        updateDisplayTimerState(trigger: "enterBackground")
    }

    /// Restart the display timer when the app foregrounds — but only if music was
    /// actively playing (not paused by the user or a track transition).
    public func exitBackground() {
        isBackgrounded = false
        updateDisplayTimerState(trigger: "exitBackground")
    }

    public func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool) {
        let changed: Bool
        if isVisible {
            changed = visibleVisualizationConsumers.insert(consumer).inserted
        } else {
            changed = visibleVisualizationConsumers.remove(consumer) != nil
        }

        guard changed else { return }

        logger.debug("Visualization consumer \(consumer.rawValue) visible=\(isVisible) total=\(self.visibleVisualizationConsumers.count)")

        updateDisplayTimerState(trigger: "consumer:\(consumer.rawValue)")
    }

    // MARK: - Display Timer

    private var desiredDisplayFPS: Double? {
        guard !visibleVisualizationConsumers.isEmpty else { return nil }

        // Keep Aurora visually responsive at 30Hz. Main-thread pressure is managed
        // by coalescing no-op band publishes and moving surface shaping off the
        // SwiftUI receive path, not by reducing the visualizer cadence.
        return highTargetFPS
    }

    private func updateDisplayTimerState(trigger: String) {
        guard visualizationEnabled else {
            stopDisplayTimer(reason: "\(trigger):visualizationDisabled")
            return
        }

        guard !isBackgrounded else {
            stopDisplayTimer(reason: "\(trigger):backgrounded")
            return
        }

        guard activeTrackId != nil else {
            stopDisplayTimer(reason: "\(trigger):noActiveTrack")
            return
        }

        guard !isPaused else {
            stopDisplayTimer(reason: "\(trigger):paused")
            return
        }

        guard let fps = desiredDisplayFPS else {
            stopDisplayTimer(reason: "\(trigger):noVisibleConsumers")
            return
        }

        startDisplayTimer(fps: fps, reason: trigger)
    }

    /// Start a timer that reads the active timeline and publishes bands.
    /// Timer runs on RunLoop.main so tickDisplay() executes on the main thread directly
    /// without the overhead of a Task { @MainActor } hop on every frame.
    private func startDisplayTimer(fps: Double, reason: String) {
        if displayTimer != nil, activeDisplayFPS == fps {
            return
        }

        stopDisplayTimer(reason: "\(reason):restart")

        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickDisplay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        activeDisplayFPS = fps

        logger.debug("Display timer started fps=\(fps, format: .fixed(precision: 0)) reason=\(reason)")
    }

    private func stopDisplayTimer(reason: String) {
        guard displayTimer != nil else { return }
        displayTimer?.invalidate()
        displayTimer = nil
        activeDisplayFPS = nil

        logger.debug("Display timer stopped reason=\(reason)")
    }

    /// Called by the display timer to publish the latest interpolated bands.
    private func tickDisplay() {
        guard !isPaused, !isBackgrounded,
              let trackId = activeTrackId,
              let timeline = timelines[trackId] else {
            return
        }

        // Interpolate playback position using wall-clock time since last update
        // This gives smooth 30fps updates between the 0.5s periodic observer ticks
        let wallElapsed = CACurrentMediaTime() - positionUpdateWallTime
        let interpolatedTime = currentPlaybackTime + wallElapsed

        publishFrequencyBands(timeline.bands(at: interpolatedTime), force: false)
    }

    private func publishFrequencyBands(_ bands: [Double], force: Bool) {
        let currentBands = frequencyBandsSubject.value
        guard force || Self.shouldPublishBands(bands, comparedTo: currentBands) else { return }
        frequencyBandsSubject.send(bands)
    }

    private nonisolated static func shouldPublishBands(_ newBands: [Double], comparedTo currentBands: [Double]) -> Bool {
        guard newBands.count == currentBands.count else { return true }
        let minimumVisibleDelta = 0.003

        for (newValue, currentValue) in zip(newBands, currentBands) {
            if abs(newValue - currentValue) >= minimumVisibleDelta {
                return true
            }
        }

        return false
    }

    internal var visibleVisualizationConsumersForTesting: Set<VisualizationConsumer> {
        visibleVisualizationConsumers
    }

    internal var isDisplayTimerRunningForTesting: Bool {
        displayTimer != nil
    }

    internal var activeDisplayFPSForTesting: Double? {
        activeDisplayFPS
    }

    // MARK: - Static FFT Analysis (runs on background thread)

    /// Progress callback type: (snapshots so far, fps, analyzed duration, total duration)
    typealias ProgressHandler = @Sendable ([FrequencySnapshot], Double, TimeInterval, TimeInterval) -> Void

    /// Public entry point for sidecar generation after offline downloads.
    /// Calls analyzeFile directly (no inner Task.detached) so Task.isCancelled checks
    /// inside the FFT loop propagate from the SidecarAnalysisQueue's worker task.
    /// This enables clean suspension when the app backgrounds mid-analysis.
    public nonisolated static func analyzeForSidecar(fileURL: URL) async -> FrequencyTimeline? {
        return analyzeFile(at: fileURL)
    }

    /// Analyze an audio file and produce a FrequencyTimeline.
    /// Runs entirely off the main thread. Returns nil if the file can't be read.
    /// Optional progressHandler receives partial results for progressive display.
    private nonisolated static func analyzeInBackground(
        fileURL: URL,
        priority: TaskPriority = .utility,
        throttled: Bool = false,
        progressHandler: ProgressHandler? = nil
    ) async -> FrequencyTimeline? {
        return await Task.detached(priority: priority) {
            return analyzeFile(at: fileURL, throttled: throttled, progressHandler: progressHandler)
        }.value
    }

    /// Core FFT analysis: opens file, seeks to analysis points, runs windowed FFT, maps to 24 bands.
    /// Progressive: publishes partial results every ~50 keyframes (~5s of audio) so the
    /// visualizer starts within ~0.7s. Full analysis for a 5-min song takes ~35s on A9.
    /// When `throttled`, inserts pauses between keyframes to reduce CPU cache contention
    /// with real-time audio processing (e.g. AUSoundIsolation neural network).
    private nonisolated static func analyzeFile(
        at fileURL: URL,
        throttled: Bool = false,
        progressHandler: ProgressHandler? = nil
    ) -> FrequencyTimeline? {
        let startTime = CACurrentMediaTime()
        logger.debug("Frequency analysis started isFile=\(fileURL.isFileURL)")

        // Open audio file — try directly first, then fall back to symlink probing
        // for files with unrecognized extensions (e.g. ".audio" from stream cache).
        var tempSymlink: URL? = nil
        let audioFile: AVAudioFile
        if let file = try? AVAudioFile(forReading: fileURL) {
            audioFile = file
        } else if let (file, symlink) = openWithExtensionProbing(fileURL) {
            audioFile = file
            tempSymlink = symlink
        } else {
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1
            logger.error(
                "Frequency analysis failed to open file=\(fileURL.lastPathComponent, privacy: .public) exists=\(exists, privacy: .public) size=\(size, privacy: .public)"
            )
            return nil
        }
        defer { if let tempSymlink { try? FileManager.default.removeItem(at: tempSymlink) } }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard sampleRate > 0, totalFrames > 0 else { return nil }

        let duration = Double(totalFrames) / sampleRate
        let processingFormat = audioFile.processingFormat
        let channelCount = Int(processingFormat.channelCount)
        logger.debug(
            "Frequency analysis opened duration=\(duration, format: .fixed(precision: 1)) sampleRate=\(sampleRate, format: .fixed(precision: 0)) channels=\(channelCount, privacy: .public)"
        )

        // Seek-based analysis at 10fps with progressive loading.
        // Each seek + decode of 1024 samples takes ~14ms on A9 (dual core).
        // For a 5-min song: ~3000 keyframes × 14ms = ~42s total.
        // But results are published every 50 keyframes (~0.7s), so the
        // visualizer starts almost immediately while analysis continues.
        // Analysis runs at ~7x real-time, staying ahead of playback.
        let analysisFPS: Double = 10.0
        let fftSize = 1024
        let bandCount = 24
        let hopFrames = Int(sampleRate / analysisFPS)

        // Setup FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Log-spaced frequency band edges (60Hz - 16kHz, 24 bands)
        let logMin = log10(60.0), logMax = log10(16000.0)
        let bandEdges = (0...bandCount).map { i in
            pow(10, logMin + (Double(i) / Double(bandCount)) * (logMax - logMin))
        }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Read buffer for exactly one FFT window of audio
        guard let readBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(fftSize)
        ) else { return nil }

        // Reusable FFT buffers
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        var realParts = [Float](repeating: 0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var normalizedMags = [Float](repeating: 0, count: fftSize / 2)
        let binSize = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2
        let bandBinRanges: [Range<Int>] = (0..<bandCount).map { index in
            let lower = min(maxBin, max(0, Int(bandEdges[index] / binSize)))
            let rawUpper = Int(bandEdges[index + 1] / binSize)
            let upper = min(maxBin, max(lower, rawUpper))
            return lower..<upper
        }

        // Analyze at 10fps keyframes by seeking to each point
        let keyframeCount = Int(ceil(duration * analysisFPS))
        var keyframes = [FrequencySnapshot]()
        keyframes.reserveCapacity(keyframeCount)

        // Publish partial results every progressInterval keyframes (~5s of audio).
        // At 10fps, 50 keyframes = 5s of audio, analyzed in ~0.7s on A9.
        let progressInterval = 50

        do {
            for k in 0..<keyframeCount {
                // Check for cancellation frequently (every 2 keyframes ~0.2s of audio)
                // to quickly abandon analysis when the user skips tracks rapidly
                if k % 2 == 0 && Task.isCancelled { return nil }

                // When throttled (e.g. AUSoundIsolation active), pause every 3 keyframes
                // to reduce sustained CPU cache pressure on the real-time audio IO thread.
                // 5ms pause per ~5ms of FFT work ≈ 50% CPU reduction, keeps the neural
                // network's L2 cache warm across render cycles.
                if throttled && k % 3 == 0 && k > 0 {
                    usleep(5000)
                }

                let seekFrame = AVAudioFramePosition(k * hopFrames)
                guard seekFrame + AVAudioFramePosition(fftSize) <= audioFile.length else {
                    // Near end of file — duplicate last frame if we have one
                    if let last = keyframes.last {
                        keyframes.append(last)
                    }
                    continue
                }

                // Seek and read only fftSize samples
                audioFile.framePosition = seekFrame
                readBuffer.frameLength = 0
                try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(fftSize))
                guard readBuffer.frameLength > 0,
                      let channelData = readBuffer.floatChannelData else { continue }

                let readCount = min(Int(readBuffer.frameLength), fftSize)

                // Mix to mono + apply Hann window in one pass
                for i in 0..<fftSize { windowedSamples[i] = 0 }
                if channelCount == 1 {
                    let ptr = channelData[0]
                    for i in 0..<readCount {
                        windowedSamples[i] = ptr[i] * hannWindow[i]
                    }
                } else {
                    let invCh = 1.0 / Float(channelCount)
                    for i in 0..<readCount {
                        var sum: Float = 0
                        for ch in 0..<channelCount { sum += channelData[ch][i] }
                        windowedSamples[i] = sum * invCh * hannWindow[i]
                    }
                }

                // FFT
                realParts.withUnsafeMutableBufferPointer { realPtr in
                    imagParts.withUnsafeMutableBufferPointer { imagPtr in
                        guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                        var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        windowedSamples.withUnsafeBufferPointer { bufferPtr in
                            guard let sampleBase = bufferPtr.baseAddress else { return }
                            sampleBase.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                    }
                }
                var divisor = Float(fftSize * 2)
                vDSP_vsdiv(magnitudes, 1, &divisor, &normalizedMags, 1, vDSP_Length(fftSize / 2))

                // Extract 24 logarithmic frequency bands
                var bandValues = [UInt8](repeating: 0, count: bandCount)
                for i in 0..<bandCount {
                    let bins = bandBinRanges[i]
                    guard !bins.isEmpty else { continue }

                    var sum: Float = 0
                    var count = 0
                    for bin in bins {
                        sum += normalizedMags[bin]
                        count += 1
                    }
                    guard count > 0 else { continue }

                    let average = sum / Float(count)
                    let db = 20.0 * log10(Double(max(average, 1e-10)))
                    let normalized = min(1.0, max(0.0, (db + 60.0) / 60.0))
                    let curved = pow(normalized, 0.7)
                    bandValues[i] = UInt8(min(255, max(0, curved * 255.0)))
                }

                keyframes.append(FrequencySnapshot(bands: bandValues))

                // Publish partial results for progressive display
                if let progressHandler, keyframes.count % progressInterval == 0 {
                    let analyzedSoFar = Double(keyframes.count) / analysisFPS
                    progressHandler(Array(keyframes), analysisFPS, analyzedSoFar, duration)
                }
            }
        } catch {
            logger.error("Frequency analysis read failed: \(error.localizedDescription, privacy: .public)")
            // Return whatever we have so far (partial analysis is better than nothing)
            if !keyframes.isEmpty {
                let analyzedSoFar = Double(keyframes.count) / analysisFPS
                return FrequencyTimeline(
                    snapshots: keyframes,
                    framesPerSecond: analysisFPS,
                    duration: duration,
                    analyzedDuration: analyzedSoFar
                )
            }
            return nil
        }

        guard !keyframes.isEmpty else { return nil }

        let elapsed = CACurrentMediaTime() - startTime
        logger.debug(
            "Frequency analysis complete keyframes=\(keyframes.count, privacy: .public) duration=\(duration, format: .fixed(precision: 1)) elapsed=\(elapsed, format: .fixed(precision: 2))"
        )

        // Store keyframes at analysis FPS. The display timer
        // interpolates between them at 30Hz via bands(at:).
        return FrequencyTimeline(
            snapshots: keyframes,
            framesPerSecond: analysisFPS,
            duration: duration,
            analyzedDuration: duration  // fully analyzed
        )
    }

    /// Try opening a file using temporary symlinks with common audio extensions.
    /// AVAudioFile uses the file extension to determine the container format, so files
    /// with unrecognized extensions (e.g. ".audio" from the stream cache) need this workaround.
    /// Returns the opened AVAudioFile and the symlink URL (caller must clean up the symlink).
    private nonisolated static func openWithExtensionProbing(_ fileURL: URL) -> (AVAudioFile, URL)? {
        let extensions = ["mp3", "flac", "m4a", "caf", "aac", "wav"]
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory

        for ext in extensions {
            let symlink = tempDir.appendingPathComponent("\(baseName)_probe.\(ext)")
            try? FileManager.default.removeItem(at: symlink)

            do {
                try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fileURL)
                if let file = try? AVAudioFile(forReading: symlink) {
                    logger.debug(
                        "Frequency analysis opened via extension probe ext=\(ext, privacy: .public) file=\(fileURL.lastPathComponent, privacy: .public)"
                    )
                    return (file, symlink)
                }
                try? FileManager.default.removeItem(at: symlink)
            } catch {
                continue
            }
        }

        return nil
    }
}
