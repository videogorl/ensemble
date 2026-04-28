import EnsembleCore
import SwiftUI

/// A card component for displaying a music genre in a grid layout
public struct GenreCard: View {
    let genre: Genre
    let onTap: (() -> Void)?

    public init(genre: Genre, onTap: (() -> Void)? = nil) {
        self.genre = genre
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 0) {
            // Gradient background with music icon
            ZStack {
                // Generate a deterministic color based on genre name
                LinearGradient(
                    colors: [
                        genreColor(for: genre.title).opacity(0.8),
                        genreColor(for: genre.title).opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                Image(systemName: EnsembleDesign.Icon.genre)
                    .font(EnsembleDesign.Typography.mediaPlaceholderIcon)
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: ArtworkSize.thumbnail.cgSize.width, height: ArtworkSize.thumbnail.cgSize.width)
            .cornerRadius(ArtworkCornerRadius.square(for: ArtworkSize.thumbnail))
            .shadow(
                color: EnsembleDesign.Effect.cardShadowColor,
                radius: EnsembleDesign.Effect.cardShadowRadius,
                x: 0,
                y: EnsembleDesign.Effect.cardShadowY
            )
            
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
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
    }
    
    /// Generate a deterministic color based on genre name
    private func genreColor(for name: String) -> Color {
        let colors: [Color] = [
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo
        ]

        // Hash the genre name using UTF-8 byte reduction for consistent colors across views
        let hash = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % colors.count
        return colors[index]
    }
}

// MARK: - Genre Grid

public struct GenreGrid: View {
    let genres: [Genre]
    let onGenreTap: ((Genre) -> Void)?

    private let columns = EnsembleScaffold.MediaCard.personGridColumns

    public init(genres: [Genre], onGenreTap: ((Genre) -> Void)? = nil) {
        self.genres = genres
        self.onGenreTap = onGenreTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
            ForEach(genres) { genre in
                GenreCard(genre: genre) {
                    onGenreTap?(genre)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}
