import SwiftUI

#if canImport(UIKit)
import UIKit

/// Utility for extracting colors from album artwork to create gradient backgrounds
public class ArtworkColorExtractor {
    
    // Cache to avoid re-extracting colors for the same artwork (thread-safe with actor)
    private actor ColorCacheActor {
        private var cache: [String: GradientColors] = [:]
        
        func get(_ key: String) -> GradientColors? {
            cache[key]
        }
        
        func set(_ value: GradientColors, forKey key: String) {
            cache[key] = value
        }
        
        func removeAll() {
            cache.removeAll()
        }
    }
    
    private static let cacheActor = ColorCacheActor()
    
    /// Extracted colors for creating gradients
    public struct GradientColors: Sendable {
        public let accent: Color
        public let secondary: Color
        public let isLight: Bool
        
        public init(accent: Color, secondary: Color, isLight: Bool) {
            self.accent = accent
            self.secondary = secondary
            self.isLight = isLight
        }
    }
    
    /// Extract colors from an image to create a vibrant gradient
    /// Combines corner colors, average color, and most common color for best results
    public static func extractColors(from uiImage: UIImage, cacheKey: String? = nil) async -> GradientColors {
        // Check cache first
        if let key = cacheKey, let cached = await cacheActor.get(key) {
            return cached
        }
        
        // Perform extraction on background thread
        let colors = await Task.detached {
            // Resize image for faster processing (avoid processing full resolution)
            let resizedImage = Self.resizeImage(uiImage, targetSize: CGSize(width: 100, height: 100))
            
            // Extract colors using multiple methods
            let averageColor = Self.extractAverageColor(from: resizedImage)
            let dominantColor = Self.extractMostCommonColor(from: resizedImage, fallback: averageColor)
            
            // Boost saturation for vibrant gradients
            let accentUIColor = Self.boostSaturation(dominantColor, amount: 1.5)
            let secondaryUIColor = Self.boostSaturation(averageColor, amount: 1.3)
            
            let accent = Color(accentUIColor)
            let secondary = Color(secondaryUIColor)
            
            // Determine if the background is light based on the accent color's luminance
            let isLight = Self.isLightColor(accentUIColor)
            
            return GradientColors(accent: accent, secondary: secondary, isLight: isLight)
        }.value
        
        // Cache result
        if let key = cacheKey {
            await cacheActor.set(colors, forKey: key)
        }
        
        return colors
    }

    /// Check if a color is considered "light" (high luminance)
    private static func isLightColor(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Formula for relative luminance
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6
    }
    
    /// Calculate average color of entire image
    private static func extractAverageColor(from image: UIImage) -> UIColor {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return .gray
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        
        var totalRed: CGFloat = 0
        var totalGreen: CGFloat = 0
        var totalBlue: CGFloat = 0
        var pixelCount: CGFloat = 0
        
        // Sample every 4th pixel for performance
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let red = CGFloat(bytes[offset]) / 255.0
                let green = CGFloat(bytes[offset + 1]) / 255.0
                let blue = CGFloat(bytes[offset + 2]) / 255.0
                
                totalRed += red
                totalGreen += green
                totalBlue += blue
                pixelCount += 1
            }
        }
        
        return UIColor(
            red: totalRed / pixelCount,
            green: totalGreen / pixelCount,
            blue: totalBlue / pixelCount,
            alpha: 1.0
        )
    }
    
    /// Find most common color using color bucketing, excluding grays/blacks
    private static func extractMostCommonColor(from image: UIImage, fallback: UIColor) -> UIColor {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return fallback
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        
        // Use color buckets to group similar colors (reduce to 16 buckets per channel for better key color detection)
        var colorBuckets: [String: (count: Int, r: Int, g: Int, b: Int)] = [:]
        
        // Sample every 3rd pixel for better coverage
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                
                // Calculate basic saturation: (max - min) / max
                let r = Double(red) / 255.0
                let g = Double(green) / 255.0
                let b = Double(blue) / 255.0
                
                let maxVal = max(r, g, b)
                let minVal = min(r, g, b)
                let saturation = maxVal == 0 ? 0 : (maxVal - minVal) / maxVal
                
                // Filter out:
                // 1. Very dark colors (brightness < 15%)
                // 2. Very desaturated colors (saturation < 15%) unless they are very frequent
                // 3. Very bright white-ish colors (brightness > 95% and saturation < 10%)
                
                let isTooDark = maxVal < 0.15
                let isTooGray = saturation < 0.15
                let isTooWhite = maxVal > 0.95 && saturation < 0.10
                
                if !isTooDark && !isTooWhite {
                    // Give extra weight to saturated colors
                    let weight = isTooGray ? 1 : 3
                    
                    let bucketR = red / 16
                    let bucketG = green / 16
                    let bucketB = blue / 16
                    
                    let bucketKey = "\(bucketR),\(bucketG),\(bucketB)"
                    if var existing = colorBuckets[bucketKey] {
                        existing.count += weight
                        colorBuckets[bucketKey] = existing
                    } else {
                        colorBuckets[bucketKey] = (count: weight, r: bucketR, g: bucketG, b: bucketB)
                    }
                }
            }
        }
        
        // Find most common bucket
        guard let mostCommon = colorBuckets.max(by: { $0.value.count < $1.value.count }) else {
            return fallback
        }
        
        let bucket = mostCommon.value
        return UIColor(
            red: CGFloat(bucket.r * 16 + 8) / 255.0,
            green: CGFloat(bucket.g * 16 + 8) / 255.0,
            blue: CGFloat(bucket.b * 16 + 8) / 255.0,
            alpha: 1.0
        )
    }
    
    /// Resize image for faster processing
    private static func resizeImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    /// Boost color saturation for more vibrant gradients
    private static func boostSaturation(_ color: UIColor, amount: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        
        // Boost saturation and brightness
        let boostedSaturation = min(saturation * amount, 1.0)
        let boostedBrightness = min(brightness * 1.1, 1.0)
        
        return UIColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
    
    /// Clear color cache
    public static func clearCache() async {
        await cacheActor.removeAll()
    }
}
#else
#if canImport(AppKit)
import AppKit
public typealias UIImage = NSImage
#endif

public class ArtworkColorExtractor {
    public struct GradientColors: Sendable {
        public let accent: Color
        public let secondary: Color
        public let isLight: Bool
        public init(accent: Color, secondary: Color, isLight: Bool) {
            self.accent = accent
            self.secondary = secondary
            self.isLight = isLight
        }
    }
    
    public static func extractColors(from image: UIImage, cacheKey: String? = nil) async -> GradientColors {
        return GradientColors(accent: .gray, secondary: .black, isLight: false)
    }
    
    public static func clearCache() async {}
}
#endif
