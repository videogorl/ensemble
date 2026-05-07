import SwiftUI

#if os(iOS)
import UIKit
#endif

var supportsCustomMiniPlayerSwipeGestures: Bool {
    #if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

struct MiniPlayerVerticalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var verticalOffset: CGFloat
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height < 0 {
                            verticalOffset = value.translation.height * EnsembleScaffold.MiniPlayer.verticalSwipeRubberBandFactor
                        }
                    }
                    .onEnded { value in
                        if value.translation.height < -EnsembleScaffold.MiniPlayer.verticalOpenThreshold {
                            onOpen()
                        }
                        withAnimation(.spring()) {
                            verticalOffset = 0
                        }
                    }
            )
        } else {
            content
        }
    }
}

struct MiniPlayerHorizontalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var dragOffset: CGFloat
    @Binding var opacity: Double
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture()
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragOffset = value.translation.width
                            opacity = 1.0 - min(
                                abs(value.translation.width) / EnsembleScaffold.MiniPlayer.horizontalSwipeFadeDistance,
                                EnsembleScaffold.MiniPlayer.horizontalSwipeMaximumFade
                            )
                        }
                    }
                    .onEnded { value in
                        let threshold = EnsembleScaffold.MiniPlayer.horizontalSwipeThreshold
                        if value.translation.width > threshold {
                            dismissThenReset(offset: EnsembleScaffold.MiniPlayer.horizontalSwipeDismissOffset, action: onPrevious)
                        } else if value.translation.width < -threshold {
                            dismissThenReset(offset: -EnsembleScaffold.MiniPlayer.horizontalSwipeDismissOffset, action: onNext)
                        } else {
                            reset()
                        }
                    }
            )
        } else {
            content
        }
    }

    private func dismissThenReset(offset: CGFloat, action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.3)) {
            dragOffset = offset
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + EnsembleScaffold.MiniPlayer.horizontalSwipeResetDelay) {
            action()
            reset()
        }
    }

    private func reset() {
        withAnimation(.spring(response: 0.3)) {
            dragOffset = 0
            opacity = 1.0
        }
    }
}
