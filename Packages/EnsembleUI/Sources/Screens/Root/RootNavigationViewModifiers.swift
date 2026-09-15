import SwiftUI

extension View {
    @ViewBuilder
    func adaptiveTabChrome(isSelected: Bool, showsMiniPlayer: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            background {
                if isSelected {
                    // Native tab content already excludes the tab bar.
                    RootChromeFrameRegistrationView(
                        bottomPadding: TrackListLayoutMetrics.miniPlayerAdditionalBottomPadding,
                        showsMiniPlayer: showsMiniPlayer,
                        priority: 100,
                        ownsContentFrame: true
                    )
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
