import SwiftUI

/// Shared visual chrome modifiers for surfaces that should not tune their own
/// depth, radius, or material stack independently.
public extension View {
    func ensembleStandardShadow() -> some View {
        shadow(
            color: EnsembleDesign.Effect.shadowColor,
            radius: EnsembleDesign.Effect.shadowRadius,
            x: EnsembleDesign.Effect.shadowX,
            y: EnsembleDesign.Effect.shadowY
        )
    }

    func ensembleCardShadow() -> some View {
        shadow(
            color: EnsembleDesign.Effect.cardShadowColor,
            radius: EnsembleDesign.Effect.cardShadowRadius,
            x: EnsembleDesign.Effect.shadowX,
            y: EnsembleDesign.Effect.cardShadowY
        )
    }

    func ensembleArtworkShadow() -> some View {
        shadow(
            color: EnsembleScaffold.DetailSurface.ArtworkShadow.color,
            radius: EnsembleScaffold.DetailSurface.ArtworkShadow.radius,
            x: EnsembleScaffold.DetailSurface.ArtworkShadow.x,
            y: EnsembleScaffold.DetailSurface.ArtworkShadow.y
        )
    }

}
