import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootMiniPlayerOverlay: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void

    @State private var displayedLayout: RootChromeLayout = .hidden
    @State private var pendingLayoutUpdate: Task<Void, Never>?

    private var isPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var miniPlayerHorizontalPadding: CGFloat {
        isPhoneLayout ? 8 : 20
    }

    private var miniPlayerHeight: CGFloat {
        max(
            EnsembleScaffold.MiniPlayer.artworkDimension,
            EnsembleScaffold.MiniPlayer.largeRowMinimumHeight
        ) + (TrackListLayoutMetrics.rowVerticalPadding * 2)
            + EnsembleScaffold.MiniPlayer.floatingBottomPadding
    }

    private var effectiveLayout: RootChromeLayout {
        guard layout.showsMiniPlayer, layout.hasRenderableFrame else {
            return layout
        }

        guard displayedLayout.showsMiniPlayer, displayedLayout.hasRenderableFrame else {
            return layout
        }

        return displayedLayout
    }

    var body: some View {
        let resolvedLayout = effectiveLayout
        let resolvedMiniPlayerWidth = miniPlayerWidth(for: resolvedLayout)
        let resolvedMiniPlayerPosition = miniPlayerPosition(
            for: resolvedLayout,
            miniPlayerHeight: miniPlayerHeight
        )

        if resolvedLayout.showsMiniPlayer && resolvedLayout.hasRenderableFrame && resolvedMiniPlayerWidth > 0 {
            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: true,
                showsWaveform: !isPhoneLayout && resolvedMiniPlayerWidth >= 280,
                waveformColor: accentColor,
                horizontalPadding: miniPlayerHorizontalPadding,
                usesGlassEffectIdentity: false,
                namespace: namespace,
                animationID: animationID
            ) {
                withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.85)) {
                    presentNowPlaying()
                }
            }
            .accentColor(accentColor)
            .frame(width: resolvedMiniPlayerWidth)
            .position(resolvedMiniPlayerPosition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .transition(.identity)
            .onAppear {
                applyLayoutImmediately(layout)
            }
            .onChange(of: layout) { newLayout in
                scheduleLayoutUpdate(newLayout)
            }
            .onDisappear {
                pendingLayoutUpdate?.cancel()
                pendingLayoutUpdate = nil
            }
        }
    }

    private func miniPlayerWidth(for layout: RootChromeLayout) -> CGFloat {
        if isPhoneLayout {
            // Keep the mini player aligned to the tab bar capsule while leaving
            // just enough extra width to avoid looking visually under-hung.
            return max(layout.frame.width - 28, 0)
        }
        return min(620, max(layout.frame.width - 32, 0))
    }

    private func miniPlayerPosition(
        for layout: RootChromeLayout,
        miniPlayerHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: layout.frame.midX + layout.horizontalOffset,
            y: layout.frame.maxY - layout.bottomPadding - (miniPlayerHeight / 2)
        )
    }

    private func applyLayoutImmediately(_ newLayout: RootChromeLayout) {
        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = nil

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedLayout = newLayout
        }
    }

    private func scheduleLayoutUpdate(_ newLayout: RootChromeLayout) {
        guard newLayout.showsMiniPlayer, newLayout.hasRenderableFrame else {
            applyLayoutImmediately(newLayout)
            return
        }

        guard displayedLayout.showsMiniPlayer, displayedLayout.hasRenderableFrame else {
            applyLayoutImmediately(newLayout)
            return
        }

        guard newLayout != displayedLayout else {
            pendingLayoutUpdate?.cancel()
            pendingLayoutUpdate = nil
            return
        }

        pendingLayoutUpdate?.cancel()
        pendingLayoutUpdate = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            applyLayoutImmediately(newLayout)
        }
    }
}
