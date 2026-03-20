import EnsembleCore
import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - Offline Indicator Overlay

/// Device-aware offline connectivity indicator that uses a top gradient
/// to show connectivity status without consuming layout space.
/// The gradient fades from the indicator color at the top edge to transparent,
/// naturally working around the Dynamic Island, notch, or status bar since
/// those hardware cutouts are physically black.
public struct OfflineIndicatorOverlay: View {
    let networkState: NetworkState
    let topInset: CGFloat

    public init(networkState: NetworkState, topInset: CGFloat) {
        self.networkState = networkState
        self.topInset = topInset
    }

    public var body: some View {
        #if os(iOS)
        if shouldShow {
            indicatorView
                .allowsHitTesting(false)
                .ignoresSafeArea(.all, edges: .top)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: shouldShow)
                .animation(.easeInOut(duration: 0.3), value: indicatorColor)
        }
        #endif
    }

    private var shouldShow: Bool {
        // Hide in landscape (top inset drops to 0 when notch/DI is on the side)
        guard topInset > 0 else { return false }
        return isOfflineOrLimited
    }

    private var isOfflineOrLimited: Bool {
        switch networkState {
        case .offline, .limited:
            return true
        case .online, .unknown:
            return false
        }
    }

    private var indicatorColor: Color {
        switch networkState {
        case .offline:
            return Color.orange
        case .limited:
            return Color.yellow
        case .online, .unknown:
            return Color.clear
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var indicatorView: some View {
        // Simple top-edge gradient that works across all device types:
        // - Dynamic Island: hardware cutout is black, gradient shows around it
        // - Notch: same — notch is black hardware, gradient fills the ears
        // - Classic: gradient fills the status bar area
        // Uses only topInset (public API) — future-proof for any form factor.
        LinearGradient(
            colors: [indicatorColor, indicatorColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all, edges: .top)
    }
    #endif
}
