import SwiftUI

enum AuroraMetalSurfaceTier: Int {
    case lowPower = 0
    case ambient = 1
    case immersive = 2
}

#if canImport(MetalKit)
import Metal
import MetalKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MetalAuroraSurface: View {
    static var isAvailable: Bool {
        AuroraMetalRenderer.canCreatePipeline
    }

    let renderModel: AuroraRenderModel
    let accentColor: Color
    let colorScheme: ColorScheme
    let preferredFrameInterval: Double
    let isPaused: Bool
    let surfaceTier: AuroraMetalSurfaceTier
    let activeContentMaxWidth: CGFloat?
    let bellWidth: CGFloat
    let bandCount: Int
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let poolHeight: CGFloat

    var body: some View {
        Representable(
            renderModel: renderModel,
            accentColor: accentColor,
            colorScheme: colorScheme,
            preferredFrameInterval: preferredFrameInterval,
            isPaused: isPaused,
            surfaceTier: surfaceTier,
            activeContentMaxWidth: activeContentMaxWidth,
            bellWidth: bellWidth,
            bandCount: bandCount,
            maxHeight: maxHeight,
            minHeight: minHeight,
            poolHeight: poolHeight
        )
    }
}

#if canImport(UIKit)
extension MetalAuroraSurface {
    struct Representable: UIViewRepresentable {
        let renderModel: AuroraRenderModel
        let accentColor: Color
        let colorScheme: ColorScheme
        let preferredFrameInterval: Double
        let isPaused: Bool
        let surfaceTier: AuroraMetalSurfaceTier
        let activeContentMaxWidth: CGFloat?
        let bellWidth: CGFloat
        let bandCount: Int
        let maxHeight: CGFloat
        let minHeight: CGFloat
        let poolHeight: CGFloat

        func makeCoordinator() -> AuroraMetalRenderer {
            AuroraMetalRenderer(renderModel: renderModel)
        }

        func makeUIView(context: Context) -> MTKView {
            context.coordinator.makeView()
        }

        func updateUIView(_ view: MTKView, context: Context) {
            context.coordinator.update(
                view: view,
                accentColor: accentColor,
                colorScheme: colorScheme,
                preferredFrameInterval: preferredFrameInterval,
                isPaused: isPaused,
                surfaceTier: surfaceTier,
                activeContentMaxWidth: activeContentMaxWidth,
                bellWidth: bellWidth,
                bandCount: bandCount,
                maxHeight: maxHeight,
                minHeight: minHeight,
                poolHeight: poolHeight
            )
        }
    }
}
#elseif canImport(AppKit)
extension MetalAuroraSurface {
    struct Representable: NSViewRepresentable {
        let renderModel: AuroraRenderModel
        let accentColor: Color
        let colorScheme: ColorScheme
        let preferredFrameInterval: Double
        let isPaused: Bool
        let surfaceTier: AuroraMetalSurfaceTier
        let activeContentMaxWidth: CGFloat?
        let bellWidth: CGFloat
        let bandCount: Int
        let maxHeight: CGFloat
        let minHeight: CGFloat
        let poolHeight: CGFloat

        func makeCoordinator() -> AuroraMetalRenderer {
            AuroraMetalRenderer(renderModel: renderModel)
        }

        func makeNSView(context: Context) -> MTKView {
            context.coordinator.makeView()
        }

        func updateNSView(_ view: MTKView, context: Context) {
            context.coordinator.update(
                view: view,
                accentColor: accentColor,
                colorScheme: colorScheme,
                preferredFrameInterval: preferredFrameInterval,
                isPaused: isPaused,
                surfaceTier: surfaceTier,
                activeContentMaxWidth: activeContentMaxWidth,
                bellWidth: bellWidth,
                bandCount: bandCount,
                maxHeight: maxHeight,
                minHeight: minHeight,
                poolHeight: poolHeight
            )
        }
    }
}
#endif

final class AuroraMetalRenderer: NSObject, MTKViewDelegate {
    static let canCreatePipeline: Bool = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              library.makeFunction(name: "auroraVertex") != nil,
              library.makeFunction(name: "auroraFragment") != nil else {
            return false
        }
        return true
    }()

    private struct Uniforms {
        var size: SIMD2<Float> = .zero
        var accentColor: SIMD4<Float> = .zero
        var maxHeight: Float = 80
        var minHeight: Float = 6
        var poolHeight: Float = 10
        var activeWidth: Float = 0
        var bandCount: UInt32 = 24
        var layerCount: UInt32 = 2
        var colorScheme: UInt32 = 0
        var bellWidth: Float = 0.24
        var time: Float = 0
    }

    private let renderModel: AuroraRenderModel
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private var uniforms = Uniforms()
    private var bandBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?

    init(renderModel: AuroraRenderModel) {
        self.renderModel = renderModel

        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()

        if let device,
           let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
           let vertex = library.makeFunction(name: "auroraVertex"),
           let fragment = library.makeFunction(name: "auroraFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        } else {
            self.pipelineState = nil
        }

        super.init()

        if let device {
            self.bandBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * 48, options: .storageModeShared)
            self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)
        }
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = 30
        configureTransparentBacking(for: view)

        return view
    }

    func update(
        view: MTKView,
        accentColor: Color,
        colorScheme: ColorScheme,
        preferredFrameInterval: Double,
        isPaused: Bool,
        surfaceTier: AuroraMetalSurfaceTier,
        activeContentMaxWidth: CGFloat?,
        bellWidth: CGFloat,
        bandCount: Int,
        maxHeight: CGFloat,
        minHeight: CGFloat,
        poolHeight: CGFloat
    ) {
        let backingScale = backingScaleFactor(for: view)

        uniforms.accentColor = resolvedRGBA(from: accentColor)
        // The shader runs in drawable pixels, while SwiftUI layout supplies points.
        // Convert every layout dimension so Retina displays do not halve the aurora.
        uniforms.maxHeight = Float(maxHeight * backingScale)
        uniforms.minHeight = Float(minHeight * backingScale)
        uniforms.poolHeight = Float(poolHeight * backingScale)
        uniforms.activeWidth = Float((activeContentMaxWidth ?? 0) * backingScale)
        uniforms.bellWidth = Float(bellWidth)
        uniforms.bandCount = UInt32(max(1, min(48, bandCount)))
        uniforms.layerCount = UInt32(layerCount(for: surfaceTier))
        uniforms.colorScheme = colorScheme == .dark ? 1 : 0

        view.preferredFramesPerSecond = framesPerSecond(for: preferredFrameInterval)
        let shouldPause = isPaused || pipelineState == nil
        view.isPaused = shouldPause
        configureTransparentBacking(for: view)
        if shouldPause, pipelineState != nil {
            view.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.size = SIMD2(Float(size.width), Float(size.height))
        if view.isPaused {
            view.draw()
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let pipelineState,
              let bandBuffer,
              let uniformBuffer else { return }

        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        uniforms.time = Float(renderModel.animationTime)
        copyBands(into: bandBuffer, width: view.bounds.width)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func copyBands(into buffer: MTLBuffer, width: CGFloat) {
        let bands = renderModel.displayBands(width: width, count: Int(uniforms.bandCount))
        let pointer = buffer.contents().assumingMemoryBound(to: Float.self)
        for index in bands.indices {
            pointer[index] = Float(max(0, min(1, bands[index])))
        }
    }

    private func layerCount(for tier: AuroraMetalSurfaceTier) -> Int {
        switch tier {
        case .lowPower:
            return 1
        case .ambient, .immersive:
            return 3
        }
    }

    private func framesPerSecond(for interval: Double) -> Int {
        guard interval > 0 else { return 30 }
        return max(15, min(60, Int((1.0 / interval).rounded())))
    }

    private func resolvedRGBA(from color: Color) -> SIMD4<Float> {
        #if canImport(UIKit)
        let platformColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
        #else
        let platformColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return SIMD4(
            Float(platformColor.redComponent),
            Float(platformColor.greenComponent),
            Float(platformColor.blueComponent),
            Float(platformColor.alphaComponent)
        )
        #endif
    }

    private func backingScaleFactor(for view: MTKView) -> CGFloat {
        #if canImport(UIKit)
        return max(1, view.window?.screen.scale ?? view.contentScaleFactor)
        #elseif canImport(AppKit)
        let converted = view.convertToBacking(CGSize(width: 1, height: 1))
        if converted.width > 0 {
            return max(1, converted.width)
        }
        return max(1, view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        #endif
    }

    private func configureTransparentBacking(for view: MTKView) {
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.layer.backgroundColor = UIColor.clear.cgColor
        #elseif canImport(AppKit)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        #endif
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
    };

    struct Uniforms {
        float2 size;
        float4 accentColor;
        float maxHeight;
        float minHeight;
        float poolHeight;
        float activeWidth;
        uint bandCount;
        uint layerCount;
        uint colorScheme;
        float bellWidth;
        float time;
    };

    vertex VertexOut auroraVertex(uint vertexID [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        return out;
    }

    static float smoothBand(float edge0, float edge1, float value) {
        float x = clamp((value - edge0) / max(edge1 - edge0, 0.0001), 0.0, 1.0);
        return x * x * (3.0 - 2.0 * x);
    }

    fragment float4 auroraFragment(
        VertexOut in [[stage_in]],
        constant float *bands [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]
    ) {
        float2 p = in.position.xy;
        if (u.size.x <= 1.0 || u.size.y <= 1.0) {
            return float4(0.0);
        }

        uint bandCount = min(u.bandCount, 48u);
        float activeWidth = u.activeWidth > 0.0 ? min(u.size.x, u.activeWidth) : u.size.x;
        float xOffset = (u.size.x - activeWidth) * 0.5;
        float bandWidth = activeWidth / max(float(bandCount), 1.0);
        float alpha = 0.0;

        for (uint layer = 0; layer < u.layerCount; layer++) {
            uint depth = u.layerCount == 1 ? 2u : layer;
            float layerOpacity = depth == 0 ? 0.20 : (depth == 1 ? 0.40 : 0.50);
            float spread = depth == 0 ? 2.0 : (depth == 1 ? 1.15 : 0.65);
            float heightScale = depth == 0 ? 1.85 : (depth == 1 ? 1.10 : 1.30);
            float verticalSoftness = depth == 0 ? 0.48 : 0.70;
            float verticalBlur = depth == 0 ? 1.12 : 1.95;

            // Slow independent motion gives each curtain its own shape and brightness.
            float layerPhase = u.time * (0.19 + 0.07 * float(depth)) + float(depth) * 2.1;
            float widthScale = 0.92 + 0.08 * sin(layerPhase);
            float layerBreath = 0.86 + 0.14 * sin(layerPhase * 1.3 + 1.7);
            float layerDrift = 0.025 * sin(layerPhase * 0.7 + 0.8) * activeWidth;
            float baseOpacity = (u.colorScheme == 1 ? 0.70 : 0.50) * layerOpacity * (0.82 + 0.18 * sin(layerPhase + 2.4));

            for (uint i = 0; i < bandCount; i++) {
                float intensity = clamp(bands[i], 0.0, 1.0);
                float normalized = bandCount > 1 ? float(i) / float(bandCount - 1) : 0.5;
                float bell = exp(-pow(normalized - 0.5, 2.0) / (2.0 * pow(u.bellWidth, 2.0)));
                float phase = u.time * (0.25 + 0.15 * float(depth)) + normalized * 6.1 + float(depth) * 2.1;
                float breath = 0.9 + 0.1 * sin(phase + 1.3);
                float heightTaper = min(1.0, min(normalized, 1.0 - normalized) / 0.20);
                float height = (u.minHeight + (u.maxHeight - u.minHeight) * pow(intensity, 1.35) * bell * heightTaper) * heightScale * breath * layerBreath;
                float drift = sin(phase) * (0.25 + 0.12 * float(depth)) * bandWidth;
                float centeredX = (float(i) + 0.5) * bandWidth - activeWidth * 0.5;
                float centerX = xOffset + activeWidth * 0.5 + centeredX * widthScale + layerDrift + drift;
                float glowWidth = bandWidth * 3.0 * spread * widthScale;
                float rectHeight = height + u.poolHeight * heightScale;

                float dx = (p.x - centerX) / max(glowWidth * 0.5, 1.0);
                float dy = (u.size.y - p.y) / max(rectHeight, 1.0);
                float ellipse = exp(-(dx * dx * 1.65 + dy * dy * verticalBlur));
                float vertical = 1.0 - smoothBand(verticalSoftness, 1.0, dy);
                // Brightness arrives early so the subsequent rise is visible.
                float intensityAlpha = sqrt(intensity);
                float contribution = ellipse * vertical * intensityAlpha * baseOpacity;

                // Additive light from independently moving curtains.
                alpha += contribution * 0.72;
            }
        }

        float topFeather = smoothBand(0.0, u.size.y * 0.20, p.y);
        alpha = clamp(alpha * topFeather, 0.0, 1.0) * u.accentColor.a;

        // Premultiply once so brighter peaks preserve the selected accent hue.
        return float4(u.accentColor.rgb * alpha, alpha);
    }
    """
}

#else
struct MetalAuroraSurface: View {
    static var isAvailable: Bool { false }

    let renderModel: AuroraRenderModel
    let accentColor: Color
    let colorScheme: ColorScheme
    let preferredFrameInterval: Double
    let isPaused: Bool
    let surfaceTier: AuroraMetalSurfaceTier
    let activeContentMaxWidth: CGFloat?
    let bellWidth: CGFloat
    let bandCount: Int
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let poolHeight: CGFloat

    var body: some View {
        EmptyView()
    }
}
#endif
