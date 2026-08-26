import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// A card component for displaying a music genre in a grid layout
public struct GenreCard: View {
    let genre: Genre

    public init(genre: Genre) {
        self.genre = genre
    }

    public var body: some View {
        VStack(alignment: .center, spacing: EnsembleDesign.Spacing.none) {
            // Gradient background with music icon
            ZStack {
                // Generate a deterministic color based on genre name
                LinearGradient(
                    colors: [
                        genreColor(for: genre.title).opacity(EnsembleScaffold.MediaCard.genreGradientTopOpacity),
                        genreColor(for: genre.title).opacity(EnsembleScaffold.MediaCard.genreGradientBottomOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                Image(systemName: EnsembleDesign.Icon.genre)
                    .font(EnsembleDesign.Typography.mediaPlaceholderIcon)
                    .foregroundColor(EnsembleDesign.Color.onArtwork)
            }
            .frame(width: ArtworkSize.thumbnail.cgSize.width, height: ArtworkSize.thumbnail.cgSize.width)
            .cornerRadius(ArtworkCornerRadius.square(for: ArtworkSize.thumbnail))
            .ensembleCardShadow()
            
            // Genre name
            Text(genre.title)
                .font(EnsembleDesign.Typography.cardTitle)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(EnsembleDesign.Color.primaryText)
                .frame(width: ArtworkSize.thumbnail.cgSize.width)
                .padding(.top, EnsembleScaffold.MediaCard.contentSpacing)
        }
        .frame(maxWidth: ArtworkSize.thumbnail.cgSize.width, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
    
    /// Generate a deterministic color based on genre name
    private func genreColor(for name: String) -> Color {
        // Hash the genre name using UTF-8 byte reduction for consistent colors across views
        let hash = name.utf8.reduce(0) { ($0 &* EnsembleScaffold.MediaCard.genreHashMultiplier) &+ Int($1) }
        let index = abs(hash) % EnsembleScaffold.MediaCard.genrePalette.count
        return EnsembleScaffold.MediaCard.genrePalette[index]
    }
}
