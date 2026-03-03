import EnsembleCore
import SwiftUI
import Combine

/// Real-time frequency visualization with soft aurora-style glow.
/// Displays 24 frequency bands (60Hz-16kHz) from live FFT analysis,
/// rising from the bottom with blurred, overlapping wisps.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let accentColor: Color

    // MARK: - State

    @State private var frequencyBands: [Double] = []
    @State private var playbackState: PlaybackState = .stopped
    @State private var isVisible: Bool = false
    /// Smoothed band values for fluid animation
    @State private var smoothedBands: [Double] = Array(repeating: 0.0, count: 24)
    /// Peak hold for each band (visual drama)
    @State private var peakHolds: [Double] = Array(repeating: 0.0, count: 24)
    @State private var peakDecayTimers: [Double] = Array(repeating: 0.0, count: 24)

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of frequency bands (matches AudioAnalyzer)
    private let bandCount = 24

    /// Maximum height of the aurora (mini player ~60pt + 5pt margin)
    private let maxHeight: CGFloat = 220

    /// Minimum height of bands (always visible base)
    private let minHeight: CGFloat = 25

    /// Height of the solid "pool" at the bottom
    private let poolHeight: CGFloat = 30

    /// Smoothing factor for band animations (lower = snappier response)
    private let smoothingFactor: Double = 1.5
    
    /// Attack smoothing (how fast bands rise) - increased for smoother transitions
    private let attackFactor: Double = 0.7
    
    /// Decay smoothing (how fast bands fall) - increased for smoother transitions
    private let decayFactor: Double = 0.7

    /// Peak hold time in seconds
    private let peakHoldTime: Double = 0.10
    
    /// Peak decay rate per second
    private let peakDecayRate: Double = 1.5

    /// Breathing animation speed when paused
    private let breathingSpeed: Double = 0.75

    /// Breathing amplitude (how much bands move when paused)
    private let breathingAmplitude: Double = 0.15

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
                .frame(width: geometry.size.width + 80)
                .frame(height: maxHeight + 40) // Slightly taller to allow for bottom overflow
                .offset(x: -40, y: 15) // Offset down to hide the very bottom of the pool
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(isVisible ? 0.7 : 0) // Reduced overall opacity for transparency
        .animation(.easeInOut(duration: 1.0), value: isVisible)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(playbackService.frequencyBandsPublisher) { bands in
            frequencyBands = bands
        }
        .onReceive(playbackService.playbackStatePublisher) { state in
            playbackState = state
            updateVisibility(for: state)
        }
        .onAppear {
            frequencyBands = playbackService.frequencyBands
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

        // Calculate target band values from real-time frequency data
        let targetBands = calculateBandValues(time: time, isPlaying: isPlaying)

        // Smooth the bands with fast attack, slower decay for natural feel
        var newSmoothed = smoothedBands
        var newPeakHolds = peakHolds
        var newPeakTimers = peakDecayTimers
        
        let deltaTime: Double = 1.0 / 60.0 // Approximate frame delta
        
        for i in 0..<bandCount {
            let target = targetBands[i]
            let current = smoothedBands[i]
            
            // Attack/decay smoothing
            if target > current {
                // Fast attack on rising signal
                newSmoothed[i] = current + (target - current) * (1.0 - attackFactor)
            } else {
                // Slower decay on falling signal
                newSmoothed[i] = current + (target - current) * (1.0 - decayFactor)
            }
            
            // Peak hold logic
            if newSmoothed[i] > newPeakHolds[i] {
                // New peak
                newPeakHolds[i] = newSmoothed[i]
                newPeakTimers[i] = peakHoldTime
            } else if newPeakTimers[i] > 0 {
                // Hold the peak
                newPeakTimers[i] -= deltaTime
            } else {
                // Decay the peak
                newPeakHolds[i] = max(newSmoothed[i], newPeakHolds[i] - peakDecayRate * deltaTime)
            }
        }

        // Update state for next frame
        DispatchQueue.main.async {
            self.smoothedBands = newSmoothed
            self.peakHolds = newPeakHolds
            self.peakDecayTimers = newPeakTimers
        }

        // Draw multiple soft glow passes for ethereal blur effect (back to front)
        // Wide, soft outer glow
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 60, opacity: 0.03)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 45, opacity: 0.05)
        
        // Mid-range glow for depth
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 30, opacity: 0.12)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 18, opacity: 0.18)
        
        // Tighter glow for definition
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 10, opacity: 0.25)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 4, opacity: 0.3)
        
        // Peak highlights (subtle)
        if isPlaying {
            // drawPeakLayer(context: context, size: size, peaks: newPeakHolds)
        }
        
        drawBottomPool(context: context, size: size)
    }

    /// Calculates the intensity value for each frequency band
    /// When playing: uses real-time frequency analysis from AudioAnalyzer
    /// When paused/stopped: uses gentle breathing animation
    private func calculateBandValues(time: Double, isPlaying: Bool) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)

        if isPlaying {
            if !frequencyBands.isEmpty {
                // Use real-time frequency data from audio analyzer
                // frequencyBands is already normalized to 0.0-1.0 range
                for i in 0..<min(bandCount, frequencyBands.count) {
                    // Apply slight boost to low frequencies for visual impact
                    let normalizedPosition = Double(i) / Double(bandCount - 1)
                    let bassBoost = 1.0 + (1.0 - normalizedPosition) * 0.4
                    
                    let rawValue = frequencyBands[i]
                    let boosted = min(1.0, rawValue * bassBoost)
                    
                    // Keep minimum floor for visibility
                    bands[i] = max(0.05, boosted)
                }
            } else {
                // No frequency data yet, show minimal activity
                for i in 0..<bandCount {
                    bands[i] = 0.1
                }
            }
        } else {
            // Gentle breathing animation when paused
            for i in 0..<bandCount {
                bands[i] = calculateBreathingValue(bandIndex: i, time: time)
            }
        }

        return bands
    }

    /// Calculates gentle breathing animation value for a band when paused
    private func calculateBreathingValue(bandIndex: Int, time: Double) -> Double {
        let normalizedPosition = Double(bandIndex) / Double(bandCount - 1)
        let breathTime = time * breathingSpeed

        // Multiple overlapping sine waves for organic breathing
        let primaryBreath = sin(breathTime * 0.8) * 0.5 + 0.5
        let phaseOffset = normalizedPosition * Double.pi * 2
        let secondaryBreath = sin(breathTime * 1.3 + phaseOffset) * 0.3
        let tertiaryBreath = sin(breathTime * 2.1 + phaseOffset * 0.7) * 0.1

        // Bass-heavy shape even when paused
        let bassShape = 1.0 + (1.0 - normalizedPosition) * 0.3

        let breathValue = (primaryBreath + secondaryBreath + tertiaryBreath) * breathingAmplitude
        let baseValue = 0.15 * bassShape

        return max(0.05, min(0.4, baseValue + breathValue))
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
        let baseOpacity = (colorScheme == .dark ? 0.7 : 0.5) * opacity

        for i in 0..<bandCount {
            let intensity = bands[i]
            
            // Normalized position (0.0 to 1.0) for bell curve calculation
            let normalizedPos = Double(i) / Double(bandCount - 1)
            
            // Bell curve factor (Gaussian-like) to make middle bands taller
            // peak at 0.5, sigma of ~0.35 for a nice spread
            let bellFactor = exp(-pow(normalizedPos - 0.5, 2) / (2 * pow(0.35, 2)))
            
            // Apply curve to intensity for better visual range
            let curvedIntensity = pow(intensity, 0.6)
            
            // Combined height factor (intensity * bell curve)
            let heightFactor = curvedIntensity * bellFactor
            
            let height = minHeight + (maxHeight - minHeight) * CGFloat(heightFactor)

            // Center the band and make it very wide for ethereal overlap
            let centerX = (CGFloat(i) + 0.5) * bandWidth
            let glowWidth = bandWidth * 4.5 // Wider overlap for more ethereal blending
            let x = centerX - glowWidth / 2
            let y = size.height - height - poolHeight

            // Create vertical gradient: concentrated at bottom, fading up gradually
            let intensityAlpha = max(0.3, curvedIntensity)
            let bandGradient = Gradient(stops: [
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha), location: 0.0),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.8), location: 0.1),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.6), location: 0.3),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.35), location: 0.6),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.15), location: 0.8),
                .init(color: accentColor.opacity(0), location: 1.0)
            ])

            // Use ellipse for softer edges
            let glowRect = CGRect(
                x: x,
                y: y,
                width: glowWidth,
                height: height + poolHeight
            )

            var bandContext = context
            bandContext.blendMode = .plusLighter
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
    
    /// Draws subtle peak hold indicators
    private func drawPeakLayer(context: GraphicsContext, size: CGSize, peaks: [Double]) {
        let bandWidth = size.width / CGFloat(bandCount)
        let peakOpacity = (colorScheme == .dark ? 0.4 : 0.3)

        for i in 0..<bandCount {
            let peakIntensity = peaks[i]
            guard peakIntensity > 0.1 else { continue }
            
            // Apply same bell curve to peaks for consistency
            let normalizedPos = Double(i) / Double(bandCount - 1)
            let bellFactor = exp(-pow(normalizedPos - 0.5, 2) / (2 * pow(0.35, 2)))
            
            let peakHeight = minHeight + (maxHeight - minHeight) * CGFloat(pow(peakIntensity, 0.6) * bellFactor)
            let centerX = (CGFloat(i) + 0.5) * bandWidth
            let peakWidth = bandWidth * 2.0
            
            let peakY = size.height - peakHeight - poolHeight
            
            // Small ellipse at peak position
            let peakRect = CGRect(
                x: centerX - peakWidth / 2,
                y: peakY - 2,
                width: peakWidth,
                height: 4
            )
            
            var peakContext = context
            peakContext.blendMode = .plusLighter
            peakContext.addFilter(.blur(radius: 4))
            
            peakContext.fill(
                Path(ellipseIn: peakRect),
                with: .color(accentColor.opacity(peakOpacity * peakIntensity))
            )
        }
    }

    /// Draws the solid color pool at the very bottom
    private func drawBottomPool(context: GraphicsContext, size: CGSize) {
        let poolOpacity = colorScheme == .dark ? 0.6 : 0.4

        // Soft gradient pool at the bottom
        let poolRect = CGRect(
            x: 0,
            y: size.height - poolHeight - 20,
            width: size.width,
            height: poolHeight + 20
        )

        let poolGradient = Gradient(colors: [
            .clear,
            accentColor.opacity(poolOpacity * 0.25),
            accentColor.opacity(poolOpacity * 0.5),
            accentColor.opacity(poolOpacity * 0.7)
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
}
