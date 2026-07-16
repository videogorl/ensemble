import CoreImage
import Foundation

#if os(iOS) || os(tvOS) || os(watchOS)
    import UIKit

    public typealias PlatformImage = UIImage
#elseif os(macOS)
    import AppKit

    public typealias PlatformImage = NSImage
#endif

/// Shared pre-renderer for artwork washes.
///
/// SwiftUI `.blur` on large artwork layers forces repeated offscreen rendering.
/// This renderer bakes the color adjustment and Gaussian blur into a bitmap once,
/// then keeps the result in memory and on disk when callers provide a stable key.
public enum ArtworkBlurRenderer {
    private static let renderVersion = "v2"
    private static let gaussianBlurRadius = 180.0
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let diskCacheDirectoryName = "ArtworkBlurCache"

    public static func cachedBlurredImage(for source: PlatformImage) -> PlatformImage? {
        cache.object(forKey: cacheKey(for: source))
    }

    public static func cachedBlurredImage(forStableKey stableKey: String) -> PlatformImage? {
        let key = cacheKey(forStableKey: stableKey)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let diskURL = diskCacheURL(forStableKey: stableKey),
              let image = imageFromDisk(at: diskURL) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: memoryCost(of: image))
        return image
    }

    public static func blurredImage(from source: PlatformImage, stableKey: String? = nil) -> PlatformImage? {
        let key = stableKey.map(cacheKey(forStableKey:)) ?? cacheKey(for: source)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let stableKey,
           let diskURL = diskCacheURL(forStableKey: stableKey),
           let diskImage = imageFromDisk(at: diskURL) {
            cache.setObject(diskImage, forKey: key, cost: memoryCost(of: diskImage))
            return diskImage
        }

        guard let rendered = generateBlurredImage(from: source) else {
            return nil
        }
        cache.setObject(rendered, forKey: key, cost: memoryCost(of: rendered))
        if let stableKey {
            writeImageToDisk(rendered, stableKey: stableKey)
        }
        return rendered
    }

    public static func clearCache() {
        cache.removeAllObjects()
        guard let directoryURL = diskCacheDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    public static func clearMemoryCache() {
        cache.removeAllObjects()
    }

    private static func memoryCost(of image: PlatformImage) -> Int {
        #if os(iOS) || os(tvOS) || os(watchOS)
            if let cgImage = image.cgImage {
                return cgImage.bytesPerRow * cgImage.height
            }
            let width = Int(image.size.width * image.scale)
            let height = Int(image.size.height * image.scale)
            return width * height * 4
        #elseif os(macOS)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return Int(image.size.width * image.size.height * 4)
            }
            return cgImage.bytesPerRow * cgImage.height
        #endif
    }

    private static func cacheKey(for source: PlatformImage) -> NSString {
        let identity = ObjectIdentifier(source).hashValue
        #if os(iOS) || os(tvOS) || os(watchOS)
            let size = source.size
            let scale = source.scale
            return "\(renderVersion):\(identity):\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        #elseif os(macOS)
            let size = source.size
            return "\(renderVersion):\(identity):\(Int(size.width))x\(Int(size.height))" as NSString
        #endif
    }

    private static func cacheKey(forStableKey stableKey: String) -> NSString {
        "stable:\(renderVersion):\(stableKeyDigest(stableKey))" as NSString
    }

    private static func stableKeyDigest(_ stableKey: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(renderVersion):\(stableKey)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func diskCacheURL(forStableKey stableKey: String) -> URL? {
        diskCacheDirectoryURL()?
            .appendingPathComponent(stableKeyDigest(stableKey))
            .appendingPathExtension("jpg")
    }

    private static func diskCacheDirectoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(diskCacheDirectoryName, isDirectory: true)
    }

    private static func imageFromDisk(at url: URL) -> PlatformImage? {
        #if os(iOS) || os(tvOS) || os(watchOS)
            return UIImage(contentsOfFile: url.path)
        #elseif os(macOS)
            return NSImage(contentsOf: url)
        #endif
    }

    private static func writeImageToDisk(_ image: PlatformImage, stableKey: String) {
        guard let url = diskCacheURL(forStableKey: stableKey),
              let data = encodedJPEGData(for: image) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            EnsembleLogger.debug("ArtworkBlurRenderer: Failed to persist blurred artwork: \(error.localizedDescription)")
        }
    }

    private static func encodedJPEGData(for image: PlatformImage) -> Data? {
        #if os(iOS) || os(tvOS) || os(watchOS)
            return image.jpegData(compressionQuality: 0.85)
        #elseif os(macOS)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            return representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.85]
            )
        #endif
    }

    private nonisolated static func generateBlurredImage(from source: PlatformImage) -> PlatformImage? {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard let ciImage = CIImage(image: source) else { return nil }
        #elseif os(macOS)
            let ciImage: CIImage
            if let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ciImage = CIImage(cgImage: cgImage)
            } else if let tiffData = source.tiffRepresentation,
                      let image = CIImage(data: tiffData) {
                ciImage = image
            } else {
                return nil
            }
        #endif

        guard let colorFilter = CIFilter(name: "CIColorControls") else { return nil }
        colorFilter.setValue(ciImage, forKey: kCIInputImageKey)
        colorFilter.setValue(2.0, forKey: kCIInputContrastKey)
        colorFilter.setValue(1.9, forKey: kCIInputSaturationKey)
        colorFilter.setValue(-0.05, forKey: kCIInputBrightnessKey)

        guard let colorAdjusted = colorFilter.outputImage else { return nil }

        // Keep Gaussian blur as the final visual filter so the tuned artwork
        // signal is smeared after contrast/saturation/brightness are baked in.
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(colorAdjusted, forKey: kCIInputImageKey)
        blurFilter.setValue(gaussianBlurRadius, forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage else { return nil }
        let output = blurred.cropped(to: ciImage.extent)

        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else { return nil }

        #if os(iOS) || os(tvOS) || os(watchOS)
            return UIImage(cgImage: cgImage)
        #elseif os(macOS)
            return NSImage(cgImage: cgImage, size: source.size)
        #endif
    }
}
