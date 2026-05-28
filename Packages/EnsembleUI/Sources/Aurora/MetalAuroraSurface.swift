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
        var maxHeight: Float = 220
        var minHeight: Float = 25
        var poolHeight: Float = 48
        var activeWidth: Float = 0
        var bandCount: UInt32 = 24
        var layerCount: UInt32 = 2
        var colorScheme: UInt32 = 0
        var padding: UInt32 = 0
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
            self.bandBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * 24, options: .storageModeShared)
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
        uniforms.bandCount = UInt32(max(1, min(24, bandCount)))
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
        copyBands(into: bandBuffer)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func copyBands(into buffer: MTLBuffer) {
        let bands = renderModel.renderedBands
        let pointer = buffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<24 {
            pointer[index] = index < bands.count ? Float(max(0, min(1, bands[index]))) : 0
        }
    }

    private func layerCount(for tier: AuroraMetalSurfaceTier) -> Int {
        switch tier {
        case .lowPower:
            return 1
        case .ambient:
            return 2
        case .immersive:
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
        uint padding;
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

        uint bandCount = min(u.bandCount, 24u);
        float activeWidth = u.activeWidth > 0.0 ? min(u.size.x, u.activeWidth) : u.size.x;
        float xOffset = (u.size.x - activeWidth) * 0.5;
        float bandWidth = activeWidth / max(float(bandCount), 1.0);
        float3 color = float3(0.0);
        float alpha = 0.0;

        for (uint layer = 0; layer < u.layerCount; layer++) {
            float layerOpacity;
            float spread;
            float heightScale;
            float verticalSoftness;
            float verticalBlur;
            if (u.layerCount == 1) {
                layerOpacity = 0.50;
                spread = 1.8;
                heightScale = 0.94;
                verticalSoftness = 0.62;
                verticalBlur = 1.75;
            } else if (u.layerCount == 2) {
                layerOpacity = layer == 0 ? 0.20 : 0.42;
                spread = layer == 0 ? 2.3 : 1.25;
                heightScale = layer == 0 ? 1.05 : 0.94;
                verticalSoftness = layer == 0 ? 0.48 : 0.70;
                verticalBlur = layer == 0 ? 1.12 : 1.95;
            } else {
                layerOpacity = layer == 0 ? 0.16 : (layer == 1 ? 0.28 : 0.38);
                spread = layer == 0 ? 2.7 : (layer == 1 ? 1.75 : 1.15);
                heightScale = layer == 0 ? 1.12 : (layer == 1 ? 1.02 : 0.94);
                verticalSoftness = layer == 0 ? 0.42 : (layer == 1 ? 0.58 : 0.76);
                verticalBlur = layer == 0 ? 0.92 : (layer == 1 ? 1.42 : 2.4);
            }

            float baseOpacity = (u.colorScheme == 1 ? 0.70 : 0.50) * layerOpacity;

            for (uint i = 0; i < bandCount; i++) {
                float intensity = clamp(bands[i], 0.0, 1.0);
                float normalized = bandCount > 1 ? float(i) / float(bandCount - 1) : 0.5;
                float bell = exp(-pow(normalized - 0.5, 2.0) / (2.0 * pow(0.34, 2.0)));
                float height = (u.minHeight + (u.maxHeight - u.minHeight) * intensity * bell) * heightScale;
                float centerX = xOffset + (float(i) + 0.5) * bandWidth;
                float glowWidth = bandWidth * 4.5 * spread;
                float rectHeight = height + u.poolHeight * heightScale;
                float rectMinY = u.size.y - height - u.poolHeight;
                float rectCenterY = rectMinY + rectHeight * 0.5;

                float dx = (p.x - centerX) / max(glowWidth * 0.5, 1.0);
                float dy = (p.y - rectCenterY) / max(rectHeight * 0.5, 1.0);
                float ellipse = exp(-(dx * dx * 1.65 + dy * dy * verticalBlur));
                float t = clamp((p.y - rectMinY) / max(rectHeight, 1.0), 0.0, 1.0);
                float fromBottom = 1.0 - t;
                float vertical = smoothBand(0.0, 0.08, fromBottom) * (1.0 - smoothBand(verticalSoftness, 1.0, fromBottom));
                float bellAlpha = 0.32 + bell * 0.68;
                float intensityAlpha = (0.18 + intensity * 0.82) * bellAlpha;
                float contribution = ellipse * vertical * intensityAlpha * baseOpacity;

                color += u.accentColor.rgb * contribution;
                alpha += contribution * 0.72;
            }
        }

        float energy = 0.0;
        float bassEnergy = 0.0;
        uint bassCount = min(bandCount, 6u);
        for (uint i = 0; i < bandCount; i++) {
            energy += clamp(bands[i], 0.0, 1.0);
            if (i < bassCount) {
                bassEnergy += clamp(bands[i], 0.0, 1.0);
            }
        }
        energy = bandCount > 0 ? energy / float(bandCount) : 0.0;
        bassEnergy = bassCount > 0 ? bassEnergy / float(bassCount) : 0.0;
        energy = clamp(energy * 0.70 + bassEnergy * 0.30, 0.0, 1.0);

        float bridgeHeight = u.poolHeight + 76.0;
        float bridgeWidth = activeWidth * 1.16;
        float2 bridgeCenter = float2(u.size.x * 0.5, u.size.y - bridgeHeight * 0.5 - 18.0);
        float2 bridgeD = (p - bridgeCenter) / float2(max(bridgeWidth * 0.5, 1.0), max(bridgeHeight * 0.5, 1.0));
        float bridge = exp(-(bridgeD.x * bridgeD.x * 1.3 + bridgeD.y * bridgeD.y * 2.0));
        float bridgeOpacity = (u.colorScheme == 1 ? 0.34 : 0.24) * (0.45 + energy * 0.7);
        color += u.accentColor.rgb * bridge * bridgeOpacity;
        alpha += bridge * bridgeOpacity * 0.72;

        float fromBottomPixels = u.size.y - p.y;
        float pool = 1.0 - smoothBand(0.0, u.poolHeight + 52.0, fromBottomPixels);
        float poolOpacity = (u.colorScheme == 1 ? 0.58 : 0.38) * (0.84 + energy * 0.34);
        color += u.accentColor.rgb * pool * poolOpacity;
        alpha += pool * poolOpacity * 0.75;

        float topFeather = smoothBand(0.0, 96.0, p.y);
        color *= topFeather;
        alpha = clamp(alpha * topFeather, 0.0, 0.95);

        color = min(color, float3(alpha));

        return float4(color, alpha);
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
    let bandCount: Int
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let poolHeight: CGFloat

    var body: some View {
        EmptyView()
    }
}
#endif
