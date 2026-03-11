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
    private let poolHeight: CGFloat = 48

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

    /// Whether the aurora should pause rendering (e.g. Now Playing sheet covers it)
    private let isPaused: Bool

    public init(playbackService: PlaybackServiceProtocol, accentColor: Color, isPaused: Bool = false) {
        self.playbackService = playbackService
        self.accentColor = accentColor
        self.isPaused = isPaused
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            // Cap at 30fps — band data from FrequencyAnalysisService already updates at 30fps,
            // so 60fps doubles GPU work for zero visual benefit. Pause when occluded.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused || !isVisible)) { timeline in
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
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(playbackService.frequencyBandsPublisher) { bands in
            frequencyBands = bands
        }
        .onReceive(playbackService.playbackStatePublisher) { state in
            // Deduplicate: skip repeated state values to avoid redundant visibility checks
            guard state != playbackState else { return }
            playbackState = state
            // Animate visibility only when the playback state actively changes.
            // This produces the desired fade-in when the user first presses play.
            updateVisibility(for: state, animated: true)
        }
        .onAppear {
            frequencyBands = playbackService.frequencyBands
            let currentState = playbackService.playbackState
            playbackState = currentState
            // Snap directly without animation: onAppear fires on tab switches too,
            // and we don't want the aurora to fade in every time the user changes tabs.
            // The animated fade is reserved for actual play/stop transitions via onReceive.
            updateVisibility(for: currentState, animated: false)
        }
    }

    // MARK: - Visibility

    /// Updates visibility based on playback state.
    /// Aurora stays visible when paused (with breathing) but hides when stopped.
    /// Pass animated: false (e.g. on onAppear) to snap without the fade transition.
    private func updateVisibility(for state: PlaybackState, animated: Bool) {
        let newVisibility: Bool
        switch state {
        case .playing, .buffering, .loading, .paused:
            newVisibility = true
        case .stopped, .failed:
            newVisibility = false
            // Reset band state so stale values don't flash when playback resumes
            smoothedBands = Array(repeating: 0.0, count: bandCount)
            peakHolds = Array(repeating: 0.0, count: bandCount)
            peakDecayTimers = Array(repeating: 0.0, count: bandCount)
        }

        guard newVisibility != isVisible else { return }

        #if DEBUG
        EnsembleLogger.debug("Aurora visibility: \(newVisibility) (state: \(state), animated: \(animated))")
        #endif

        if animated {
            withAnimation(.easeInOut(duration: 1.0)) {
                isVisible = newVisibility
            }
        } else {
            isVisible = newVisibility
        }
    }

    // MARK: - Drawing

    /// Main drawing function for the aurora frequency visualization
    private func drawAurora(context: GraphicsContext, size: CGSize, time: Double) {
        // Only show active frequency data when actually playing;
        // buffering/loading/paused all settle to resting state
        let isPlaying = playbackState == .playing

        // Calculate target band values from real-time frequency data
        let targetBands = calculateBandValues(time: time, isPlaying: isPlaying)

        // Smooth the bands with fast attack, slower decay for natural feel
        var newSmoothed = smoothedBands
        var newPeakHolds = peakHolds
        var newPeakTimers = peakDecayTimers
        
        let deltaTime: Double = 1.0 / 30.0 // Approximate frame delta (30fps cap)
        
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

        // Draw 3 soft glow passes for ethereal blur effect (back to front).
        // Reduced from 6 passes — the 3 outermost (blur=60,45,30) were nearly invisible
        // but cost 72 blur filter applications per frame. Opacities bumped to compensate.
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 18, opacity: 0.25)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 12, opacity: 0.30)
        drawSoftGlowLayer(context: context, size: size, bands: newSmoothed, blur: 8, opacity: 0.35)
        
        // Peak highlights (subtle)
        if isPlaying {
            // drawPeakLayer(context: context, size: size, peaks: newPeakHolds)
        }
        
        drawBottomPool(context: context, size: size)
        // drawSaturationGradient(context: context, size: size)
        drawDarkeningGradient(context: context, size: size)
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
                    let normalizedPosition = Double(i) / Double(bandCount - 1)

                    // Slight amplitude boost for low frequencies
                    let bassBoost = 1.0 + (1.0 - normalizedPosition) * 0.4
                    let rawValue = min(1.0, frequencyBands[i] * bassBoost)

                    // Per-band response curve: shapes how contrasty vs sensitive each range is.
                    // Bass (0.0): exponent ~1.3 — contrasty, quiet bass stays low, loud bass pops.
                    // Mids (0.5): exponent ~0.7 — gentle lift, keeps presence.
                    // Highs (1.0): exponent ~0.45 — sensitive, brief transients register visibly.
                    let exponent = bandResponseExponent(normalizedPosition: normalizedPosition)
                    let shaped = pow(max(0.001, rawValue), exponent)

                    // Lower floor for bass so quiet moments don't look "always on"
                    let floor = 0.02 + normalizedPosition * 0.04
                    bands[i] = max(floor, shaped)
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

        // Lateral blend: spread energy from active bands into their neighbors so the
        // aurora reads as one connected curtain rather than isolated clusters.
        // Applied as a partial mix (40% smoothed, 60% original) to preserve dynamic peaks.
        return lateralBlend(bands: bands, sigma: 2.2, mix: 0.4)
    }

    /// Gaussian-weighted lateral blend across frequency bands.
    /// Each band's output is a mix of its original value and a neighbor-weighted average,
    /// which fills in gaps between active regions without flattening peaks.
    private func lateralBlend(bands: [Double], sigma: Double, mix: Double) -> [Double] {
        let count = bands.count
        let kernelRadius = Int(ceil(sigma * 2.5))
        var result = [Double](repeating: 0.0, count: count)

        for i in 0..<count {
            var weightedSum = 0.0
            var totalWeight = 0.0
            let lo = max(0, i - kernelRadius)
            let hi = min(count - 1, i + kernelRadius)

            for j in lo...hi {
                let dist = Double(abs(i - j))
                let weight = exp(-dist * dist / (2 * sigma * sigma))
                weightedSum += bands[j] * weight
                totalWeight += weight
            }

            let smoothed = weightedSum / totalWeight
            result[i] = bands[i] * (1.0 - mix) + smoothed * mix
        }

        return result
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

    /// Returns the gamma exponent used to shape each band's response curve.
    /// Interpolates smoothly across the spectrum:
    ///   Bass  (0.0) → 1.3  high contrast, quiet bass stays low
    ///   Mids  (0.5) → 0.7  gentle lift, keeps presence
    ///   Highs (1.0) → 0.45 sensitive, brief transients register visibly
    private func bandResponseExponent(normalizedPosition: Double) -> Double {
        // Smooth cubic Hermite interpolation through three control points
        if normalizedPosition <= 0.5 {
            let t = normalizedPosition * 2.0
            return 1.3 + (0.7 - 1.3) * (t * t * (3 - 2 * t))
        } else {
            let t = (normalizedPosition - 0.5) * 2.0
            return 0.7 + (0.45 - 0.7) * (t * t * (3 - 2 * t))
        }
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
            
            // Bands are already shaped by bandResponseExponent in calculateBandValues,
            // so use intensity directly here.
            let heightFactor = intensity * bellFactor
            
            let height = minHeight + (maxHeight - minHeight) * CGFloat(heightFactor)

            // Center the band and make it very wide for ethereal overlap
            let centerX = (CGFloat(i) + 0.5) * bandWidth
            let glowWidth = bandWidth * 4.5 // Wider overlap for more ethereal blending
            let x = centerX - glowWidth / 2
            let y = size.height - height - poolHeight

            // Gradient fades transparent at the very bottom so bands "emerge" from the pool
            // rather than anchoring bright cones to the floor (which causes the "uplight" banding look).
            // Peak brightness sits slightly above the base, then fades upward to transparent.
            let intensityAlpha = max(0.3, intensity)
            let bandGradient = Gradient(stops: [
                .init(color: accentColor.opacity(0), location: 0.0),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.7), location: 0.08),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha), location: 0.2),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.6), location: 0.45),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.25), location: 0.7),
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha * 0.08), location: 0.88),
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

    /// Draws a saturation gradient over the aurora: desaturated (~0.5) at the bottom,
    /// fully saturated at the top. Uses the .saturation blend mode with a gray gradient —
    /// gray has zero saturation so it reduces the destination's color intensity by its opacity.
    private func drawSaturationGradient(context: GraphicsContext, size: CGSize) {
        var satContext = context
        satContext.blendMode = .saturation

        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        satContext.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .gray.opacity(0.15), location: 0.35),
                    .init(color: .gray.opacity(0.5), location: 1.0)
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
    }

    /// Draws a darkening gradient: scheme background color at the bottom fading to clear at the top.
    /// Grounds the aurora visually so it feels like it's rising from the surface.
    private func drawDarkeningGradient(context: GraphicsContext, size: CGSize) {
        #if canImport(UIKit)
        let baseColor: Color = colorScheme == .dark ? .black : Color(uiColor: .systemBackground)
        #else
        let baseColor: Color = colorScheme == .dark ? .black : Color(nsColor: .windowBackgroundColor)
        #endif

        var darkContext = context
        darkContext.blendMode = .multiply

        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        darkContext.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: baseColor.opacity(0.15), location: 0.4),
                    .init(color: baseColor.opacity(0.75), location: 1.0)
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
    }

    /// Draws the solid color pool at the very bottom.
    /// Drawn in two passes: a wide blurred halo for soft spread, then a sharper core for brightness.
    private func drawBottomPool(context: GraphicsContext, size: CGSize) {
        let poolOpacity = colorScheme == .dark ? 0.65 : 0.45

        // Wide halo pass — blurred so the pool bleeds softly upward into the bands
        let haloHeight = poolHeight + 50
        let haloRect = CGRect(x: 0, y: size.height - haloHeight, width: size.width, height: haloHeight)
        let haloGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: accentColor.opacity(poolOpacity * 0.2), location: 0.45),
            .init(color: accentColor.opacity(poolOpacity * 0.5), location: 0.75),
            .init(color: accentColor.opacity(poolOpacity * 0.65), location: 1.0)
        ])
        var haloContext = context
        haloContext.blendMode = .plusLighter
        haloContext.addFilter(.blur(radius: 18))
        haloContext.fill(
            Path(haloRect),
            with: .linearGradient(haloGradient,
                startPoint: CGPoint(x: haloRect.midX, y: haloRect.minY),
                endPoint: CGPoint(x: haloRect.midX, y: haloRect.maxY))
        )

        // Sharp core pass — unblurred, gives the pool a solid glowing base
        let poolRect = CGRect(
            x: 0,
            y: size.height - poolHeight - 20,
            width: size.width,
            height: poolHeight + 20
        )

        let poolGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: accentColor.opacity(poolOpacity * 0.3), location: 0.2),
            .init(color: accentColor.opacity(poolOpacity * 0.6), location: 0.55),
            .init(color: accentColor.opacity(poolOpacity * 0.85), location: 1.0)
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
