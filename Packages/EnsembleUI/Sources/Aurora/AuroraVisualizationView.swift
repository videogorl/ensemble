import EnsembleCore
import SwiftUI
import Combine
import Foundation

/// Real-time frequency visualization with soft aurora-style glow.
/// Displays 24 frequency bands (60Hz-16kHz) from live FFT analysis,
/// rising from the bottom with blurred, overlapping wisps.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let consumer: VisualizationConsumer
    private let accentColor: Color

    // MARK: - State

    @State private var playbackState: PlaybackState = .stopped
    @State private var isVisible: Bool = false
    @State private var isMounted = false
    @State private var isSettlingToZero = false
    @State private var settleToZeroTask: Task<Void, Never>?
    @StateObject private var renderModel = AuroraRenderModel()
    @StateObject private var bandProcessor = AuroraBandShapeProcessor()

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of frequency bands (matches AudioAnalyzer)
    private let bandCount = 24

    /// Maximum height of the active aurora bands.
    private let maxHeight: CGFloat = 185

    /// Minimum height of bands (always visible base)
    private let minHeight: CGFloat = 18

    /// Height of the solid "pool" at the bottom
    private let poolHeight: CGFloat = 48

    /// Attack smoothing (how fast bands rise) - increased for smoother transitions
    private let attackFactor: Double = 0.7
    
    /// Decay smoothing (how fast bands fall) - increased for smoother transitions
    private let decayFactor: Double = 0.7

    /// Peak hold time in seconds
    private let peakHoldTime: Double = 0.10
    
    /// Peak decay rate per second
    private let peakDecayRate: Double = 1.5

    // MARK: - Init

    /// Whether the aurora should pause rendering (e.g. Now Playing sheet covers it)
    private let isPaused: Bool

    /// When true, reduces to 1 glow pass at 15fps to conserve battery
    private let isLowPowerMode: Bool

    /// Whether the aurora is allowed to intentionally bleed beyond its host bounds.
    /// Root shells want the wider glow treatment; split detail panes need a clipped surface.
    private let expandsBeyondBounds: Bool
    private let activeContentMaxWidth: CGFloat?

    /// True on A9 (dual-core) and other ≤2-core devices.
    /// Stored once at init time — processorCount never changes at runtime,
    /// and drawAurora() runs at 15-30fps so we don't want ProcessInfo on the hot path.
    private let isLowCoreDevice: Bool

    public init(
        playbackService: PlaybackServiceProtocol,
        consumer: VisualizationConsumer,
        accentColor: Color,
        isPaused: Bool = false,
        isLowPowerMode: Bool = false,
        expandsBeyondBounds: Bool = true,
        activeContentMaxWidth: CGFloat? = nil
    ) {
        self.playbackService = playbackService
        self.consumer = consumer
        self.accentColor = accentColor
        self.isPaused = isPaused
        self.isLowPowerMode = isLowPowerMode
        self.expandsBeyondBounds = expandsBeyondBounds
        self.activeContentMaxWidth = activeContentMaxWidth
        self.isLowCoreDevice = ProcessInfo.processInfo.processorCount <= 2
    }

    // MARK: - Body

    /// Whether the TimelineView should be fully paused (no frames rendered).
    /// Paused when: occluded by NP sheet, not visible, or not actively playing.
    /// When paused, the last rendered frame stays on screen at zero GPU cost.
    private var isTimelinePaused: Bool {
        if isSettlingToZero { return false }
        if isPaused || !isVisible { return true }
        // Only animate when actively playing — the blur passes are expensive
        // even at low frame rates. When paused, the aurora freezes in place.
        return playbackState != .playing
    }

    /// Frame rate: 30fps normal, 15fps in Low Power Mode or on ≤2-core devices (A9/A10).
    private var frameInterval: Double {
        isLowPowerMode || isLowCoreDevice ? 1.0 / 15.0 : 1.0 / 30.0
    }

    private var usesLowCostSurfaceTier: Bool {
        consumer == .phoneOverlay || consumer == .rootBackdrop
    }

    private var shouldRegisterConsumer: Bool {
        isMounted && !isPaused
    }

    private var shouldIngestFrequencyBands: Bool {
        shouldRegisterConsumer && isVisible && playbackState == .playing
    }

    public var body: some View {
        GeometryReader { geometry in
            auroraSurface(for: geometry)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(isVisible ? 0.7 : 0) // Reduced overall opacity for transparency
        .if(expandsBeyondBounds) { view in
            view.ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .onReceive(playbackService.frequencyBandsPublisher) { bands in
            guard shouldIngestFrequencyBands else { return }
            cancelSettleToZero()
            ingestBands(bands)
        }
        .onReceive(playbackService.playbackStatePublisher) { state in
            // Deduplicate: skip repeated state values to avoid redundant visibility checks
            guard state != playbackState else { return }
            playbackState = state
            if state == .paused {
                startSettleToZero()
            } else if state == .playing || state == .buffering || state == .loading {
                cancelSettleToZero()
            }
            // Animate visibility only when the playback state actively changes.
            // This produces the desired fade-in when the user first presses play.
            updateVisibility(for: state, animated: true)
        }
        .onAppear {
            isMounted = true
            let currentState = playbackService.playbackState
            playbackState = currentState
            updateConsumerRegistration()
            if currentState == .playing {
                ingestBands(playbackService.frequencyBands)
            }
            // Snap directly without animation: onAppear fires on tab switches too,
            // and we don't want the aurora to fade in every time the user changes tabs.
            // The animated fade is reserved for actual play/stop transitions via onReceive.
            updateVisibility(for: currentState, animated: false)
        }
        .onDisappear {
            isMounted = false
            settleToZeroTask?.cancel()
            settleToZeroTask = nil
            bandProcessor.cancelPending()
            updateConsumerRegistration()
        }
        .onChange(of: isPaused) { _ in
            updateConsumerRegistration()
        }
    }

    @ViewBuilder
    private func auroraSurface(for geometry: GeometryProxy) -> some View {
        let surfaceWidth = expandsBeyondBounds ? geometry.size.width + 80 : geometry.size.width
        let surfaceHeight = maxHeight + 40
        let xOffset = expandsBeyondBounds ? -40.0 : 0.0

        if isMetalAuroraAvailable {
            ZStack {
                MetalAuroraSurface(
                    renderModel: renderModel,
                    accentColor: accentColor,
                    colorScheme: colorScheme,
                    preferredFrameInterval: frameInterval,
                    isPaused: isTimelinePaused,
                    surfaceTier: auroraSurfaceTier,
                    activeContentMaxWidth: activeContentMaxWidth,
                    bandCount: bandCount,
                    maxHeight: maxHeight,
                    minHeight: minHeight,
                    poolHeight: poolHeight
                )
                horizonGlowOverlay
                foregroundFadeOverlay
            }
            .frame(width: surfaceWidth, height: surfaceHeight)
            .offset(x: xOffset, y: 15)
        } else {
            canvasAuroraSurface(width: surfaceWidth, height: surfaceHeight, xOffset: xOffset)
        }
    }

    private var isMetalAuroraAvailable: Bool {
        #if canImport(MetalKit) && !os(watchOS)
        return MetalAuroraSurface.isAvailable
        #else
        return false
        #endif
    }

    private var auroraSurfaceTier: AuroraMetalSurfaceTier {
        if isLowPowerMode {
            return .lowPower
        }
        if usesLowCostSurfaceTier || isLowCoreDevice {
            return .ambient
        }
        return .immersive
    }

    private var foregroundFadeOverlay: some View {
        #if canImport(UIKit)
        let baseColor: Color = colorScheme == .dark ? .black : Color(uiColor: .systemBackground)
        #else
        let baseColor: Color = colorScheme == .dark ? .black : Color(nsColor: .windowBackgroundColor)
        #endif

        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.28),
                .init(color: baseColor.opacity(0.10), location: 0.54),
                .init(color: baseColor.opacity(0.34), location: 0.75),
                .init(color: baseColor.opacity(0.56), location: 0.91),
                .init(color: baseColor.opacity(0.68), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var horizonGlowOverlay: some View {
        let bottomOpacity = colorScheme == .dark ? 0.64 : 0.96

        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.46),
                .init(color: accentColor.opacity(bottomOpacity * 0.10), location: 0.62),
                .init(color: accentColor.opacity(bottomOpacity * 0.36), location: 0.76),
                .init(color: accentColor.opacity(bottomOpacity * 0.78), location: 0.90),
                .init(color: accentColor.opacity(bottomOpacity), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 24)
    }

    private func canvasAuroraSurface(width: CGFloat, height: CGFloat, xOffset: CGFloat) -> some View {
        // Fully paused when not actively playing (see isTimelinePaused).
        // The Canvas fallback mirrors the Metal surface for unsupported devices.
        TimelineView(.animation(minimumInterval: frameInterval, paused: isTimelinePaused)) { _ in
            Canvas { context, size in
                drawAurora(context: context, size: size)
            }
            .frame(width: width)
            .frame(height: height)
            .offset(x: xOffset, y: 15)
        }
    }

    // MARK: - Visibility

    /// Updates visibility based on playback state.
    /// Aurora stays visible when paused (frozen last frame) but hides when stopped.
    /// Pass animated: false (e.g. on onAppear) to snap without the fade transition.
    private func updateVisibility(for state: PlaybackState, animated: Bool) {
        let newVisibility: Bool
        switch state {
        case .playing, .buffering, .loading, .paused:
            newVisibility = true
        case .stopped, .failed:
            newVisibility = false
            // Reset band state so stale values don't flash when playback resumes
            bandProcessor.cancelPending()
            renderModel.reset()
        }

        guard newVisibility != isVisible else { return }

        EnsembleLogger.debug("Aurora visibility: \(newVisibility) (state: \(state), animated: \(animated), timelinePaused: \(state != .playing))")

        if animated {
            withAnimation(.easeInOut(duration: 1.0)) {
                isVisible = newVisibility
            }
        } else {
            isVisible = newVisibility
        }
    }

    private func updateConsumerRegistration() {
        playbackService.setVisualizationConsumer(consumer, isVisible: shouldRegisterConsumer)
    }

    /// Advances the smoothed aurora state from analyzer samples without publishing
    /// SwiftUI updates on every FFT tick.
    private func ingestBands(_ rawBands: [Double]) {
        let renderModel = renderModel
        let attackFactor = attackFactor
        let decayFactor = decayFactor
        let peakHoldTime = peakHoldTime
        let peakDecayRate = peakDecayRate
        let deltaTime = frameInterval

        bandProcessor.submit(rawBands) { targetBands in
            renderModel.advance(
                targetBands: targetBands,
                attackFactor: attackFactor,
                decayFactor: decayFactor,
                peakHoldTime: peakHoldTime,
                peakDecayRate: peakDecayRate,
                deltaTime: deltaTime
            )
        }
    }

    private func startSettleToZero() {
        settleToZeroTask?.cancel()
        isSettlingToZero = true

        settleToZeroTask = Task { @MainActor in
            let zeroBands = [Double](repeating: 0, count: bandCount)
            for _ in 0..<36 {
                guard !Task.isCancelled else { return }
                renderModel.advance(
                    targetBands: zeroBands,
                    attackFactor: attackFactor,
                    decayFactor: 0.88,
                    peakHoldTime: 0,
                    peakDecayRate: peakDecayRate * 1.6,
                    deltaTime: frameInterval
                )
                if renderModel.isNearZero { break }
                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            isSettlingToZero = false
            settleToZeroTask = nil
        }
    }

    private func cancelSettleToZero() {
        settleToZeroTask?.cancel()
        settleToZeroTask = nil
        if isSettlingToZero {
            isSettlingToZero = false
        }
    }

    // MARK: - Drawing

    /// Main drawing function for the aurora frequency visualization
    private func drawAurora(context: GraphicsContext, size: CGSize) {
        // Non-playing states freeze the last rendered frame because TimelineView pauses.
        let bandsToRender = renderModel.renderedBands
        let energy = auroraEnergy(from: bandsToRender)

        if isLowPowerMode {
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 10, opacity: 0.50)
        } else if usesLowCostSurfaceTier || isLowCoreDevice {
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 18, opacity: 0.28)
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 8,  opacity: 0.42)
        } else {
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 18, opacity: 0.25)
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 12, opacity: 0.30)
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, blur: 8,  opacity: 0.35)
        }

        drawBandPoolBridge(context: context, size: size, energy: energy)
        drawBottomPool(context: context, size: size, energy: energy)
        drawHorizonGlow(context: context, size: size)
        drawForegroundFade(context: context, size: size)
    }

    private func auroraEnergy(from bands: [Double]) -> Double {
        guard !bands.isEmpty else { return 0 }
        let averageEnergy = bands.reduce(0, +) / Double(bands.count)
        let bassCount = min(6, bands.count)
        let bassEnergy = bands.prefix(bassCount).reduce(0, +) / Double(bassCount)
        return min(1, max(0, averageEnergy * 0.70 + bassEnergy * 0.30))
    }

    /// Draws a soft glow layer with wide, overlapping bands
    private func drawSoftGlowLayer(
        context: GraphicsContext,
        size: CGSize,
        bands: [Double],
        blur: CGFloat,
        opacity: Double
    ) {
        let activeWidth = activeContentMaxWidth.map { min(size.width, $0) } ?? size.width
        let xOffset = (size.width - activeWidth) / 2
        let bandWidth = activeWidth / CGFloat(bandCount)
        let baseOpacity = (colorScheme == .dark ? 0.7 : 0.5) * opacity

        // Blur once for the whole glow layer. Applying a Gaussian filter per band
        // creates dozens of offscreen RenderBox surfaces per frame, which can
        // starve CoreAudio under sustained playback.
        var layerContext = context
        layerContext.blendMode = .plusLighter
        layerContext.addFilter(.blur(radius: blur))

        for i in 0..<bandCount {
            let intensity = bands[i]
            
            // Normalized position (0.0 to 1.0) for bell curve calculation
            let normalizedPos = Double(i) / Double(bandCount - 1)
            
            // Bell curve factor keeps the aurora tallest and brightest in the middle.
            let bellFactor = exp(-pow(normalizedPos - 0.5, 2) / (2 * pow(0.34, 2)))
            
            // Bands are already shaped by bandResponseExponent in calculateBandValues,
            // so use intensity directly here.
            let heightFactor = intensity * bellFactor
            
            let height = minHeight + (maxHeight - minHeight) * CGFloat(heightFactor)

            // Center the band and make it very wide for ethereal overlap
            let centerX = xOffset + (CGFloat(i) + 0.5) * bandWidth
            let glowWidth = bandWidth * 4.5 // Wider overlap for more ethereal blending
            let x = centerX - glowWidth / 2
            let y = size.height - height - poolHeight

            // Gradient fades transparent at the very bottom so bands "emerge" from the pool
            // rather than anchoring bright cones to the floor (which causes the "uplight" banding look).
            // Peak brightness sits slightly above the base, then fades upward to transparent.
            let bellAlpha = 0.32 + bellFactor * 0.68
            let intensityAlpha = (0.18 + intensity * 0.82) * bellAlpha
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

            layerContext.fill(
                Path(ellipseIn: glowRect),
                with: .linearGradient(
                    bandGradient,
                    startPoint: CGPoint(x: glowRect.midX, y: glowRect.maxY),
                    endPoint: CGPoint(x: glowRect.midX, y: glowRect.minY)
                )
            )
        }
    }
    
    /// Adds a soft accent haze where active bands dissolve into the bottom pool.
    private func drawBandPoolBridge(context: GraphicsContext, size: CGSize, energy: Double) {
        let activeWidth = activeContentMaxWidth.map { min(size.width, $0) } ?? size.width
        let xOffset = (size.width - activeWidth) / 2
        let bridgeOpacity = (colorScheme == .dark ? 0.34 : 0.24) * (0.45 + energy * 0.7)
        let bridgeHeight = poolHeight + 76
        let bridgeRect = CGRect(
            x: xOffset - activeWidth * 0.08,
            y: size.height - bridgeHeight - 18,
            width: activeWidth * 1.16,
            height: bridgeHeight
        )
        let bridgeGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: accentColor.opacity(bridgeOpacity * 0.22), location: 0.28),
            .init(color: accentColor.opacity(bridgeOpacity * 0.6), location: 0.58),
            .init(color: accentColor.opacity(bridgeOpacity), location: 1.0)
        ])

        var bridgeContext = context
        bridgeContext.blendMode = .plusLighter
        bridgeContext.addFilter(.blur(radius: 24))
        bridgeContext.fill(
            Path(ellipseIn: bridgeRect),
            with: .linearGradient(
                bridgeGradient,
                startPoint: CGPoint(x: bridgeRect.midX, y: bridgeRect.minY),
                endPoint: CGPoint(x: bridgeRect.midX, y: bridgeRect.maxY)
            )
        )
    }

    /// Draws the solid color pool at the very bottom.
    /// Drawn in two passes: a wide blurred halo for soft spread, then a sharper core for brightness.
    private func drawBottomPool(context: GraphicsContext, size: CGSize, energy: Double) {
        let baselineOpacity = colorScheme == .dark ? 0.58 : 0.38
        let poolOpacity = baselineOpacity * (0.84 + energy * 0.34)

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

    /// Draws the final foreground fade inside the same Canvas as the bands and pool.
    /// This uses normal compositing so light-mode surfaces actually cover the glow
    /// instead of multiplying white over it, which is visually almost a no-op.
    private func drawForegroundFade(context: GraphicsContext, size: CGSize) {
        #if canImport(UIKit)
        let baseColor: Color = colorScheme == .dark ? .black : Color(uiColor: .systemBackground)
        #else
        let baseColor: Color = colorScheme == .dark ? .black : Color(nsColor: .windowBackgroundColor)
        #endif

        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let fadeGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.28),
            .init(color: baseColor.opacity(0.10), location: 0.54),
            .init(color: baseColor.opacity(0.34), location: 0.75),
            .init(color: baseColor.opacity(0.56), location: 0.91),
            .init(color: baseColor.opacity(0.68), location: 1.0)
        ])

        context.fill(
            Path(rect),
            with: .linearGradient(
                fadeGradient,
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
    }

    /// Adds a soft color wash below the foreground fade so the aurora reads as
    /// emerging from a tinted horizon instead of a separate bottom layer.
    private func drawHorizonGlow(context: GraphicsContext, size: CGSize) {
        let bottomOpacity = colorScheme == .dark ? 0.64 : 0.96
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let glowGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.46),
            .init(color: accentColor.opacity(bottomOpacity * 0.10), location: 0.62),
            .init(color: accentColor.opacity(bottomOpacity * 0.36), location: 0.76),
            .init(color: accentColor.opacity(bottomOpacity * 0.78), location: 0.90),
            .init(color: accentColor.opacity(bottomOpacity), location: 1.0)
        ])

        var glowContext = context
        glowContext.addFilter(.blur(radius: 24))
        glowContext.fill(
            Path(rect),
            with: .linearGradient(
                glowGradient,
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
    }
}

/// Coalesces raw FFT updates and shapes aurora bands off the SwiftUI receive path.
@MainActor
final class AuroraBandShapeProcessor: ObservableObject {
    private let bandCount = 24
    private let processingQueue = DispatchQueue(
        label: "com.felicity.Ensemble.aurora-band-shaper",
        qos: .userInitiated
    )

    private var pendingBands: [Double]?
    private var latestRequestID = 0
    private var isProcessing = false
    private var latestCompletion: (@MainActor ([Double]) -> Void)?

    func submit(_ rawBands: [Double], completion: @escaping @MainActor ([Double]) -> Void) {
        pendingBands = rawBands
        latestCompletion = completion
        latestRequestID += 1

        guard !isProcessing else { return }
        processNext()
    }

    func cancelPending() {
        pendingBands = nil
        latestCompletion = nil
        latestRequestID += 1
    }

    private func processNext() {
        guard let bands = pendingBands else {
            isProcessing = false
            return
        }

        pendingBands = nil
        isProcessing = true

        let requestID = latestRequestID
        let bandCount = bandCount

        processingQueue.async {
            let shapedBands = Self.calculateBandValues(from: bands, bandCount: bandCount)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isProcessing = false

                if requestID == self.latestRequestID, let latestCompletion = self.latestCompletion {
                    latestCompletion(shapedBands)
                }

                if self.pendingBands != nil {
                    self.processNext()
                }
            }
        }
    }

    /// Maps analyzer output into the aurora's rendered band response curve.
    private nonisolated static func calculateBandValues(from inputBands: [Double], bandCount: Int) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)

        if !inputBands.isEmpty {
            for i in 0..<min(bandCount, inputBands.count) {
                let normalizedPosition = Double(i) / Double(bandCount - 1)
                let rawValue = compensatedBandValue(
                    inputBands[i],
                    normalizedPosition: normalizedPosition
                )
                let exponent = bandResponseExponent(normalizedPosition: normalizedPosition)
                let shaped = pow(max(0.001, rawValue), exponent)
                let floor = 0.02 + normalizedPosition * 0.04
                bands[i] = max(floor, shaped)
            }
        } else {
            for i in 0..<bandCount {
                bands[i] = 0.1
            }
        }

        let responsiveBands = enhanceBandResponsiveness(bands)
        let blendedBands = lateralBlend(bands: responsiveBands, sigma: 2.8, mix: 0.42)
        return flowingBandEnvelope(bands: blendedBands, sigma: 2.0, influence: 0.46)
    }

    /// Applies a gentle spectral tilt: lows get headroom, highs get logarithmic lift.
    private nonisolated static func compensatedBandValue(_ value: Double, normalizedPosition: Double) -> Double {
        let clamped = min(1, max(0, value))
        let highPresence = pow(normalizedPosition, 0.72)
        let spectralTilt = 0.72 + highPresence * 0.68
        let weighted = min(0.98, clamped * spectralTilt)

        let bassCompression = (1 - normalizedPosition) * 2.2
        let bassHeadroom = weighted / (1 + max(0, weighted - 0.58) * bassCompression)

        let logGain = 5.0 + normalizedPosition * 7.0
        let logarithmic = log1p(bassHeadroom * logGain) / log1p(logGain)
        let logMix = smoothStep(edge0: 0.28, edge1: 1.0, value: normalizedPosition) * 0.56
        return bassHeadroom * (1 - logMix) + logarithmic * logMix
    }

    /// Preserves contrast when the whole spectrum is loud so strong songs still feel animated.
    private nonisolated static func enhanceBandResponsiveness(_ bands: [Double]) -> [Double] {
        guard !bands.isEmpty else { return bands }

        let mean = bands.reduce(0, +) / Double(bands.count)
        let peak = bands.max() ?? 0
        guard peak > 0 else { return bands }

        let density = mean / peak
        let loudFactor = smoothStep(edge0: 0.34, edge1: 0.78, value: mean)
        let fullSpectrumFactor = smoothStep(edge0: 0.58, edge1: 0.92, value: density)
        let globalContrastBoost = 0.16 + loudFactor * 0.30 + fullSpectrumFactor * 0.18
        let localContrastBoost = 0.22 + fullSpectrumFactor * 0.38
        let highBandCompression = 0.04 + fullSpectrumFactor * 0.08

        return bands.enumerated().map { index, value in
            let localAverage = localAverage(in: bands, around: index, radius: 2)
            let globalContrast = value - mean
            let localContrast = value - localAverage
            let contrasted = value
                + globalContrast * globalContrastBoost
                + localContrast * localContrastBoost

            // Keep a little headroom in dense/loud sections so every band does not pin at max.
            let compressed = contrasted / (1 + max(0, contrasted - 0.68) * highBandCompression)
            return min(0.98, max(0.015, compressed))
        }
    }

    private nonisolated static func localAverage(in bands: [Double], around index: Int, radius: Int) -> Double {
        let lowerBound = max(0, index - radius)
        let upperBound = min(bands.count - 1, index + radius)
        let values = bands[lowerBound...upperBound]
        return values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func smoothStep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let x = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }

    /// Gaussian-weighted lateral blend across frequency bands.
    private nonisolated static func lateralBlend(bands: [Double], sigma: Double, mix: Double) -> [Double] {
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

    /// Lets neighboring frequency peaks softly lift valleys so the aurora flows as one sheet.
    private nonisolated static func flowingBandEnvelope(bands: [Double], sigma: Double, influence: Double) -> [Double] {
        guard !bands.isEmpty else { return bands }

        let count = bands.count
        let kernelRadius = Int(ceil(sigma * 2.5))
        var result = [Double](repeating: 0.0, count: count)

        for i in 0..<count {
            var envelope = bands[i]
            let lo = max(0, i - kernelRadius)
            let hi = min(count - 1, i + kernelRadius)

            for j in lo...hi {
                let dist = Double(abs(i - j))
                let weight = exp(-dist * dist / (2 * sigma * sigma))
                envelope = max(envelope, bands[j] * weight)
            }

            let neighborLift = max(bands[i], envelope * 0.78)
            result[i] = min(0.98, bands[i] * (1 - influence) + neighborLift * influence)
        }

        return result
    }

    /// Returns the gamma exponent used to shape each band's response curve.
    private nonisolated static func bandResponseExponent(normalizedPosition: Double) -> Double {
        if normalizedPosition <= 0.5 {
            let t = normalizedPosition * 2.0
            return 1.45 + (0.7 - 1.45) * (t * t * (3 - 2 * t))
        } else {
            let t = (normalizedPosition - 0.5) * 2.0
            return 0.7 + (0.58 - 0.7) * (t * t * (3 - 2 * t))
        }
    }
}

/// Keeps live aurora band state off the SwiftUI observation path so analyzer ticks
/// do not invalidate root-level view trees on every update.
final class AuroraRenderModel: ObservableObject {
    private let bandCount = 24
    private var smoothedBands = Array(repeating: 0.0, count: 24)
    private var peakHolds = Array(repeating: 0.0, count: 24)
    private var peakDecayTimers = Array(repeating: 0.0, count: 24)

    var renderedBands: [Double] {
        smoothedBands
    }

    var isNearZero: Bool {
        smoothedBands.allSatisfy { $0 < 0.01 }
    }

    func reset() {
        smoothedBands = Array(repeating: 0.0, count: bandCount)
        peakHolds = Array(repeating: 0.0, count: bandCount)
        peakDecayTimers = Array(repeating: 0.0, count: bandCount)
    }

    func advance(
        targetBands: [Double],
        attackFactor: Double,
        decayFactor: Double,
        peakHoldTime: Double,
        peakDecayRate: Double,
        deltaTime: Double
    ) {
        for index in 0..<bandCount {
            let target = targetBands[index]
            let current = smoothedBands[index]

            if target > current {
                smoothedBands[index] = current + (target - current) * (1.0 - attackFactor)
            } else {
                smoothedBands[index] = current + (target - current) * (1.0 - decayFactor)
            }

            if smoothedBands[index] > peakHolds[index] {
                peakHolds[index] = smoothedBands[index]
                peakDecayTimers[index] = peakHoldTime
            } else if peakDecayTimers[index] > 0 {
                peakDecayTimers[index] -= deltaTime
            } else {
                peakHolds[index] = max(
                    smoothedBands[index],
                    peakHolds[index] - peakDecayRate * deltaTime
                )
            }
        }
    }
}
