import Accelerate
import AVFoundation
import Combine
import Foundation

#if DEBUG
import os
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
    
    /// Whether updates are paused (thread-safe via NSLock)
    private let isPausedLock = NSLock()
    private var _isPaused: Bool = false
    private var isPaused: Bool {
        get {
            isPausedLock.lock()
            defer { isPausedLock.unlock() }
            return _isPaused
        }
        set {
            isPausedLock.lock()
            defer { isPausedLock.unlock() }
            _isPaused = newValue
        }
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
        logger.debug("🎵 setupAudioTap called for player item - using REAL audio tap")
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
        
        #if DEBUG
        logger.debug("Audio analysis paused")
        #endif
    }
    
    @MainActor
    public func resumeUpdates() {
        guard isPaused else { return }
        isPaused = false
        
        #if DEBUG
        logger.debug("Audio analysis resumed")
        #endif
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

        // Get audio samples from first channel
        let audioBuffer = UnsafeBufferPointer<AudioBufferList>(start: bufferList, count: 1)
        guard let firstBuffer = audioBuffer.first?.mBuffers else { return }

        let samples = firstBuffer.mData?.assumingMemoryBound(to: Float.self)
        let sampleCount = min(Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size, fftSize)
        guard let samples = samples, sampleCount > 0 else { return }
        
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
        
        // Update on main thread
        Task { @MainActor in
            self.frequencyBands = bands
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
    logger.debug("🔊 tapInit called, storing analyzer reference...")
    #endif
    
    // Store the analyzer instance in tap storage so we can retrieve it in tapProcess
    guard let clientInfo = clientInfo else {
        #if DEBUG
        logger.error("❌ clientInfo is nil in tapInit!")
        #endif
        return
    }
    
    // Store the clientInfo pointer in the tap's storage
    tapStorageOut.pointee = clientInfo
    
    #if DEBUG
    logger.debug("✅ Audio tap initialized and analyzer stored")
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

/// Audio tap process callback - called for each audio buffer (~12 Hz).
/// This runs on the real-time audio render thread — keep it as lean as
/// possible: no logging, no allocations, no locks beyond what's strictly
/// required. Logger calls here cause audible glitches on low-RAM devices.
private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var timeRange = CMTimeRange()

    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        &timeRange,
        numberFramesOut
    )

    guard status == noErr else { return }

    // Retrieve the AudioAnalyzer stored during tapInit
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    guard clientInfo != nil else { return }
    let analyzer = Unmanaged<AudioAnalyzer>.fromOpaque(clientInfo).takeUnretainedValue()

    // Default to 44.1 kHz if we can't determine format
    let sampleRate: Double = 44100.0

    analyzer.processAudioBuffer(
        bufferListInOut,
        frameCount: Int(numberFramesOut.pointee),
        sampleRate: sampleRate
    )
}
