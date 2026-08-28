import EnsembleCore
import SwiftUI

public struct ArtistCard: View {
    let artist: Artist
    let onTap: (() -> Void)?

    public init(artist: Artist, onTap: (() -> Void)? = nil) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(
                artist: artist,
                size: .thumbnail,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width),
                isResponsive: true
            )

            Text(artist.name)
                .font(EnsembleDesign.Typography.cardTitle)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
    }
}
