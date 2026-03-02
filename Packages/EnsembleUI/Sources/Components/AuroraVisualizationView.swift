import EnsembleCore
import SwiftUI
import Combine

/// Aurora-style frequency visualization inspired by Zune 3.0.
/// Displays soft, wispy blurred glow that rises from the bottom of the screen,
/// reacting to music loudness like a frequency meter.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let accentColor: Color

    // MARK: - State

    @State private var waveformHeights: [Double] = []
    @State private var frequencyBands: [Double] = []
    @State private var currentTime: TimeInterval = 0
    @State private var playbackState: PlaybackState = .stopped
    @State private var isVisible: Bool = false
    /// Smoothed band values for fluid animation
    @State private var smoothedBands: [Double] = Array(repeating: 0.0, count: 24)

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of frequency bands (fewer = wider, softer)
    private let bandCount = 24

    /// Maximum height of the aurora (mini player ~60pt + 5pt margin)
    private let maxHeight: CGFloat = 85

    /// Minimum height of bands (always visible base)
    private let minHeight: CGFloat = 8

    /// Height of the solid "pool" at the bottom
    private let poolHeight: CGFloat = 2

    /// Smoothing factor for band animations (lower = snappier response)
    private let smoothingFactor: Double = 0.35

    /// Breathing animation speed when paused
    private let breathingSpeed: Double = 0.5

    /// Breathing amplitude (how much bands move when paused)
    private let breathingAmplitude: Double = 0.2

    // MARK: - Init

    public init(playbackService: PlaybackServiceProtocol, accentColor: Color) {
        self.playbackService = playbackService
        self.accentColor = accentColor
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: false)) { timeline in
                Canvas { context, size in
                    drawAurora(
                        context: context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
            // Constrain the canvas to only the bottom area we need
            .frame(height: maxHeight + 20) // Extra for glow overflow
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 1.0), value: isVisible)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(playbackService.frequencyBandsPublisher) { bands in
            frequencyBands = bands
        }
        .onReceive(playbackService.waveformPublisher) { heights in
            waveformHeights = heights
        }
        .onReceive(playbackService.currentTimePublisher) { time in
            currentTime = time
        }
        .onReceive(playbackService.playbackStatePublisher) { state in
            playbackState = state
            updateVisibility(for: state)
        }
        .onAppear {
            frequencyBands = playbackService.frequencyBands
            waveformHeights = playbackService.waveformHeights
            currentTime = playbackService.currentTime
            playbackState = playbackService.playbackState
            updateVisibility(for: playbackState)
        }
    }

    // MARK: - Visibility

    /// Updates visibility based on playback state.
    /// Aurora stays visible when paused (with breathing) but hides when stopped.
    private func updateVisibility(for state: PlaybackState) {
        let newVisibility: Bool
        switch state {
        case .playing, .buffering, .loading, .paused:
            newVisibility = true
        case .stopped, .failed:
            newVisibility = false
        }

        if newVisibility != isVisible {
            #if DEBUG
            EnsembleLogger.debug("Aurora visibility: \(newVisibility) (state: \(state))")
            #endif
            isVisible = newVisibility
        }
    }

    // MARK: - Drawing

    /// Main drawing function for the aurora frequency visualization
    private func drawAurora(context: GraphicsContext, size: CGSize, time: Double) {
        let isPlaying = playbackState == .playing || playbackState == .buffering || playbackState == .loading

        // Calculate target band values
        let targetBands = calculateBandValues(time: time, isPlaying: isPlaying)

        // Smooth the bands for fluid animation
        var newSmoothed = smoothedBands
        for i in 0..<bandCount {
            let target = targetBands[i]
            let current = smoothedBands[i]
            // Fast attack, slightly slower decay for natural feel
            let attackFactor = target > current ? 0.15 : smoothingFactor
            let factor = isPlaying ? attackFactor : 0.85
            newSmoothed[i] = current * factor + target * (1.0 - factor)
        }

        // Update state for next frame
        DispatchQueue.main.async {
            self.smoothedBands = newSmoothed
        }

        // Draw multiple soft glow passes for blur effect (back to front)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 25, opacity: 0.15)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 12, opacity: 0.25)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 4, opacity: 0.35)
        drawBottomPool(context: context, size: size)
    }

    /// Calculates the intensity value for each frequency band
    /// When playing: uses real-time frequency analysis from AudioAnalyzer
    /// When paused: uses loudness-based breathing animation
    private func calculateBandValues(time: Double, isPlaying: Bool) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)

        if isPlaying && !frequencyBands.isEmpty {
            // Use real-time frequency data from audio analyzer
            // frequencyBands is already normalized to 0.0-1.0 range
            for i in 0..<min(bandCount, frequencyBands.count) {
                bands[i] = max(0.08, min(1.0, frequencyBands[i]))
            }
        } else if isPlaying {
            // Fallback to loudness-based visualization if frequency data not available
            let baseLoudness = sampleLoudness()
            let globalPulse = sin(time * 3.0) * 0.08 + sin(time * 5.5) * 0.05

            for i in 0..<bandCount {
                let normalizedPosition = Double(i) / Double(bandCount - 1)
                let frequencyWeight = calculateFrequencyWeight(normalizedPosition)
                let bandSeed = Double(i * 7919 % 100) / 100.0
                let staticVariation = (bandSeed - 0.5) * 0.15
                let intensity = (baseLoudness + globalPulse) * frequencyWeight + staticVariation
                bands[i] = max(0.08, min(1.0, intensity))
            }
        } else {
            // Breathing animation when paused
            let baseLoudness = sampleLoudness()
            for i in 0..<bandCount {
                bands[i] = calculateBreathingValue(
                    bandIndex: i,
                    time: time,
                    baseLoudness: baseLoudness
                )
            }
        }

        return bands
    }

    /// Calculates frequency weighting to simulate bass-heavy response
    private func calculateFrequencyWeight(_ normalizedPosition: Double) -> Double {
        // Bell curve favoring lower-mid frequencies with gradual treble rolloff
        let bassBoost = exp(-pow((normalizedPosition - 0.15) * 2.5, 2))
        let midPresence = exp(-pow((normalizedPosition - 0.4) * 2.0, 2)) * 0.7
        let trebleRolloff = 1.0 - normalizedPosition * 0.4

        return (bassBoost + midPresence) * trebleRolloff * 0.8 + 0.2
    }

    /// Calculates breathing animation value for a band when paused
    private func calculateBreathingValue(bandIndex: Int, time: Double, baseLoudness: Double) -> Double {
        let normalizedPosition = Double(bandIndex) / Double(bandCount - 1)
        let breathTime = time * breathingSpeed

        // Multiple overlapping sine waves for organic breathing
        let primaryBreath = sin(breathTime * 0.8) * 0.5 + 0.5
        let phaseOffset = normalizedPosition * Double.pi * 2
        let secondaryBreath = sin(breathTime * 1.3 + phaseOffset) * 0.3
        let tertiaryBreath = sin(breathTime * 2.1 + phaseOffset * 0.7) * 0.1

        // Keep frequency shape when paused
        let frequencyWeight = calculateFrequencyWeight(normalizedPosition)

        let breathValue = (primaryBreath + secondaryBreath + tertiaryBreath) * breathingAmplitude
        let baseValue = baseLoudness * 0.3 + 0.15

        return max(0.08, min(0.5, (baseValue + breathValue) * frequencyWeight))
    }

    /// Draws a soft glow layer with wide, overlapping bands
    private func drawSoftGlowLayer(
        context: GraphicsContext,
        size: CGSize,
        bands: [Double],
        blur: CGFloat,
        opacity: Double
    ) {
        let bandWidth = size.width / CGFloat(bandCount)
        let baseOpacity = (colorScheme == .dark ? 0.5 : 0.35) * opacity

        for i in 0..<bandCount {
            let intensity = bands[i]
            let height = minHeight + (maxHeight - minHeight) * CGFloat(intensity)

            // Center the band and make it wide for overlap
            let centerX = (CGFloat(i) + 0.5) * bandWidth
            let glowWidth = bandWidth * 4 // Wide overlap for blending
            let x = centerX - glowWidth / 2
            let y = size.height - height - poolHeight

            // Create vertical gradient: concentrated at bottom, fading up
            let bandGradient = Gradient(stops: [
                .init(color: accentColor.opacity(baseOpacity * intensity), location: 0.0),
                .init(color: accentColor.opacity(baseOpacity * intensity * 0.7), location: 0.2),
                .init(color: accentColor.opacity(baseOpacity * intensity * 0.3), location: 0.5),
                .init(color: accentColor.opacity(0), location: 1.0)
            ])

            // Use ellipse for softer edges instead of rectangle
            let glowRect = CGRect(
                x: x,
                y: y,
                width: glowWidth,
                height: height + poolHeight
            )

            var bandContext = context
            bandContext.blendMode = .plusLighter

            // Apply blur filter for soft glow
            bandContext.addFilter(.blur(radius: blur))

            bandContext.fill(
                Path(ellipseIn: glowRect),
                with: .linearGradient(
                    bandGradient,
                    startPoint: CGPoint(x: glowRect.midX, y: glowRect.maxY),
                    endPoint: CGPoint(x: glowRect.midX, y: glowRect.minY)
                )
            )
        }
    }

    /// Draws the solid color pool at the very bottom
    private func drawBottomPool(context: GraphicsContext, size: CGSize) {
        let poolOpacity = colorScheme == .dark ? 0.5 : 0.35

        // Soft gradient pool at the bottom
        let poolRect = CGRect(
            x: 0,
            y: size.height - poolHeight - 15,
            width: size.width,
            height: poolHeight + 15
        )

        let poolGradient = Gradient(colors: [
            .clear,
            accentColor.opacity(poolOpacity * 0.3),
            accentColor.opacity(poolOpacity * 0.6)
        ])

        var poolContext = context
        poolContext.blendMode = .plusLighter
        poolContext.fill(
            Path(poolRect),
            with: .linearGradient(
                poolGradient,
                startPoint: CGPoint(x: poolRect.midX, y: poolRect.minY),
                endPoint: CGPoint(x: poolRect.midX, y: poolRect.maxY)
            )
        )
    }

    // MARK: - Loudness Sampling

    /// Samples the current loudness from waveform data based on playback position
    private func sampleLoudness() -> Double {
        let currentDuration = playbackService.duration
        guard !waveformHeights.isEmpty, currentDuration > 0 else {
            return 0.3 // Default idle value
        }

        // Calculate position in waveform array
        let progress = min(1.0, max(0.0, currentTime / currentDuration))
        let floatIndex = progress * Double(waveformHeights.count - 1)

        // Linear interpolation between adjacent samples
        let lowerIndex = Int(floatIndex)
        let upperIndex = min(lowerIndex + 1, waveformHeights.count - 1)
        let fraction = floatIndex - Double(lowerIndex)

        let lowerValue = waveformHeights[lowerIndex]
        let upperValue = waveformHeights[upperIndex]

        let interpolated = lowerValue + (upperValue - lowerValue) * fraction

        return max(0.2, interpolated)
    }
}
