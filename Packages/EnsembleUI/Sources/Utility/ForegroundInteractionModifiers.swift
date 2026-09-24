import EnsembleCore
import SwiftUI

private final class ForegroundScrollActivityState {
    var isScrolling = false
    var endTask: Task<Void, Never>?
}

private struct ForegroundScrollActivityModifier: ViewModifier {
    @State private var state = ForegroundScrollActivityState()

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        beginScrolling()
                    }
                    .onEnded { _ in
                        scheduleScrollingEnd()
                    }
            )
            .onDisappear {
                endScrollingImmediately()
            }
        #else
        content
        #endif
    }

    private func beginScrolling() {
        state.endTask?.cancel()
        state.endTask = nil
        guard !state.isScrolling else { return }
        state.isScrolling = true
        DependencyContainer.shared.foregroundWorkScheduler.beginInteraction(.scrolling)
    }

    private func scheduleScrollingEnd() {
        state.endTask?.cancel()
        state.endTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            endScrollingImmediately()
        }
    }

    private func endScrollingImmediately() {
        state.endTask?.cancel()
        state.endTask = nil
        guard state.isScrolling else { return }
        state.isScrolling = false
        DependencyContainer.shared.foregroundWorkScheduler.endInteraction(.scrolling)
    }
}

extension View {
    /// Marks user-driven scroll windows so nonessential foreground work can wait
    /// until dense browse surfaces have settled on constrained iOS devices.
    func foregroundScrollActivity() -> some View {
        modifier(ForegroundScrollActivityModifier())
    }
}
