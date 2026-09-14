// Run from the repository root: swift scripts/check_aurora_metal.swift
// Compare the current shader against the approved waveform before optimization.
import Foundation
import Metal

struct Uniforms {
    var size = SIMD2<Float>(402, 433)
    var accentColor = SIMD4<Float>(0.3, 0.7, 1, 1)
    var maxHeight: Float = 194
    var minHeight: Float = 6
    var poolHeight: Float = 18
    var activeWidth: Float = 0
    var bandCount: UInt32 = 48
    var layerCount: UInt32 = 3
    var colorScheme: UInt32 = 1
    var bellWidth: Float = 0.60
    var time: Float = 0
}

let sourcePath = "Packages/EnsembleUI/Sources/Aurora/MetalAuroraSurface.swift"
let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
git.arguments = ["show", "46608df1:\(sourcePath)"]
let output = Pipe()
git.standardOutput = output
try git.run()
let reference = output.fileHandleForReading.readDataToEndOfFile()
git.waitUntilExit()
precondition(git.terminationStatus == 0, "Reference commit 46608df1 must be available")
let sources = [String(decoding: reference, as: UTF8.self), try String(contentsOfFile: sourcePath, encoding: .utf8)]
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("A Metal device is required")
}
let libraries = try sources.map { source -> MTLLibrary in
    let shader = source.components(separatedBy: "private static let shaderSource = \"\"\"")[1]
        .components(separatedBy: "\"\"\"")[0]
    return try device.makeLibrary(source: shader, options: nil)
}
let pipelines = try libraries.map { library -> MTLRenderPipelineState in
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "auroraVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "auroraFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
let preparation = try device.makeComputePipelineState(function: libraries[1].makeFunction(name: "prepareAuroraBands")!)
let preparedBands = device.makeBuffer(length: 48 * 3 * 32, options: .storageModePrivate)!
var uniforms = Uniforms()
var cases = 0
var maximumDifference = 0

// Phone/full and low-power tiers, plus a constrained wide surface in light mode.
for (width, height, bands, layers, activeWidth, bellWidth, scheme) in [
    (402, 433, 48, 3, 0, 0.60, 1),
    (402, 433, 24, 1, 0, 0.60, 1),
    (1000, 248, 48, 3, 900, 0.24, 0)
] {
    uniforms.size = SIMD2(Float(width), Float(height))
    uniforms.bandCount = UInt32(bands)
    uniforms.layerCount = UInt32(layers)
    uniforms.activeWidth = Float(activeWidth)
    uniforms.bellWidth = Float(bellWidth)
    uniforms.colorScheme = UInt32(scheme)
    uniforms.maxHeight = width > 402 ? 102 : 194
    uniforms.poolHeight = width > 402 ? 10 : 18
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    textureDescriptor.usage = .renderTarget
    textureDescriptor.storageMode = .shared
    let textures = (0..<2).map { _ in device.makeTexture(descriptor: textureDescriptor)! }
    for time: Float in [0, 7, 37] {
        for level: Float in [0, 0.03, 0.4, 1] {
            uniforms.time = time
            let values = (0..<bands).map { level * Float(0.3 + 0.7 * abs(sin(Double($0) * 0.21))) }
            var images = [[UInt8]]()
            for variant in 0..<2 {
                let command = queue.makeCommandBuffer()!
                if variant == 1 {
                    let encoder = command.makeComputeCommandEncoder()!
                    encoder.setComputePipelineState(preparation)
                    values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
                    encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setBuffer(preparedBands, offset: 0, index: 2)
                    let threads = preparation.threadExecutionWidth
                    encoder.dispatchThreadgroups(
                        MTLSize(width: (bands * layers + threads - 1) / threads, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1)
                    )
                    encoder.endEncoding()
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = textures[variant]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipelines[variant])
                if variant == 0 {
                    values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                } else {
                    encoder.setFragmentBuffer(preparedBands, offset: 0, index: 2)
                }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                precondition(command.status == .completed, "Metal command failed: \(String(describing: command.error))")
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                bytes.withUnsafeMutableBytes {
                    textures[variant].getBytes($0.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                images.append(bytes)
            }
            let difference = zip(images[0], images[1]).map { abs(Int($0) - Int($1)) }.max()!
            precondition(difference <= 1, "Appearance mismatch: \(difference)/255 at time \(time), amplitude \(level), bands \(bands)")
            maximumDifference = max(maximumDifference, difference)
            cases += 1
        }
    }
}
print("PASS: \(cases) Metal frame comparisons; maximum channel difference \(maximumDifference)/255")
