import Accelerate
import AVFoundation
import Combine
import Foundation
import os.lock

#if DEBUG
private let logger = Logger(subsystem: "com.felicity.Ensemble", category: "AudioAnalyzer")
#endif

// MARK: - Audio Analyzer Protocol

/// Protocol for real-time audio frequency analysis
public protocol AudioAnalyzerProtocol: AnyObject {
    /// Current frequency bands (24 bands from 60Hz to 16kHz)
    var frequencyBands: [Double] { get }
    
    /// Publisher for frequency band updates (~30 Hz)
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }
    
    /// Setup audio tap for an AVPlayerItem
    @MainActor func setupAudioTap(for playerItem: AVPlayerItem)
    
    /// Remove audio tap and stop analysis
    @MainActor func stopAnalysis()
    
    /// Pause frequency band updates (keeps tap alive but stops publishing)
    @MainActor func pauseUpdates()
    
    /// Resume frequency band updates
    @MainActor func resumeUpdates()
}

// MARK: - Audio Analyzer

/// Real-time audio frequency analyzer using MTAudioProcessingTap and FFT
/// Extracts 24 frequency bands from 60Hz to 16kHz for visualization
public final class AudioAnalyzer: AudioAnalyzerProtocol {
    
    // MARK: - Configuration
    
    /// Number of frequency bands to extract
    private let bandCount = 24
    
    /// FFT size (must be power of 2)
    private let fftSize = 1024
    
    /// Frequency range for analysis
    private let minFrequency: Double = 60.0
    private let maxFrequency: Double = 16000.0
    
    /// Update rate limiter (max 30 fps)
    private let updateInterval: TimeInterval = 1.0 / 30.0
    private var lastUpdateTime: TimeInterval = 0
    
    // MARK: - State
    
    @Published public private(set) var frequencyBands: [Double] = []
    
    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
        $frequencyBands.eraseToAnyPublisher()
    }
    
    /// FFT setup for frequency analysis
    private var fftSetup: FFTSetup?
    
    /// Current audio tap
    private var audioMix: AVAudioMix?
    
    /// Frequency band edges (in Hz)
    private var bandEdges: [Double] = []
    
    /// Mock data generator timer (simulator only)
    private var mockDataTimer: Timer?
    
    /// Mock data phase for animation
    private var mockDataPhase: Double = 0.0
    
    /// Whether updates are paused (thread-safe via OSAllocatedUnfairLock)
    private let isPausedLock = OSAllocatedUnfairLock()
    private var _isPaused: Bool = false
    private var isPaused: Bool {
        get { isPausedLock.withLock { _isPaused } }
        set { isPausedLock.withLock { _isPaused = newValue } }
    }
    
    // MARK: - Init
    
    public init() {
        setupFFT()
        calculateBandEdges()
        
        // Initialize with silent bands
        frequencyBands = Array(repeating: 0.0, count: bandCount)
        
        #if DEBUG
        logger.debug("AudioAnalyzer initialized with \(self.bandCount) bands (\(Int(self.minFrequency))Hz - \(Int(self.maxFrequency))Hz)")
        #endif
    }
    
    deinit {
        if let fftSetup = fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }
    
    // MARK: - FFT Setup
    
    /// Setup FFT for frequency analysis using Accelerate framework
    private func setupFFT() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        
        guard fftSetup != nil else {
            #if DEBUG
            logger.error("Failed to create FFT setup")
            #endif
            return
        }
    }
    
    /// Calculate logarithmic frequency band edges
    /// Bass-heavy distribution with more resolution in lower frequencies
    private func calculateBandEdges() {
        bandEdges = []
        
        let logMin = log10(minFrequency)
        let logMax = log10(maxFrequency)
        let logRange = logMax - logMin
        
        for i in 0...bandCount {
            let logFreq = logMin + (Double(i) / Double(bandCount)) * logRange
            let freq = pow(10, logFreq)
            bandEdges.append(freq)
        }
        
        #if DEBUG
        logger.debug("Band edges: \(self.bandEdges.map { Int($0) })")
        #endif
    }
    
    // MARK: - Audio Tap
    
    @MainActor
    public func setupAudioTap(for playerItem: AVPlayerItem) {
        stopAnalysis()
        
        #if DEBUG
        logger.debug("🎵 setupAudioTap called for player item")
        #endif
        
        #if targetEnvironment(simulator)
        // MTAudioProcessingTap doesn't work reliably in iOS Simulator
        // Use mock data generator for testing
        #if DEBUG
        logger.warning("⚠️ Running in simulator - using mock frequency data generator")
        #endif
        startMockDataGenerator()
        return
        #endif
        
        guard let fftSetup = fftSetup else {
            #if DEBUG
            logger.error("Cannot setup audio tap: FFT not initialized")
            #endif
            return
        }
        
        // Get audio tracks
        guard let audioTrack = playerItem.asset.tracks(withMediaType: .audio).first else {
            #if DEBUG
            logger.debug("No audio track found in player item")
            #endif
            return
        }
        
        // Create audio processing tap callbacks
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        guard status == noErr, let audioTap = tap else {
            #if DEBUG
            logger.error("Failed to create audio processing tap: \(status)")
            #endif
            return
        }
        
        // Create audio mix with the tap
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = audioTap
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        
        // Apply the audio mix to the player item
        playerItem.audioMix = audioMix
        self.audioMix = audioMix
        
        #if DEBUG
        logger.debug("✅ Audio tap setup complete")
        #endif
    }
    
    @MainActor
    public func stopAnalysis() {
        audioMix = nil
        mockDataTimer?.invalidate()
        mockDataTimer = nil
        isPaused = false
        
        // Reset bands to silent
        frequencyBands = Array(repeating: 0.0, count: bandCount)
        
        #if DEBUG
        logger.debug("Audio analysis stopped")
        #endif
    }
    
    @MainActor
    public func pauseUpdates() {
        isPaused = true
        mockDataTimer?.invalidate()
        mockDataTimer = nil
        
        #if DEBUG
        logger.debug("Audio analysis paused")
        #endif
    }
    
    @MainActor
    public func resumeUpdates() {
        guard isPaused else { return }
        isPaused = false
        
        #if targetEnvironment(simulator)
        // Restart mock data generator
        startMockDataGenerator()
        #endif
        
        #if DEBUG
        logger.debug("Audio analysis resumed")
        #endif
    }
    
    // MARK: - Mock Data Generator (Simulator Only)
    
    @MainActor
    private func startMockDataGenerator() {
        mockDataTimer?.invalidate()
        mockDataPhase = 0.0
        
        mockDataTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.generateMockFrequencyBands()
        }
        
        #if DEBUG
        logger.debug("✅ Mock data generator started (simulator mode)")
        #endif
    }
    
    @MainActor
    private func generateMockFrequencyBands() {
        mockDataPhase += 0.1
        
        var bands = [Double](repeating: 0.0, count: bandCount)
        
        // Generate realistic-looking frequency spectrum
        // Bass frequencies (0-7): higher energy
        // Mid frequencies (8-15): moderate energy
        // High frequencies (16-23): lower energy
        for i in 0..<bandCount {
            let normalizedPosition = Double(i) / Double(bandCount - 1)
            
            // Bass boost for lower frequencies
            let bassBoost = exp(-normalizedPosition * 2.0)
            
            // Multiple sine waves at different speeds for organic movement
            let wave1 = sin(mockDataPhase + Double(i) * 0.3)
            let wave2 = sin(mockDataPhase * 1.5 + Double(i) * 0.2)
            let wave3 = sin(mockDataPhase * 0.7 + Double(i) * 0.5)
            
            // Combine waves with bass boost
            let amplitude = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2) * bassBoost
            
            // Normalize to 0.0-1.0 range with minimum floor
            bands[i] = max(0.1, min(1.0, (amplitude + 1.0) / 2.0))
        }
        
        frequencyBands = bands
    }
    
    // MARK: - Audio Processing
    
    /// Process audio samples and extract frequency bands
    fileprivate func processAudioBuffer(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, sampleRate: Double) {
        // Skip processing if paused
        guard !isPaused else { return }
        
        guard let fftSetup = fftSetup else {
            #if DEBUG
            logger.error("⚠️ FFT setup is nil, cannot process audio")
            #endif
            return
        }
        
        // Rate limit updates to ~30 fps
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = currentTime
        
        #if DEBUG
        logger.debug("🎵 Processing audio buffer: \(frameCount) frames at \(Int(sampleRate))Hz")
        #endif
        
        // Get audio samples from first channel
        let audioBuffer = UnsafeBufferPointer<AudioBufferList>(start: bufferList, count: 1)
        guard let firstBuffer = audioBuffer.first?.mBuffers else {
            #if DEBUG
            logger.error("⚠️ No audio buffer available")
            #endif
            return
        }
        
        let samples = firstBuffer.mData?.assumingMemoryBound(to: Float.self)
        let sampleCount = min(Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size, fftSize)
        
        guard let samples = samples, sampleCount > 0 else {
            #if DEBUG
            logger.error("⚠️ No samples or sample count is 0")
            #endif
            return
        }
        
        // Prepare FFT input
        var realParts = [Float](repeating: 0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0, count: fftSize / 2)
        
        // Copy and window the samples (Hann window)
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        for i in 0..<sampleCount {
            let window = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(sampleCount - 1)))
            windowedSamples[i] = samples[i] * window
        }
        
        // Convert to split complex format
        var splitComplex = DSPSplitComplex(realp: &realParts, imagp: &imagParts)
        windowedSamples.withUnsafeBytes { ptr in
            ptr.withMemoryRebound(to: DSPComplex.self) { complexPtr in
                vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }
        
        // Perform FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
        
        // Calculate magnitude spectrum
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
        
        // Convert to dB scale with normalization
        var normalizedMagnitudes = [Float](repeating: 0, count: fftSize / 2)
        var divisor = Float(fftSize * 2)
        vDSP_vsdiv(magnitudes, 1, &divisor, &normalizedMagnitudes, 1, vDSP_Length(fftSize / 2))
        
        // Extract frequency bands
        let bands = extractFrequencyBands(from: normalizedMagnitudes, sampleRate: sampleRate)
        
        #if DEBUG
        let avgBand = bands.reduce(0.0, +) / Double(bands.count)
        logger.debug("🎵 Extracted \(bands.count) frequency bands, avg: \(String(format: "%.3f", avgBand))")
        #endif
        
        // Update on main thread
        Task { @MainActor in
            self.frequencyBands = bands
            #if DEBUG
            logger.debug("✅ Updated frequency bands on main thread")
            #endif
        }
    }
    
    /// Extract logarithmic frequency bands from FFT magnitude spectrum
    private func extractFrequencyBands(from magnitudes: [Float], sampleRate: Double) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)
        
        let binSize = sampleRate / Double(fftSize)
        
        for i in 0..<bandCount {
            let lowerFreq = bandEdges[i]
            let upperFreq = bandEdges[i + 1]
            
            let lowerBin = Int(lowerFreq / binSize)
            let upperBin = Int(upperFreq / binSize)
            
            guard lowerBin < magnitudes.count else { continue }
            
            // Average magnitude in this frequency range
            let binRange = max(1, upperBin - lowerBin)
            var sum: Float = 0.0
            var count: Int = 0
            
            for bin in lowerBin..<min(upperBin, magnitudes.count) {
                sum += magnitudes[bin]
                count += 1
            }
            
            guard count > 0 else { continue }
            
            let average = sum / Float(count)
            
            // Convert to dB and normalize to 0.0-1.0 range
            // Typical audio range: -60dB to 0dB
            let db = 20.0 * log10(Double(max(average, 1e-10)))
            let normalized = min(1.0, max(0.0, (db + 60.0) / 60.0))
            
            // Apply subtle smoothing curve for better visualization
            bands[i] = pow(normalized, 0.7)
        }
        
        return bands
    }
}

// MARK: - Audio Tap Callbacks

/// Audio tap initialization callback
private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    #if DEBUG
    logger.debug("Audio tap initialized")
    #endif
}

/// Audio tap finalization callback
private func tapFinalize(tap: MTAudioProcessingTap) {
    #if DEBUG
    logger.debug("Audio tap finalized")
    #endif
}

/// Audio tap preparation callback
private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    #if DEBUG
    logger.debug("Audio tap prepared for \(maxFrames) frames at \(processingFormat.pointee.mSampleRate)Hz")
    #endif
}

/// Audio tap unprepare callback
private func tapUnprepare(tap: MTAudioProcessingTap) {
    #if DEBUG
    logger.debug("Audio tap unprepared")
    #endif
}

/// Audio tap process callback - called for each audio buffer
private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    #if DEBUG
    logger.debug("🔊 tapProcess called with \(numberFrames) frames")
    #endif
    
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        &timeRange,
        numberFramesOut
    )
    
    guard status == noErr else {
        #if DEBUG
        logger.error("Failed to get source audio: \(status)")
        #endif
        return
    }
    
    // Get analyzer instance from client info
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    guard clientInfo != nil else {
        #if DEBUG
        logger.error("⚠️ Client info is nil")
        #endif
        return
    }
    let analyzer = Unmanaged<AudioAnalyzer>.fromOpaque(clientInfo).takeUnretainedValue()
    
    // Get sample rate from audio buffer format (typical is 44.1kHz or 48kHz)
    let audioBuffer = UnsafeBufferPointer<AudioBufferList>(start: bufferListInOut, count: 1)
    // Default to 44.1kHz if we can't determine format
    let sampleRate: Double = 44100.0
    
    #if DEBUG
    logger.debug("🔊 About to call processAudioBuffer with \(numberFramesOut.pointee) frames")
    #endif
    
    // Process the audio directly (already on audio thread)
    analyzer.processAudioBuffer(
        bufferListInOut,
        frameCount: Int(numberFramesOut.pointee),
        sampleRate: sampleRate
    )
}
