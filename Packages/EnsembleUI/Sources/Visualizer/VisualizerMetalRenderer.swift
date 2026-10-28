import EnsembleCore
import SwiftUI

#if canImport(MetalKit)
import Metal
import MetalKit
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders the full-screen Now Playing visualizer from live engine output.
///
/// Every style draws an intensity field, then maps it to color. Battery and
/// Waves feed the previous field back with a small zoom, swirl, or drift, the
/// trail technique the early-2000s desktop visualizers used. Bars draws the
/// spectrum directly with falling peak caps.
final class VisualizerMetalRenderer: NSObject, MTKViewDelegate {
    static let isAvailable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            return false
        }
        return ["visualizerVertex", "visualizerField", "visualizerPresent"]
            .allSatisfy { library.makeFunction(name: $0) != nil }
    }()

    private struct Uniforms {
        var fieldSize: SIMD2<Float> = .zero
        var time: Float = 0
        var bass: Float = 0
        var level: Float = 0
        var decay: Float = 0.95
        var zoom: Float = 1
        var rotation: Float = 0
        var style: UInt32 = 0
        var variant: UInt32 = 0
        var barCount: UInt32 = UInt32(VisualizerMetalRenderer.barCount)
        var waveformLength: UInt32 = UInt32(LiveAudioAnalyzer.waveformLength)
        var colorLow: SIMD4<Float> = .zero
        var colorMid: SIMD4<Float> = .zero
        var colorHigh: SIMD4<Float> = .zero
    }

    private static let barCount = 32
    private static let batteryVariantCount = 3
    private static let batteryVariantDuration: Double = 24
    private static let fieldFormat = MTLPixelFormat.r16Float

    private let analyzer: LiveAudioAnalyzer
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let fieldPipeline: MTLRenderPipelineState?
    private let presentPipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?

    private var fieldTextures: [MTLTexture] = []
    private var currentField = 0
    private var fieldNeedsClear = true
    private var uniforms = Uniforms()
    private var style: VisualizerStyle = .battery
    private var accent = SIMD4<Float>(0.3, 0.5, 1, 1)

    private let startTime = CACurrentMediaTime()
    private var lastFrameTime: Double?
    private var bars = [Float](repeating: 0, count: barCount)
    private var peaks = [Float](repeating: 0, count: barCount)
    private var peakHold = [Float](repeating: 0, count: barCount)
    private var peakVelocity = [Float](repeating: 0, count: barCount)
    private var isDrawing = false

    init(feed: LiveAudioFeed) {
        analyzer = LiveAudioAnalyzer(feed: feed)
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()

        if let device,
           let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let vertex = library.makeFunction(name: "visualizerVertex"),
           let field = library.makeFunction(name: "visualizerField"),
           let present = library.makeFunction(name: "visualizerPresent") {
            let fieldDescriptor = MTLRenderPipelineDescriptor()
            fieldDescriptor.vertexFunction = vertex
            fieldDescriptor.fragmentFunction = field
            fieldDescriptor.colorAttachments[0].pixelFormat = Self.fieldFormat
            fieldPipeline = try? device.makeRenderPipelineState(descriptor: fieldDescriptor)

            let presentDescriptor = MTLRenderPipelineDescriptor()
            presentDescriptor.vertexFunction = vertex
            presentDescriptor.fragmentFunction = present
            presentDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            presentPipeline = try? device.makeRenderPipelineState(descriptor: presentDescriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToZero
            samplerDescriptor.tAddressMode = .clampToZero
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        } else {
            fieldPipeline = nil
            presentPipeline = nil
            sampler = nil
        }
        super.init()
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.isPaused = true
        return view
    }

    func update(view: MTKView, style: VisualizerStyle, accentColor: Color, framesPerSecond: Int, isPaused: Bool) {
        if style != self.style {
            self.style = style
            fieldNeedsClear = true
        }
        accent = Self.resolvedRGBA(accentColor)
        view.preferredFramesPerSecond = framesPerSecond
        let shouldPause = isPaused || fieldPipeline == nil || presentPipeline == nil
        if view.isPaused != shouldPause {
            view.isPaused = shouldPause
            lastFrameTime = nil
        }
        if shouldPause {
            view.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Resizing the drawable can request a nested draw.
        guard !isDrawing else { return }
        isDrawing = true
        defer { isDrawing = false }

        let scale = Self.renderScale(for: view)
        let size = CGSize(
            width: (view.bounds.width * scale).rounded(.down),
            height: (view.bounds.height * scale).rounded(.down)
        )
        guard size.width > 0, size.height > 0 else { return }
        if view.drawableSize != size {
            view.drawableSize = size
        }
        prepareFieldTextures(size: size)

        guard fieldTextures.count == 2,
              let fieldPipeline,
              let presentPipeline,
              let sampler,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        advanceAudioState()

        let previous = fieldTextures[currentField]
        let next = fieldTextures[1 - currentField]
        if fieldNeedsClear {
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = previous
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            commandBuffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
            fieldNeedsClear = false
        }

        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = next
        fieldPass.colorAttachments[0].loadAction = .dontCare
        fieldPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: fieldPass) {
            encoder.label = "Visualizer field"
            encoder.setRenderPipelineState(fieldPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            analyzer.waveform.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            bars.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            peaks.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
            encoder.setFragmentTexture(previous, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        currentField = 1 - currentField

        guard let drawable = view.currentDrawable,
              let presentPass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) else {
            commandBuffer.commit()
            return
        }
        encoder.label = "Visualizer present"
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(next, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Audio state

    private func advanceAudioState() {
        let now = CACurrentMediaTime()
        let deltaTime = Float(min(0.1, max(0, now - (lastFrameTime ?? now))))
        lastFrameTime = now
        analyzer.update()
        let spectrum = analyzer.spectrum

        let bandsPerBar = spectrum.count / Self.barCount
        for index in 0..<Self.barCount {
            let start = index * bandsPerBar
            let target = spectrum[start..<(start + bandsPerBar)].max() ?? 0
            bars[index] = max(target, bars[index] - 1.6 * deltaTime)

            if bars[index] >= peaks[index] {
                peaks[index] = bars[index]
                peakHold[index] = 0.35
                peakVelocity[index] = 0
            } else if peakHold[index] > 0 {
                peakHold[index] -= deltaTime
            } else {
                peakVelocity[index] += 2.2 * deltaTime
                peaks[index] = max(bars[index], peaks[index] - peakVelocity[index] * deltaTime)
            }
        }

        let bass = (spectrum.prefix(6).reduce(0, +) / 6)
        uniforms.bass = max(bass * bass, uniforms.bass - 2.5 * deltaTime)
        uniforms.level += (analyzer.level - uniforms.level) * min(1, 12 * deltaTime)

        let elapsed = now - startTime
        uniforms.time = Float(elapsed.truncatingRemainder(dividingBy: 3600))
        uniforms.style = Self.styleIndex(style)
        uniforms.variant = style == .battery
            ? UInt32(Int(elapsed / Self.batteryVariantDuration) % Self.batteryVariantCount)
            : 0
        applyMotion()
        applyPalette()
    }

    private func applyMotion() {
        switch (style, uniforms.variant) {
        case (.battery, 0):
            uniforms.decay = 0.955
            uniforms.zoom = 1.012 + uniforms.bass * 0.035
            uniforms.rotation = 0.006
        case (.battery, 1):
            uniforms.decay = 0.962
            uniforms.zoom = 1.006 + uniforms.bass * 0.02
            uniforms.rotation = -0.014
        case (.battery, _):
            uniforms.decay = 0.95
            uniforms.zoom = 0.988 - uniforms.bass * 0.02
            uniforms.rotation = 0.018
        case (.waves, _):
            uniforms.decay = 0.93
            uniforms.zoom = 1
            uniforms.rotation = 0
        case (.bars, _):
            uniforms.decay = 0
            uniforms.zoom = 1
            uniforms.rotation = 0
        }
    }

    private func applyPalette() {
        switch style {
        case .battery:
            break // Battery cycles a cosine palette in the shader.
        case .bars:
            uniforms.colorLow = accent * 0.35
            uniforms.colorMid = accent
            uniforms.colorHigh = accent + (SIMD4<Float>(1, 1, 1, 1) - accent) * 0.75
        case .waves:
            uniforms.colorLow = SIMD4(0.02, 0.07, 0.24, 1)
            uniforms.colorMid = SIMD4(0.08, 0.55, 0.85, 1)
            uniforms.colorHigh = SIMD4(0.85, 0.97, 1, 1)
        }
    }

    private static func styleIndex(_ style: VisualizerStyle) -> UInt32 {
        switch style {
        case .battery: return 0
        case .bars: return 1
        case .waves: return 2
        }
    }

    // MARK: - Resources

    private func prepareFieldTextures(size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        if fieldTextures.count == 2, fieldTextures[0].width == width, fieldTextures[0].height == height {
            return
        }
        guard let device else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.fieldFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        fieldTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        uniforms.fieldSize = SIMD2(Float(width), Float(height))
        fieldNeedsClear = true
    }

    /// Half the native pixel density keeps the fill cost low; the soft upscale suits the look.
    private static func renderScale(for view: MTKView) -> CGFloat {
        #if canImport(UIKit)
        return max(1, view.traitCollection.displayScale) * 0.5
        #else
        let backing = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return max(1, backing) * 0.5
        #endif
    }

    private static func resolvedRGBA(_ color: Color) -> SIMD4<Float> {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4(Float(red), Float(green), Float(blue), 1)
        #else
        let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemBlue
        return SIMD4(Float(resolved.redComponent), Float(resolved.greenComponent), Float(resolved.blueComponent), 1)
        #endif
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float2 fieldSize;
        float time;
        float bass;
        float level;
        float decay;
        float zoom;
        float rotation;
        uint style;
        uint variant;
        uint barCount;
        uint waveformLength;
        float4 colorLow;
        float4 colorMid;
        float4 colorHigh;
    };

    vertex VertexOut visualizerVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        // Texture space: origin at the top left.
        out.uv = positions[vertexID] * float2(0.5, -0.5) + 0.5;
        return out;
    }

    static float sampleWave(constant float *wave, uint count, float t) {
        float x = clamp(t, 0.0, 1.0) * float(count - 1);
        uint i = uint(x);
        uint j = min(i + 1, count - 1);
        return mix(wave[i], wave[j], x - float(i));
    }

    static float glowLine(float distance, float thickness) {
        return smoothstep(thickness * 2.5, 0.0, distance);
    }

    fragment float4 visualizerField(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(0)]],
        constant float *wave [[buffer(1)]],
        constant float *bars [[buffer(2)]],
        constant float *peaks [[buffer(3)]],
        texture2d<float> previous [[texture(0)]],
        sampler fieldSampler [[sampler(0)]]
    ) {
        float aspect = u.fieldSize.x / max(u.fieldSize.y, 1.0);
        float2 uv = in.uv;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float pixel = 1.0 / max(u.fieldSize.y, 1.0);

        if (u.style == 1) {
            float height = 1.0 - uv.y;
            float slot = uv.x * float(u.barCount);
            uint index = min(uint(slot), u.barCount - 1);
            float within = fract(slot);
            if (within < 0.12 || within > 0.88) {
                return float4(0.0);
            }
            const float maxHeight = 0.6;
            float top = bars[index] * maxHeight;
            float peak = peaks[index] * maxHeight + 0.012;
            // Bodies stay in the darker half of the palette; only peak caps are bright.
            float value = height <= top ? 0.12 + 0.48 * (height / maxHeight) : 0.0;
            if (abs(height - peak) < 0.005) {
                value = 1.0;
            }
            return float4(value, 0.0, 0.0, 1.0);
        }

        float c = cos(u.rotation);
        float s = sin(u.rotation);
        float2 q = float2(c * p.x - s * p.y, s * p.x + c * p.y) / u.zoom;
        float history;
        if (u.style == 2) {
            // Drift upward and spread sideways so the trail reads as mist.
            q.y += 2.5 * pixel;
            float2 previousUV = q / float2(aspect, 1.0) + 0.5;
            float2 dx = float2(1.5 / max(u.fieldSize.x, 1.0), 0.0);
            history = 0.5 * previous.sample(fieldSampler, previousUV).r
                + 0.25 * previous.sample(fieldSampler, previousUV - dx).r
                + 0.25 * previous.sample(fieldSampler, previousUV + dx).r;
        } else {
            q += 0.004 * float2(sin(q.y * 9.0 + u.time * 0.7), cos(q.x * 9.0 - u.time * 0.6));
            history = previous.sample(fieldSampler, q / float2(aspect, 1.0) + 0.5).r;
        }
        history *= u.decay;

        float thickness = (1.5 + 3.0 * u.level) * pixel;
        float line;
        if (u.style == 2) {
            float y = sampleWave(wave, u.waveformLength, uv.x) * 0.3;
            line = glowLine(abs(p.y - 0.12 - y), thickness);
        } else if (u.variant == 0) {
            // A ring whose radius follows the waveform, mirrored so the seam closes.
            float angle = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;
            float radius = 0.17 + 0.06 * u.bass + sampleWave(wave, u.waveformLength, abs(angle * 2.0 - 1.0)) * 0.12;
            line = glowLine(abs(length(p) - radius), thickness);
        } else if (u.variant == 1) {
            float y = sampleWave(wave, u.waveformLength, uv.x) * 0.24;
            line = glowLine(abs(p.y - y), thickness);
        } else {
            float x = sampleWave(wave, u.waveformLength, uv.y) * 0.16;
            line = glowLine(abs(abs(p.x) - (0.1 + 0.05 * u.bass + x)), thickness);
        }

        float value = max(history, line * (0.75 + 0.5 * u.level));
        return float4(value, 0.0, 0.0, 1.0);
    }

    fragment float4 visualizerPresent(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(0)]],
        texture2d<float> field [[texture(0)]],
        sampler fieldSampler [[sampler(0)]]
    ) {
        float v = field.sample(fieldSampler, in.uv).r;
        float3 color;
        if (u.style == 0) {
            float3 phase = u.variant == 0 ? float3(0.0, 0.33, 0.67)
                : (u.variant == 1 ? float3(0.05, 0.15, 0.3) : float3(0.5, 0.25, 0.0));
            float t = v * 0.9 + u.time * 0.04;
            color = (0.5 + 0.5 * cos(6.28318 * (t + phase))) * smoothstep(0.02, 0.3, v);
        } else {
            float3 low = u.colorLow.rgb;
            float3 mid = u.colorMid.rgb;
            float3 high = u.colorHigh.rgb;
            color = v < 0.6 ? mix(low, mid, v / 0.6) : mix(mid, high, saturate((v - 0.6) / 0.4));
            color *= smoothstep(0.0, 0.12, v);
        }
        return float4(color, 1.0);
    }
    """
}
#endif
