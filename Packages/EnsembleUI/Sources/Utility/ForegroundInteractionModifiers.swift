import EnsembleCore
import SwiftUI

private struct ForegroundScrollActivityModifier: ViewModifier {
    @State private var isScrolling = false
    @State private var endTask: Task<Void, Never>?

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
        endTask?.cancel()
        endTask = nil
        guard !isScrolling else { return }
        isScrolling = true
        DependencyContainer.shared.foregroundWorkScheduler.beginInteraction(.scrolling)
    }

    private func scheduleScrollingEnd() {
        endTask?.cancel()
        endTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            endScrollingImmediately()
        }
    }

    private func endScrollingImmediately() {
        endTask?.cancel()
        endTask = nil
        guard isScrolling else { return }
        isScrolling = false
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
