import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Handcrafted system-material background used on iOS 15-25.
///
/// The root mini player is visible below most phone surfaces, so it avoids
/// artwork-backed blur entirely and lets the system color scheme carry the fill.
struct MiniPlayerBackground: View {
    let pillCornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    private let materialRole = EnsembleScaffold.MiniPlayer.materialRole

    var body: some View {
        RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
            .fill(materialRole.fallbackMaterial)
            .background(
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .fill(platformBackgroundColor)
            )
            .overlay(surfaceSheen)
            .overlay(
                RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)
                    .stroke(.primary.opacity(materialRole.strokeOpacity), lineWidth: 1)
            )
    }

    private var platformBackgroundColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var surfaceSheen: some View {
        RoundedRectangle(cornerRadius: pillCornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkTopOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity),
                        .clear,
                        .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkBottomOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
    }

}
