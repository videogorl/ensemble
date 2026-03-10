import Accelerate
import AVFoundation
import Combine
import Foundation

#if DEBUG
import os
private let logger = Logger(subsystem: "com.felicity.Ensemble", category: "AudioAnalyzer")
#endif

// MARK: - Audio Analyzer Protocol

/// Protocol for pre-computed frequency analysis decoupled from the audio pipeline.
/// Timelines are analyzed from audio files on disk, then played back in sync with
/// AVPlayer's current time via a 30Hz display timer.
@MainActor
public protocol AudioAnalyzerProtocol: AnyObject {
    /// Current frequency bands (24 bands from 60Hz to 16kHz)
    var frequencyBands: [Double] { get }

    /// Publisher for frequency band updates (~30 Hz)
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }

    /// Pre-compute frequency data for a track (call during prefetch or item creation).
    /// Loads from sidecar file if available, otherwise runs FFT analysis on background thread.
    /// Use `.userInitiated` priority for the current track, `.utility` for prefetch.
    @MainActor func loadTimeline(for trackId: String, fileURL: URL, priority: TaskPriority) async

    /// Activate a loaded timeline as the current display source.
    /// Starts the 30Hz display timer.
    @MainActor func activateTimeline(for trackId: String)

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
/// to produce time-indexed frequency snapshots, and drives a 30Hz display timer synced
/// to AVPlayer's current playback position. Completely decoupled from the audio pipeline.
@MainActor
public final class FrequencyAnalysisService: AudioAnalyzerProtocol {

    // MARK: - Configuration

    private let bandCount = 24
    private let fftSize = 1024
    private let minFrequency: Double = 60.0
    private let maxFrequency: Double = 16000.0
    private let targetFPS: Double = 30.0

    // MARK: - Published State

    @Published public private(set) var frequencyBands: [Double] = []

    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
        $frequencyBands.eraseToAnyPublisher()
    }

    // MARK: - Internal State

    /// Cached timelines keyed by trackId (max 3: current + 2 prefetched)
    private var timelines: [String: FrequencyTimeline] = [:]

    /// Which timeline is currently being displayed
    private var activeTrackId: String?

    /// 30Hz display timer
    private var displayTimer: Timer?

    /// Last known playback position (set by updatePlaybackPosition)
    private var currentPlaybackTime: TimeInterval = 0

    /// Wall-clock time when playback position was last updated (for interpolation)
    private var positionUpdateWallTime: TimeInterval = 0

    /// Whether updates are paused
    private var isPaused: Bool = false

    /// In-flight analysis tasks (to avoid duplicate work)
    private var analysisTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    public init() {
        frequencyBands = Array(repeating: 0.0, count: bandCount)

        #if DEBUG
        logger.debug("FrequencyAnalysisService initialized (pre-computed, no audio tap)")
        #endif
    }

    deinit {
        displayTimer?.invalidate()
        for task in analysisTasks.values { task.cancel() }
    }

    // MARK: - Timeline Loading

    public func loadTimeline(for trackId: String, fileURL: URL, priority: TaskPriority = .utility) async {
        #if DEBUG
        logger.debug("loadTimeline called for \(trackId), url=\(fileURL.lastPathComponent), isFile=\(fileURL.isFileURL)")
        #endif

        // Already cached or loading
        if timelines[trackId] != nil || analysisTasks[trackId] != nil {
            #if DEBUG
            logger.debug("loadTimeline skipped \(trackId): cached=\(self.timelines[trackId] != nil), loading=\(self.analysisTasks[trackId] != nil)")
            #endif
            return
        }

        // Only analyze local files (not remote stream URLs)
        guard fileURL.isFileURL else {
            #if DEBUG
            logger.debug("loadTimeline skipped \(trackId): not a file URL")
            #endif
            return
        }

        // Check for sidecar file first
        let sidecarURL = fileURL.appendingPathExtension("freq")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let timeline = try FrequencyTimelinePersistence.load(from: sidecarURL)
                timelines[trackId] = timeline
                #if DEBUG
                logger.debug("Loaded sidecar timeline for \(trackId): \(timeline.snapshots.count) frames")
                #endif
                return
            } catch {
                #if DEBUG
                logger.debug("Failed to load sidecar for \(trackId), will re-analyze: \(error)")
                #endif
            }
        }

        // Serialize analysis: only one analysis at a time to avoid CPU contention
        // on dual-core devices (A9). High-priority (current track) cancels existing
        // tasks. Low-priority (prefetch) is skipped if anything is already running.
        if priority == .userInitiated {
            for (existingId, existingTask) in analysisTasks {
                existingTask.cancel()
                #if DEBUG
                logger.debug("Cancelled analysis for \(existingId) to prioritize \(trackId)")
                #endif
            }
            analysisTasks.removeAll()
        } else if !analysisTasks.isEmpty {
            #if DEBUG
            logger.debug("Skipping prefetch analysis for \(trackId): another analysis is running")
            #endif
            return
        }

        // Analyze on background thread with progressive updates.
        // Every ~50 keyframes (~5s of audio at 10fps), a partial timeline
        // is published so the visualizer starts almost immediately (~0.7s)
        // while analysis continues in background.
        let capturedFileURL = fileURL
        let capturedPriority = priority
        let analysisTask = Task { [weak self] in
            let timeline = await Self.analyzeInBackground(
                fileURL: capturedFileURL,
                priority: capturedPriority
            ) { partialSnapshots, fps, analyzedDur, totalDur in
                // Progressive update: publish partial timeline to main actor
                Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.timelines[trackId] = FrequencyTimeline(
                        snapshots: partialSnapshots,
                        framesPerSecond: fps,
                        duration: totalDur,
                        analyzedDuration: analyzedDur
                    )
                }
            }
            guard !Task.isCancelled, let self else { return }

            if let timeline {
                self.timelines[trackId] = timeline

                // Save sidecar for downloaded files (not temp/cache files)
                // Downloaded files live in the app's Documents/Downloads directory
                if capturedFileURL.path.contains("Downloads") {
                    Task.detached(priority: .utility) {
                        try? FrequencyTimelinePersistence.save(timeline, to: sidecarURL)
                    }
                }

                #if DEBUG
                logger.debug("Analyzed timeline for \(trackId): \(timeline.snapshots.count) frames, \(String(format: "%.1f", timeline.duration))s")
                #endif
            } else {
                #if DEBUG
                logger.debug("Analysis returned nil for \(trackId) — file may be unsupported")
                #endif
            }

            self.analysisTasks.removeValue(forKey: trackId)
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
        activeTrackId = trackId
        isPaused = true  // Start paused — timer won't interpolate until resumeUpdates() on confirmed playback
        currentPlaybackTime = 0
        positionUpdateWallTime = CACurrentMediaTime()

        // Clear bands immediately so stale data from the previous track doesn't persist
        frequencyBands = Array(repeating: 0.0, count: bandCount)

        startDisplayTimer()

        #if DEBUG
        let hasTimeline = timelines[trackId] != nil
        logger.debug("Activated timeline for \(trackId), hasData=\(hasTimeline)")
        #endif
    }

    // MARK: - Eviction

    public func evictTimeline(for trackId: String) {
        timelines.removeValue(forKey: trackId)
        analysisTasks[trackId]?.cancel()
        analysisTasks.removeValue(forKey: trackId)

        // If we evicted the active timeline, clear the display
        if activeTrackId == trackId {
            activeTrackId = nil
            stopDisplayTimer()
            frequencyBands = Array(repeating: 0.0, count: bandCount)
        }
    }

    // MARK: - Playback Position

    public func updatePlaybackPosition(_ time: TimeInterval) {
        currentPlaybackTime = time
        positionUpdateWallTime = CACurrentMediaTime()
    }

    // MARK: - Lifecycle

    public func stopAnalysis() {
        displayTimer?.invalidate()
        displayTimer = nil
        activeTrackId = nil
        isPaused = false
        timelines.removeAll()
        for task in analysisTasks.values { task.cancel() }
        analysisTasks.removeAll()
        frequencyBands = Array(repeating: 0.0, count: bandCount)

        #if DEBUG
        logger.debug("Frequency analysis stopped")
        #endif
    }

    public func pauseUpdates() {
        isPaused = true

        #if DEBUG
        logger.debug("Frequency updates paused")
        #endif
    }

    public func resumeUpdates() {
        guard isPaused else { return }
        isPaused = false
        positionUpdateWallTime = CACurrentMediaTime()

        #if DEBUG
        logger.debug("Frequency updates resumed")
        #endif
    }

    // MARK: - Display Timer

    /// Start a 30Hz timer that reads the active timeline and publishes bands
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / targetFPS, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickDisplay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Called ~30 times per second by the display timer
    private func tickDisplay() {
        guard !isPaused,
              let trackId = activeTrackId,
              let timeline = timelines[trackId] else {
            return
        }

        // Interpolate playback position using wall-clock time since last update
        // This gives smooth 30fps updates between the 0.5s periodic observer ticks
        let wallElapsed = CACurrentMediaTime() - positionUpdateWallTime
        let interpolatedTime = currentPlaybackTime + wallElapsed

        frequencyBands = timeline.bands(at: interpolatedTime)
    }

    // MARK: - Static FFT Analysis (runs on background thread)

    /// Progress callback type: (snapshots so far, fps, analyzed duration, total duration)
    typealias ProgressHandler = @Sendable ([FrequencySnapshot], Double, TimeInterval, TimeInterval) -> Void

    /// Public entry point for sidecar generation after offline downloads.
    /// Runs FFT analysis on a background thread. Returns nil if the file can't be read.
    public nonisolated static func analyzeForSidecar(fileURL: URL) async -> FrequencyTimeline? {
        return await analyzeInBackground(fileURL: fileURL, priority: .utility, progressHandler: nil)
    }

    /// Analyze an audio file and produce a FrequencyTimeline.
    /// Runs entirely off the main thread. Returns nil if the file can't be read.
    /// Optional progressHandler receives partial results for progressive display.
    private nonisolated static func analyzeInBackground(
        fileURL: URL,
        priority: TaskPriority = .utility,
        progressHandler: ProgressHandler? = nil
    ) async -> FrequencyTimeline? {
        return await Task.detached(priority: priority) {
            return analyzeFile(at: fileURL, progressHandler: progressHandler)
        }.value
    }

    /// Core FFT analysis: opens file, seeks to analysis points, runs windowed FFT, maps to 24 bands.
    /// Progressive: publishes partial results every ~50 keyframes (~5s of audio) so the
    /// visualizer starts within ~0.7s. Full analysis for a 5-min song takes ~35s on A9.
    private nonisolated static func analyzeFile(
        at fileURL: URL,
        progressHandler: ProgressHandler? = nil
    ) -> FrequencyTimeline? {
        #if DEBUG
        let startTime = CACurrentMediaTime()
        NSLog("[FrequencyAnalysis] analyzeFile START: %@", fileURL.lastPathComponent)
        #endif

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
            #if DEBUG
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1
            NSLog("[FrequencyAnalysis] Failed to open: %@ (exists=%d, size=%lld)", fileURL.lastPathComponent, exists, size)
            #endif
            return nil
        }
        defer { if let tempSymlink { try? FileManager.default.removeItem(at: tempSymlink) } }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard sampleRate > 0, totalFrames > 0 else { return nil }

        let duration = Double(totalFrames) / sampleRate
        let processingFormat = audioFile.processingFormat
        let channelCount = Int(processingFormat.channelCount)
        #if DEBUG
        NSLog("[FrequencyAnalysis] Opened: %.1fs, %.0fHz, ch=%u", duration, sampleRate, channelCount)
        #endif

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
        var bandEdges = (0...bandCount).map { i in
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
                realParts = [Float](repeating: 0, count: fftSize / 2)
                imagParts = [Float](repeating: 0, count: fftSize / 2)
                var splitComplex = DSPSplitComplex(realp: &realParts, imagp: &imagParts)
                windowedSamples.withUnsafeBufferPointer { bufferPtr in
                    bufferPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                var divisor = Float(fftSize * 2)
                vDSP_vsdiv(magnitudes, 1, &divisor, &normalizedMags, 1, vDSP_Length(fftSize / 2))

                // Extract 24 logarithmic frequency bands
                var bandValues = [UInt8](repeating: 0, count: bandCount)
                for i in 0..<bandCount {
                    let lowerBin = Int(bandEdges[i] / binSize)
                    let upperBin = Int(bandEdges[i + 1] / binSize)
                    guard lowerBin < normalizedMags.count else { continue }

                    var sum: Float = 0
                    var count = 0
                    for bin in lowerBin..<min(upperBin, normalizedMags.count) {
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
            #if DEBUG
            NSLog("[FrequencyAnalysis] Read error: %@", "\(error)")
            #endif
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

        #if DEBUG
        let elapsed = CACurrentMediaTime() - startTime
        NSLog("[FrequencyAnalysis] Complete: %d keyframes for %.1fs (took %.2fs)",
              keyframes.count, duration, elapsed)
        #endif

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
                    #if DEBUG
                    NSLog("[FrequencyAnalysis] Opened file via extension probe: .%@ for %@", ext, fileURL.lastPathComponent)
                    #endif
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
