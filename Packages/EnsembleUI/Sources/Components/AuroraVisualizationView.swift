import EnsembleCore
import SwiftUI
import Combine

/// Aurora-style frequency visualization inspired by Zune 3.0.
/// Displays soft, wispy vertical frequency bands that rise from the bottom of the screen,
/// with colors bleeding into each other for an aurora borealis effect.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let accentColor: Color

    // MARK: - State

    @State private var waveformHeights: [Double] = []
    @State private var currentTime: TimeInterval = 0
    @State private var playbackState: PlaybackState = .stopped
    @State private var isVisible: Bool = false
    /// Smoothed band values for fluid animation
    @State private var smoothedBands: [Double] = Array(repeating: 0.0, count: 64)
    /// Previous frame's band values for interpolation
    @State private var previousBands: [Double] = Array(repeating: 0.0, count: 64)

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of frequency bands to display
    private let bandCount = 64

    /// Maximum height of bands as fraction of screen height
    private let maxHeightFraction: CGFloat = 0.45

    /// Minimum height of bands (always visible base)
    private let minHeightFraction: CGFloat = 0.02

    /// Height of the solid "pool" at the bottom
    private let poolHeight: CGFloat = 3

    /// Smoothing factor for band animations (0 = no smoothing, 1 = frozen)
    private let smoothingFactor: Double = 0.75

    /// Breathing animation speed when paused
    private let breathingSpeed: Double = 0.5

    /// Breathing amplitude (how much bands move when paused)
    private let breathingAmplitude: Double = 0.15

    // MARK: - Init

    public init(playbackService: PlaybackServiceProtocol, accentColor: Color) {
        self.playbackService = playbackService
        self.accentColor = accentColor
    }

    // MARK: - Body

    public var body: some View {
        TimelineView(.animation(paused: false)) { timeline in
            Canvas { context, size in
                drawAurora(
                    context: context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 1.0), value: isVisible)
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
            // Faster response when playing, slower breathing decay when paused
            let factor = isPlaying ? smoothingFactor : 0.92
            newSmoothed[i] = current * factor + target * (1.0 - factor)
        }

        // Update state for next frame
        DispatchQueue.main.async {
            self.previousBands = self.smoothedBands
            self.smoothedBands = newSmoothed
        }

        // Draw layers from back to front for proper blending
        drawAuroraGlow(context: context, size: size, bands: newSmoothed)
        drawAuroraBands(context: context, size: size, bands: newSmoothed)
        drawBottomPool(context: context, size: size)
    }

    /// Calculates the intensity value for each frequency band
    private func calculateBandValues(time: Double, isPlaying: Bool) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)

        // Get base loudness from waveform
        let baseLoudness = sampleLoudness()

        for i in 0..<bandCount {
            let normalizedPosition = Double(i) / Double(bandCount - 1)

            if isPlaying {
                // Simulate frequency distribution: bass (left) is typically louder
                let frequencyWeight = calculateFrequencyWeight(normalizedPosition)

                // Add variation based on position and time for organic movement
                let phaseOffset = normalizedPosition * 6.0
                let variation = sin(time * 3.0 + phaseOffset) * 0.15
                let secondaryWave = sin(time * 1.7 + phaseOffset * 0.5) * 0.08

                // Combine loudness with frequency weighting and variation
                let intensity = baseLoudness * frequencyWeight + variation + secondaryWave
                bands[i] = max(0.05, min(1.0, intensity))
            } else {
                // Breathing animation when paused
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
    /// Bass frequencies (left side) tend to have more energy in music
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

        // Multiple overlapping sine waves for organic breathing
        let breathTime = time * breathingSpeed

        // Primary slow breath
        let primaryBreath = sin(breathTime * 0.8) * 0.5 + 0.5

        // Secondary wave with position offset for ripple effect
        let phaseOffset = normalizedPosition * Double.pi * 2
        let secondaryBreath = sin(breathTime * 1.3 + phaseOffset) * 0.3

        // Tertiary subtle variation
        let tertiaryBreath = sin(breathTime * 2.1 + phaseOffset * 0.7) * 0.1

        // Frequency weighting even when paused (keeps the shape)
        let frequencyWeight = calculateFrequencyWeight(normalizedPosition)

        // Combine for final breathing value
        let breathValue = (primaryBreath + secondaryBreath + tertiaryBreath) * breathingAmplitude
        let baseValue = baseLoudness * 0.3 + 0.1 // Keep some memory of last played loudness

        return max(0.05, min(0.4, (baseValue + breathValue) * frequencyWeight))
    }

    /// Draws the soft glow layer behind the bands
    private func drawAuroraGlow(context: GraphicsContext, size: CGSize, bands: [Double]) {
        let bandWidth = size.width / CGFloat(bandCount)
        let maxHeight = size.height * maxHeightFraction
        let baseOpacity = colorScheme == .dark ? 0.2 : 0.12

        // Draw wider, softer glow rectangles behind each band
        for i in 0..<bandCount {
            let intensity = bands[i]
            let height = maxHeight * CGFloat(intensity)
            let x = CGFloat(i) * bandWidth
            let y = size.height - height - poolHeight

            // Glow extends wider than the band
            let glowWidth = bandWidth * 3
            let glowX = x - bandWidth

            // Create vertical gradient for glow
            let glowGradient = Gradient(colors: [
                accentColor.opacity(baseOpacity * intensity * 0.3),
                accentColor.opacity(baseOpacity * intensity),
                accentColor.opacity(0)
            ])

            let glowRect = CGRect(
                x: glowX,
                y: y,
                width: glowWidth,
                height: height + poolHeight
            )

            var glowContext = context
            glowContext.blendMode = .plusLighter
            glowContext.fill(
                Path(glowRect),
                with: .linearGradient(
                    glowGradient,
                    startPoint: CGPoint(x: glowRect.midX, y: glowRect.maxY),
                    endPoint: CGPoint(x: glowRect.midX, y: glowRect.minY)
                )
            )
        }
    }

    /// Draws the main frequency band columns
    private func drawAuroraBands(context: GraphicsContext, size: CGSize, bands: [Double]) {
        let bandWidth = size.width / CGFloat(bandCount)
        let maxHeight = size.height * maxHeightFraction
        let minHeight = size.height * minHeightFraction
        let baseOpacity = colorScheme == .dark ? 0.5 : 0.35

        for i in 0..<bandCount {
            let intensity = bands[i]
            let height = minHeight + (maxHeight - minHeight) * CGFloat(intensity)
            let x = CGFloat(i) * bandWidth
            let y = size.height - height - poolHeight

            // Create vertical gradient: solid at bottom, fading to transparent at top
            let bandGradient = Gradient(stops: [
                .init(color: accentColor.opacity(baseOpacity * intensity), location: 0.0),
                .init(color: accentColor.opacity(baseOpacity * intensity * 0.8), location: 0.3),
                .init(color: accentColor.opacity(baseOpacity * intensity * 0.4), location: 0.6),
                .init(color: accentColor.opacity(0), location: 1.0)
            ])

            let bandRect = CGRect(
                x: x,
                y: y,
                width: bandWidth + 1, // Slight overlap to prevent gaps
                height: height + poolHeight
            )

            var bandContext = context
            bandContext.blendMode = .plusLighter
            bandContext.fill(
                Path(bandRect),
                with: .linearGradient(
                    bandGradient,
                    startPoint: CGPoint(x: bandRect.midX, y: bandRect.maxY),
                    endPoint: CGPoint(x: bandRect.midX, y: bandRect.minY)
                )
            )
        }
    }

    /// Draws the solid color pool at the very bottom
    private func drawBottomPool(context: GraphicsContext, size: CGSize) {
        let poolOpacity = colorScheme == .dark ? 0.6 : 0.4

        // Solid line at the very bottom
        let poolRect = CGRect(
            x: 0,
            y: size.height - poolHeight,
            width: size.width,
            height: poolHeight
        )

        var poolContext = context
        poolContext.blendMode = .plusLighter
        poolContext.fill(
            Path(poolRect),
            with: .color(accentColor.opacity(poolOpacity))
        )

        // Gradient fade just above the pool
        let fadeHeight: CGFloat = 20
        let fadeRect = CGRect(
            x: 0,
            y: size.height - poolHeight - fadeHeight,
            width: size.width,
            height: fadeHeight
        )

        let fadeGradient = Gradient(colors: [
            .clear,
            accentColor.opacity(poolOpacity * 0.5)
        ])

        poolContext.fill(
            Path(fadeRect),
            with: .linearGradient(
                fadeGradient,
                startPoint: CGPoint(x: fadeRect.midX, y: fadeRect.minY),
                endPoint: CGPoint(x: fadeRect.midX, y: fadeRect.maxY)
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

        // Return with minimum floor for visual presence
        return max(0.2, interpolated)
    }
}
