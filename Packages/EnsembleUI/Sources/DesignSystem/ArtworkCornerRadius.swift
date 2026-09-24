import EnsembleDesignTokens
import CoreGraphics
import EnsembleCore

/// Shared corner-radius rules for square media artwork (album/track/playlist).
/// Uses a proportional radius with sensible clamps so tiny thumbnails still read
/// rounded while large hero artwork doesn't become overly pill-shaped.
public enum ArtworkCornerRadius {
    private static let minimum: CGFloat = 4
    private static let maximum: CGFloat = 20

    public static func square(for dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return minimum }
        return min(max(EnsembleDesign.Radius.artworkSquare(for: dimension), minimum), maximum)
    }

    public static func square(for size: ArtworkSize) -> CGFloat {
        square(for: size.cgSize.width)
    }

    public static func circle(for dimension: CGFloat) -> CGFloat {
        EnsembleDesign.Radius.artworkCircle(for: dimension)
    }
}
