import EnsembleCore
import SwiftUI
import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Real-time frequency visualization with soft aurora-style glow.
/// Mirrors live FFT bands with bass at the center and higher frequencies outward,
/// rising from the bottom with blurred, overlapping wisps.
@available(iOS 15.0, macOS 12.0, *)
public struct AuroraVisualizationView: View {
    // MARK: - Dependencies

    private let playbackService: PlaybackServiceProtocol
    private let consumer: VisualizationConsumer
    private let accentColor: Color

    // MARK: - State

    @State private var playbackState: PlaybackState
    @State private var isVisible: Bool = true
    @State private var isMounted = false
    @State private var isSettlingToZero = false
    @State private var settleToZeroTask: Task<Void, Never>?
    @StateObject private var renderModel = AuroraRenderModel()
    @StateObject private var bandProcessor = AuroraBandShapeProcessor()

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Configuration

    /// Number of frequency bands (matches AudioAnalyzer)
    private let bandCount = 24
    private var displaySampleCount: Int { isLowPowerMode || isLowCoreDevice ? 24 : 48 }

    /// Maximum height of the active aurora bands.
    private var maxHeight: CGFloat { isPhone ? 184 : 92 }

    /// Minimum height of bands (always visible base)
    private let minHeight: CGFloat = 6

    /// Extra height at the base of each reactive band
    private var poolHeight: CGFloat { isPhone ? 18 : 10 }

    private let isPhone: Bool
    private var bellWidth: CGFloat { isPhone ? 0.60 : 0.24 }

    // MARK: - Init

    /// Whether the aurora should pause rendering (e.g. Now Playing sheet covers it)
    private let isPaused: Bool

    /// When true, reduces to 1 glow pass at 15fps to conserve battery.
    private let isLowPowerMode: Bool

    /// Whether the aurora is allowed to intentionally bleed beyond its host bounds.
    /// Root shells include the bottom safe area; split detail panes stay within their host.
    private let expandsBeyondBounds: Bool
    private let activeContentMaxWidth: CGFloat?

    /// True on A9 (dual-core) and other ≤2-core devices.
    /// Stored once at init time — processorCount never changes at runtime,
    /// and drawAurora() runs on the hot path so we don't want ProcessInfo there.
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
        #if os(iOS)
        self.isPhone = UIDevice.current.userInterfaceIdiom == .phone
        #else
        self.isPhone = false
        #endif
        self.playbackService = playbackService
        self.consumer = consumer
        self.accentColor = accentColor
        self.isPaused = isPaused
        self.isLowPowerMode = isLowPowerMode
        self.expandsBeyondBounds = expandsBeyondBounds
        self.activeContentMaxWidth = activeContentMaxWidth
        self.isLowCoreDevice = ProcessInfo.processInfo.processorCount <= 2
        self._playbackState = State(initialValue: playbackService.playbackState)
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

    /// Frame rate: 30fps normal, 15fps in Low Power Mode.
    private var frameInterval: Double {
        isLowPowerMode ? 1.0 / 15.0 : 1.0 / 30.0
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
        .opacity(isVisible ? 0.45 : 0)
        // Add light on dark surfaces; additive blending disappears against white.
        .blendMode(colorScheme == .dark ? .plusLighter : .normal)
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
        let surfaceWidth = isPhone ? geometry.size.width : min(geometry.size.width, activeContentMaxWidth ?? 900)
        let surfaceHeight = maxHeight + 40
        let xOffset = (geometry.size.width - surfaceWidth) / 2

        if isMetalAuroraAvailable {
            MetalAuroraSurface(
                renderModel: renderModel,
                accentColor: accentColor,
                colorScheme: colorScheme,
                preferredFrameInterval: frameInterval,
                isPaused: isTimelinePaused,
                surfaceTier: auroraSurfaceTier,
                activeContentMaxWidth: isPhone ? nil : activeContentMaxWidth,
                bellWidth: bellWidth,
                bandCount: displaySampleCount,
                maxHeight: maxHeight,
                minHeight: minHeight,
                poolHeight: poolHeight
            )
            .frame(width: surfaceWidth, height: surfaceHeight)
            .mask(horizontalFade)
            .offset(x: xOffset)
        } else {
            canvasAuroraSurface(width: surfaceWidth, height: surfaceHeight, xOffset: xOffset)
        }
    }

    private var isMetalAuroraAvailable: Bool {
        #if canImport(MetalKit)
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

    /// Phones fill the display; larger surfaces taper to transparent edges.
    @ViewBuilder
    private var horizontalFade: some View {
        if isPhone {
            Color.black
        } else {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.18), location: 0.12),
                    .init(color: .black.opacity(0.68), location: 0.30),
                    .init(color: .black, location: 0.50),
                    .init(color: .black.opacity(0.68), location: 0.70),
                    .init(color: .black.opacity(0.18), location: 0.88),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
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
            .mask(horizontalFade)
            .offset(x: xOffset)
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
            newVisibility = true
            // Reset band state so stale values don't flash while the idle surface remains mounted.
            bandProcessor.cancelPending()
            renderModel.resetToIdle()
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
        bandProcessor.submit(rawBands) { targetBands in
            renderModel.advance(targetBands: targetBands)
        }
    }

    private func startSettleToZero() {
        settleToZeroTask?.cancel()
        isSettlingToZero = true

        settleToZeroTask = Task { @MainActor in
            let zeroBands = [Double](repeating: 0, count: bandCount)
            for _ in 0..<36 {
                guard !Task.isCancelled else { return }
                renderModel.advance(targetBands: zeroBands)
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
        let bandsToRender = renderModel.displayBands(width: size.width, count: displaySampleCount)

        let time = renderModel.animationTime
        if !isLowPowerMode {
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, layer: 0, time: time)
            drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, layer: 1, time: time)
        }
        drawSoftGlowLayer(context: context, size: size, bands: bandsToRender, layer: 2, time: time)
    }

    /// Draws a soft glow layer with wide, overlapping bands
    private func drawSoftGlowLayer(
        context: GraphicsContext,
        size: CGSize,
        bands: [Double],
        layer: Int,
        time: TimeInterval
    ) {
        let activeWidth = isPhone ? size.width : (activeContentMaxWidth.map { min(size.width, $0) } ?? size.width)
        let xOffset = (size.width - activeWidth) / 2
        let bandWidth = activeWidth / CGFloat(bands.count)
        let opacity = [0.20, 0.40, 0.50][layer]
        let blur: CGFloat = [14, 6, 2][layer]
        let spread: CGFloat = [2.0, 1.15, 0.65][layer]
        let heightScale: CGFloat = [0.85, 1.10, 1.30][layer]
        // Each curtain breathes independently of the audio, which still supplies its energy.
        let layerPhase = time * (0.19 + 0.07 * Double(layer)) + Double(layer) * 2.1
        let widthScale = 0.92 + 0.08 * sin(layerPhase)
        let layerBreath = 0.86 + 0.14 * sin(layerPhase * 1.3 + 1.7)
        let layerDrift = CGFloat(0.025 * sin(layerPhase * 0.7 + 0.8)) * activeWidth
        let baseOpacity = (colorScheme == .dark ? 0.7 : 0.5) * opacity * (0.82 + 0.18 * sin(layerPhase + 2.4))

        // Blur once for the whole glow layer. Applying a Gaussian filter per band
        // creates dozens of offscreen RenderBox surfaces per frame, which can
        // starve CoreAudio under sustained playback.
        var layerContext = context
        layerContext.blendMode = .plusLighter
        layerContext.addFilter(.blur(radius: blur))

        for i in bands.indices {
            let intensity = bands[i]
            
            // Normalized position (0.0 to 1.0) for bell curve calculation
            let normalizedPos = Double(i) / Double(bands.count - 1)
            
            // Bell curve factor keeps the aurora tallest and brightest in the middle.
            let bellFactor = exp(-pow(normalizedPos - 0.5, 2) / (2 * pow(Double(bellWidth), 2)))
            
            // Bands are already shaped by bandResponseExponent in calculateBandValues,
            // so use intensity directly here.
            let heightFactor = intensity * bellFactor
            
            let phase = time * (0.25 + 0.15 * Double(layer)) + normalizedPos * 6.1 + Double(layer) * 2.1
            let breath = 0.9 + 0.1 * sin(phase + 1.3)
            let height = (minHeight + (maxHeight - minHeight) * CGFloat(heightFactor)) * heightScale * CGFloat(breath * layerBreath)

            // Center the band and make it very wide for ethereal overlap
            let drift = CGFloat(sin(phase) * (0.25 + 0.12 * Double(layer))) * bandWidth
            let centeredX = (CGFloat(i) + 0.5) * bandWidth - activeWidth / 2
            let centerX = xOffset + activeWidth / 2 + centeredX * CGFloat(widthScale) + layerDrift + drift
            let glowWidth = bandWidth * 3.0 * spread * CGFloat(widthScale)
            let x = centerX - glowWidth / 2
            let y = size.height - height - poolHeight

            // Anchor each curtain below the surface so it only fades upward.
            let bellAlpha = bellFactor
            let intensityAlpha = intensity * bellAlpha
            let bandGradient = Gradient(stops: [
                .init(color: accentColor.opacity(baseOpacity * intensityAlpha), location: 0.0),
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
                height: (height + poolHeight) * 2
            )

            layerContext.fill(
                Path(ellipseIn: glowRect),
                with: .linearGradient(
                    bandGradient,
                    startPoint: CGPoint(x: glowRect.midX, y: size.height),
                    endPoint: CGPoint(x: glowRect.midX, y: glowRect.minY)
                )
            )
        }
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

        processingQueue.async { [weak self, bands, bandCount] in
            let shapedBands = AuroraBandShapeProcessor.calculateBandValues(from: bands, bandCount: bandCount)

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
    private var smoothedBands = AuroraRenderModel.idleBands
    private var lastUpdateTime: TimeInterval?
    private let animationStartTime = ProcessInfo.processInfo.systemUptime

    var animationTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime - animationStartTime
    }

    var renderedBands: [Double] {
        smoothedBands
    }

    /// Mirror the active spectrum around the center, with higher frequencies outward.
    /// Skip sparse low FFT bands; compact surfaces show roughly 390 Hz–4 kHz.
    func displayBands(width: CGFloat, count: Int) -> [Double] {
        let expansion = min(1, max(0, (Double(width) - 430) / 470))
        let lowerIndex = 8.0
        let upperIndex = 17 + 6 * expansion
        let center = Double(count - 1) / 2
        let centerGap = count.isMultiple(of: 2) ? 0.5 : 0.0
        return (0..<count).map { index in
            // Both central samples reach the lowest band when the sample count is even.
            let distance = max(0, abs(Double(index) - center) - centerGap)
            let position = lowerIndex + distance / max(1, floor(center)) * (upperIndex - lowerIndex)
            let lower = Int(position)
            let upper = min(lower + 1, bandCount - 1)
            let fraction = position - Double(lower)
            return smoothedBands[lower] * (1 - fraction) + smoothedBands[upper] * fraction
        }
    }

    var isNearZero: Bool {
        smoothedBands.allSatisfy { $0 < 0.01 }
    }

    func resetToIdle() {
        smoothedBands = Self.idleBands
        lastUpdateTime = nil
    }

    /// Fast attack and a softer release, independent of analyzer or rendering cadence.
    func advance(targetBands: [Double], at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let deltaTime = max(0, min(time - (lastUpdateTime ?? (time - 1.0 / 30.0)), 0.1))
        lastUpdateTime = time
        for index in 0..<bandCount {
            let target = targetBands[index]
            let current = smoothedBands[index]
            let responseTime = target > current ? 0.10 : 0.32
            smoothedBands[index] = current + (target - current) * (1 - exp(-deltaTime / responseTime))
        }
    }

    private static let idleBands: [Double] = (0..<24).map { index in
        let normalizedPosition = Double(index) / 23.0
        let centerLift = exp(-pow(normalizedPosition - 0.5, 2) / (2 * pow(0.24, 2)))
        return 0.035 + centerLift * 0.075
    }
}
