import SwiftUI
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
        public let primary: Color
        public let secondary: Color
        public let tertiary: Color
        
        public init(primary: Color, secondary: Color, tertiary: Color) {
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
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
            let cornerColors = Self.extractCornerColors(from: resizedImage)
            let averageColor = Self.extractAverageColor(from: resizedImage)
            let dominantColor = Self.extractMostCommonColor(from: resizedImage)
            
            // Boost saturation for vibrant gradients
            let primary = Color(Self.boostSaturation(dominantColor, amount: 1.5))
            let secondary = Color(Self.boostSaturation(averageColor, amount: 1.3))
            let tertiary = Color(Self.boostSaturation(Self.blendColors(cornerColors), amount: 1.2))
            
            return GradientColors(primary: primary, secondary: secondary, tertiary: tertiary)
        }.value
        
        // Cache result
        if let key = cacheKey {
            await cacheActor.set(colors, forKey: key)
        }
        
        return colors
    }
    
    /// Extract colors from the four corners of the image
    private static func extractCornerColors(from image: UIImage) -> [UIColor] {
        guard let cgImage = image.cgImage else { return [.gray] }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Sample points at corners (with small offset to avoid edge artifacts)
        let samplePoints = [
            CGPoint(x: 5, y: 5),                    // Top-left
            CGPoint(x: width - 5, y: 5),            // Top-right
            CGPoint(x: 5, y: height - 5),           // Bottom-left
            CGPoint(x: width - 5, y: height - 5)    // Bottom-right
        ]
        
        return samplePoints.compactMap { point in
            getPixelColor(at: point, in: cgImage)
        }
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
    private static func extractMostCommonColor(from image: UIImage) -> UIColor {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return .gray
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
                
                // Skip very dark colors and grays (low saturation)
                let max = max(red, green, blue)
                let min = min(red, green, blue)
                let saturation = max == 0 ? 0 : (max - min) / max
                
                // Only count colors with decent brightness and saturation
                if max > 30 && saturation > 20 {
                    let bucketR = red / 16  // 0-15 bucket
                    let bucketG = green / 16
                    let bucketB = blue / 16
                    
                    let bucketKey = "\(bucketR),\(bucketG),\(bucketB)"
                    if var existing = colorBuckets[bucketKey] {
                        existing.count += 1
                        colorBuckets[bucketKey] = existing
                    } else {
                        colorBuckets[bucketKey] = (count: 1, r: bucketR, g: bucketG, b: bucketB)
                    }
                }
            }
        }
        
        // Find most common saturated bucket
        guard let mostCommon = colorBuckets.max(by: { $0.value.count < $1.value.count }) else {
            return .red  // Fallback to red if no colors found
        }
        
        let bucket = mostCommon.value
        return UIColor(
            red: CGFloat(bucket.r * 16 + 8) / 255.0,
            green: CGFloat(bucket.g * 16 + 8) / 255.0,
            blue: CGFloat(bucket.b * 16 + 8) / 255.0,
            alpha: 1.0
        )
    }
    
    /// Blend multiple colors together
    private static func blendColors(_ colors: [UIColor]) -> UIColor {
        guard !colors.isEmpty else { return .gray }
        
        var totalRed: CGFloat = 0
        var totalGreen: CGFloat = 0
        var totalBlue: CGFloat = 0
        
        for color in colors {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            totalRed += red
            totalGreen += green
            totalBlue += blue
        }
        
        let count = CGFloat(colors.count)
        return UIColor(
            red: totalRed / count,
            green: totalGreen / count,
            blue: totalBlue / count,
            alpha: 1.0
        )
    }
    
    /// Get pixel color at specific point
    private static func getPixelColor(at point: CGPoint, in cgImage: CGImage) -> UIColor? {
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        let x = Int(point.x)
        let y = Int(point.y)
        
        guard x >= 0, x < cgImage.width, y >= 0, y < cgImage.height else {
            return nil
        }
        
        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
        
        return UIColor(
            red: CGFloat(bytes[offset]) / 255.0,
            green: CGFloat(bytes[offset + 1]) / 255.0,
            blue: CGFloat(bytes[offset + 2]) / 255.0,
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
