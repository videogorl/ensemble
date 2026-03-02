import EnsembleCore
import SwiftUI
import Combine

/// Aurora-style background visualization that reacts to music loudness.
/// Displays fan-shaped sectors emanating from the bottom of the screen that pulse
/// and grow based on the current playback position's loudness values.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let accentColor: Color

    // MARK: - State

    @State private var waveformHeights: [Double] = []
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var playbackState: PlaybackState = .stopped
    @State private var isVisible: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of fan sectors to draw
    private let sectorCount = 7

    /// Angular spread of the aurora in degrees (centered at bottom)
    private let angularSpread: Double = 108

    /// Base height of the aurora when at minimum intensity
    private let baseHeight: CGFloat = 180

    /// Maximum height of the aurora at full intensity
    private let maxHeight: CGFloat = 320

    /// Idle amplitude when no waveform data is available
    private let idleAmplitude: Double = 0.15

    /// Target frame rate for animation
    private let frameInterval: Double = 1.0 / 30.0

    // MARK: - Init

    public init(playbackService: PlaybackServiceProtocol, accentColor: Color) {
        self.playbackService = playbackService
        self.accentColor = accentColor
    }

    // MARK: - Body

    public var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !shouldAnimate)) { timeline in
            Canvas { context, size in
                drawAurora(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
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
            // Initialize with current state
            waveformHeights = playbackService.waveformHeights
            currentTime = playbackService.currentTime
            duration = playbackService.duration
            playbackState = playbackService.playbackState
            updateVisibility(for: playbackState)
        }
        .onChange(of: playbackService.duration) { newDuration in
            duration = newDuration
        }
    }

    // MARK: - Animation Control

    /// Whether the animation should be running
    private var shouldAnimate: Bool {
        switch playbackState {
        case .playing, .buffering, .loading:
            return true
        default:
            return false
        }
    }

    /// Updates visibility based on playback state
    private func updateVisibility(for state: PlaybackState) {
        switch state {
        case .playing, .buffering, .loading:
            isVisible = true
        case .paused, .stopped, .failed:
            isVisible = false
        }
    }

    // MARK: - Drawing

    /// Main drawing function for the aurora effect
    private func drawAurora(context: GraphicsContext, size: CGSize, time: Double) {
        // Origin point is below the visible screen (centered at bottom)
        let originX = size.width / 2
        let originY = size.height + 40

        // Calculate current loudness from waveform data
        let loudness = sampleLoudness()

        // Base opacity varies by color scheme
        let baseOpacity = colorScheme == .dark ? 0.4 : 0.25

        // Draw each sector
        for i in 0..<sectorCount {
            drawSector(
                context: context,
                sectorIndex: i,
                originX: originX,
                originY: originY,
                baseLoudness: loudness,
                time: time,
                baseOpacity: baseOpacity
            )
        }
    }

    /// Draws a single fan sector with radial gradient
    private func drawSector(
        context: GraphicsContext,
        sectorIndex: Int,
        originX: CGFloat,
        originY: CGFloat,
        baseLoudness: Double,
        time: Double,
        baseOpacity: Double
    ) {
        // Calculate angle for this sector (spread across angularSpread degrees centered at -90 degrees)
        let sectorFraction = Double(sectorIndex) / Double(sectorCount - 1)
        let startAngle = -90.0 - (angularSpread / 2)
        let angle = startAngle + (sectorFraction * angularSpread)
        let angleRadians = angle * .pi / 180

        // Add time-based wobble for organic motion (each sector wobbles slightly differently)
        let wobblePhase = Double(sectorIndex) * 0.7
        let wobble = sin(time * 2.0 + wobblePhase) * 0.08

        // Calculate intensity for this sector with staggered sampling
        let sectorOffset = Double(sectorIndex) * 0.02
        let intensity = min(1.0, max(0.1, baseLoudness + wobble + sectorOffset))

        // Calculate radius based on intensity
        let radius = baseHeight + CGFloat(intensity) * (maxHeight - baseHeight)

        // Create fan/wedge path
        let halfWedgeAngle: Double = (angularSpread / Double(sectorCount)) * 0.8 * (.pi / 180)

        var path = Path()
        path.move(to: CGPoint(x: originX, y: originY))

        // Arc from one edge of the wedge to the other
        let startWedgeAngle = angleRadians - halfWedgeAngle
        let endWedgeAngle = angleRadians + halfWedgeAngle

        path.addArc(
            center: CGPoint(x: originX, y: originY),
            radius: radius,
            startAngle: .radians(startWedgeAngle),
            endAngle: .radians(endWedgeAngle),
            clockwise: false
        )
        path.closeSubpath()

        // Create radial gradient from origin outward
        let gradient = Gradient(colors: [
            accentColor.opacity(baseOpacity * intensity),
            accentColor.opacity(baseOpacity * intensity * 0.6),
            accentColor.opacity(0)
        ])

        let radialGradient = GraphicsContext.Shading.radialGradient(
            gradient,
            center: CGPoint(x: originX, y: originY),
            startRadius: 0,
            endRadius: radius
        )

        // Draw with additive blend mode for glowing effect
        var sectorContext = context
        sectorContext.blendMode = .plusLighter
        sectorContext.fill(path, with: radialGradient)
    }

    // MARK: - Loudness Sampling

    /// Samples the current loudness from waveform data based on playback position
    private func sampleLoudness() -> Double {
        guard !waveformHeights.isEmpty, duration > 0 else {
            return idleAmplitude
        }

        // Calculate position in waveform array
        let progress = min(1.0, max(0.0, currentTime / duration))
        let floatIndex = progress * Double(waveformHeights.count - 1)

        // Linear interpolation between adjacent samples
        let lowerIndex = Int(floatIndex)
        let upperIndex = min(lowerIndex + 1, waveformHeights.count - 1)
        let fraction = floatIndex - Double(lowerIndex)

        let lowerValue = waveformHeights[lowerIndex]
        let upperValue = waveformHeights[upperIndex]

        let interpolated = lowerValue + (upperValue - lowerValue) * fraction

        // Ensure minimum amplitude for visual presence
        return max(idleAmplitude, interpolated)
    }
}
