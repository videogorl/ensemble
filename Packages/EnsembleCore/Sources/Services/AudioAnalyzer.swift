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
    @MainActor func loadTimeline(for trackId: String, fileURL: URL) async

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
/// A 5-min song at 30fps = ~9000 frames × 24 bytes = ~216KB.
public struct FrequencyTimeline {
    public let snapshots: [FrequencySnapshot]
    public let framesPerSecond: Double // 30.0
    public let duration: TimeInterval

    /// Look up bands at a playback position, normalized to 0.0-1.0
    public func bands(at time: TimeInterval) -> [Double] {
        guard !snapshots.isEmpty, duration > 0 else {
            return Array(repeating: 0, count: 24)
        }
        let index = Int((time / duration) * Double(snapshots.count))
        let clamped = max(0, min(snapshots.count - 1, index))
        return snapshots[clamped].bands.map { Double($0) / 255.0 }
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

        // Parse header
        let m = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard m == magic else { throw FrequencyAnalysisError.invalidSidecar }

        let v = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }
        guard v == version else { throw FrequencyAnalysisError.invalidSidecar }

        let count = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt32.self) })
        let fps = Double(data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) })
        let dur = TimeInterval(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float32.self) })

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

        return FrequencyTimeline(snapshots: snapshots, framesPerSecond: fps, duration: dur)
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

    public func loadTimeline(for trackId: String, fileURL: URL) async {
        // Already cached or loading
        if timelines[trackId] != nil || analysisTasks[trackId] != nil {
            return
        }

        // Only analyze local files (not remote stream URLs)
        guard fileURL.isFileURL else { return }

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

        // Analyze on background thread
        let capturedFileURL = fileURL
        let analysisTask = Task { [weak self] in
            let timeline = await Self.analyzeInBackground(fileURL: capturedFileURL)
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
        await analysisTask.value
    }

    // MARK: - Timeline Activation

    public func activateTimeline(for trackId: String) {
        activeTrackId = trackId
        isPaused = true  // Start paused — timer won't interpolate until resumeUpdates() on confirmed playback
        currentPlaybackTime = 0
        positionUpdateWallTime = CACurrentMediaTime()
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

    /// Public entry point for sidecar generation after offline downloads.
    /// Runs FFT analysis on a background thread. Returns nil if the file can't be read.
    public nonisolated static func analyzeForSidecar(fileURL: URL) async -> FrequencyTimeline? {
        return await analyzeInBackground(fileURL: fileURL)
    }

    /// Analyze an audio file and produce a FrequencyTimeline.
    /// Runs entirely off the main thread. Returns nil if the file can't be read.
    private nonisolated static func analyzeInBackground(fileURL: URL) async -> FrequencyTimeline? {
        return await Task.detached(priority: .utility) {
            return analyzeFile(at: fileURL)
        }.value
    }

    /// Core FFT analysis: opens file, reads PCM chunks, runs windowed FFT, maps to 24 bands.
    /// Reuses the same parameters as the old real-time tap (1024 FFT, 24 log bands, pow(0.7) smoothing).
    private nonisolated static func analyzeFile(at fileURL: URL) -> FrequencyTimeline? {
        // Open audio file — try directly first, then fall back to symlink probing
        // for files with unrecognized extensions (e.g. ".audio" from stream cache).
        // AVAudioFile relies on the file extension to determine the container format.
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
            #if DEBUG
            NSLog("[FrequencyAnalysis] Failed to open file: %@ (exists=%d, size=%lld)", fileURL.lastPathComponent, exists, size)
            #endif
            return nil
        }
        // Clean up temp symlink after all reading is done
        defer { if let tempSymlink { try? FileManager.default.removeItem(at: tempSymlink) } }

        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard sampleRate > 0, totalFrames > 0 else { return nil }

        let duration = Double(totalFrames) / sampleRate
        let fps: Double = 30.0
        let fftSize = 1024
        let bandCount = 24

        // Hop size for 30fps
        let hopSize = Int(sampleRate / fps)
        guard hopSize > 0 else { return nil }

        // Setup FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Calculate logarithmic band edges (60Hz - 16kHz)
        let minFreq: Double = 60.0
        let maxFreq: Double = 16000.0
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        var bandEdges = [Double]()
        for i in 0...bandCount {
            let logFreq = logMin + (Double(i) / Double(bandCount)) * (logMax - logMin)
            bandEdges.append(pow(10, logFreq))
        }

        // Pre-compute Hann window
        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Read using the file's native processing format (preserves channel count)
        let processingFormat = audioFile.processingFormat
        let channelCount = Int(processingFormat.channelCount)
        let chunkSize = AVAudioFrameCount(hopSize * 100) // Read in larger chunks for efficiency
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkSize) else {
            return nil
        }

        var allSamples = [Float]()
        allSamples.reserveCapacity(Int(totalFrames))

        // Read all samples, mix down to mono if stereo/multichannel
        do {
            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let toRead = min(chunkSize, remaining)
                readBuffer.frameLength = 0
                try audioFile.read(into: readBuffer, frameCount: toRead)
                guard readBuffer.frameLength > 0, let channelData = readBuffer.floatChannelData else { break }
                let frameCount = Int(readBuffer.frameLength)

                if channelCount == 1 {
                    // Mono — use directly
                    let ptr = channelData[0]
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: frameCount))
                } else {
                    // Mix down to mono by averaging all channels
                    for i in 0..<frameCount {
                        var sum: Float = 0
                        for ch in 0..<channelCount {
                            sum += channelData[ch][i]
                        }
                        allSamples.append(sum / Float(channelCount))
                    }
                }
            }
        } catch {
            return nil
        }

        guard !allSamples.isEmpty else { return nil }

        // Process frames: hop through samples, apply FFT, extract bands
        var snapshots = [FrequencySnapshot]()
        let expectedFrames = Int(ceil(duration * fps))
        snapshots.reserveCapacity(expectedFrames)

        var realParts = [Float](repeating: 0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0, count: fftSize / 2)
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var normalizedMags = [Float](repeating: 0, count: fftSize / 2)

        var sampleOffset = 0
        while sampleOffset < allSamples.count {
            // Zero-fill windowed buffer
            for i in 0..<fftSize { windowedSamples[i] = 0 }

            // Copy samples and apply Hann window
            let available = min(fftSize, allSamples.count - sampleOffset)
            for i in 0..<available {
                windowedSamples[i] = allSamples[sampleOffset + i] * hannWindow[i]
            }

            // Convert to split complex format
            realParts = [Float](repeating: 0, count: fftSize / 2)
            imagParts = [Float](repeating: 0, count: fftSize / 2)
            var splitComplex = DSPSplitComplex(realp: &realParts, imagp: &imagParts)
            windowedSamples.withUnsafeBytes { ptr in
                ptr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
            }

            // FFT
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

            // Magnitude spectrum
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

            // Normalize
            var divisor = Float(fftSize * 2)
            vDSP_vsdiv(magnitudes, 1, &divisor, &normalizedMags, 1, vDSP_Length(fftSize / 2))

            // Extract 24 logarithmic bands
            let binSize = sampleRate / Double(fftSize)
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

                // Same pow(0.7) smoothing curve as the old real-time analyzer
                let curved = pow(normalized, 0.7)
                bandValues[i] = UInt8(min(255, max(0, curved * 255.0)))
            }

            snapshots.append(FrequencySnapshot(bands: bandValues))
            sampleOffset += hopSize
        }

        return FrequencyTimeline(
            snapshots: snapshots,
            framesPerSecond: fps,
            duration: duration
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
