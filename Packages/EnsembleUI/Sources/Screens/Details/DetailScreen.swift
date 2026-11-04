import EnsembleCore
import EnsembleDesignTokens
import SwiftUI

/// The blurred artwork behind a detail screen.
struct DetailBackdrop {
    let artworkImage: PlatformImage?
    let blurredImage: PlatformImage?
    let blurCacheKey: String?
    let continuityIdentity: String?
}

/// Per-kind chrome differences. The values live in `EnsembleScaffold`.
enum DetailScreenStyle {
    /// Album and playlist: a native track list that scrolls itself.
    case trackList
    /// Artist: a scrolling page of sections with a full-bleed hero.
    case artist
}

/// The shared detail screen shell: artwork-backed surface, collapsing title,
/// toolbar actions and chrome bleed. Each kind supplies its backdrop, toolbar
/// actions and content (a track list or a stack of sections).
struct DetailScreen<Actions: View, Content: View>: View {
    /// Coordinate space that titles report their scroll position in.
    static var scrollSpace: String { "detailScroll" }

    let title: String
    let style: DetailScreenStyle
    let backdrop: DetailBackdrop
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    @State private var showToolbarTitle = false

    var body: some View {
        surface
            .coordinateSpace(name: Self.scrollSpace)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                EnsembleDetailToolbarActions {
                    actions()
                }
            }
            .collapsingToolbarTitle(title, threshold: 0, showToolbarTitle: $showToolbarTitle)
            .artworkBackedToolbarBleed(hidesTopScrollEdgeEffect: style == .artist && !showToolbarTitle)
            .modifier(MiniPlayerSpacing(isEnabled: style == .artist))
    }

    @ViewBuilder
    private var surface: some View {
        switch style {
        case .trackList:
            MediaDetailSurface(
                artworkImage: backdrop.artworkImage,
                preBlurredArtworkImage: backdrop.blurredImage,
                preBlurredArtworkCacheKey: backdrop.blurCacheKey,
                artworkContinuityIdentity: backdrop.continuityIdentity,
                contentBleedsUnderTopChrome: true,
                contentBleedsUnderBottomChrome: true,
                content: content
            )
        case .artist:
            MediaDetailSurface(
                artworkImage: backdrop.artworkImage,
                preBlurredArtworkImage: backdrop.blurredImage,
                preBlurredArtworkCacheKey: backdrop.blurCacheKey,
                artworkContinuityIdentity: backdrop.continuityIdentity,
                backgroundHeight: EnsembleScaffold.ArtistDetail.backgroundHeight,
                darkLegibilityOpacity: EnsembleScaffold.ArtistDetail.darkLegibilityOverlayOpacity,
                lightLegibilityOpacity: EnsembleScaffold.ArtistDetail.lightLegibilityOverlayOpacity,
                contentBleedsUnderTopChrome: true,
                content: content
            )
        }
    }
}

private struct MiniPlayerSpacing: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.miniPlayerBottomSpacing()
        } else {
            content
        }
    }
}
