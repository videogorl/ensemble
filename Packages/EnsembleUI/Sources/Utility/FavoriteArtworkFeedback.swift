import EnsembleDesignTokens
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FavoriteArtworkFeedbackModifier: ViewModifier {
    let isEnabled: Bool
    let onFavorite: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var opacity = 0.0
    @State private var scale = 0.65
    @State private var animationTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if isEnabled {
            content
                .overlay {
                    if isVisible {
                        GeometryReader { proxy in
                            Image(systemName: "heart.fill")
                                .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.34, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                                .scaleEffect(scale)
                                .opacity(opacity)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: favorite)
                .accessibilityAction(named: Text("Favorite"), favorite)
                .onDisappear { animationTask?.cancel() }
        } else {
            content
        }
        #else
        content
        #endif
    }

    private func favorite() {
        guard isEnabled else { return }
        onFavorite()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "Added to Favorites")
        #endif
        animate()
    }

    private func animate() {
        animationTask?.cancel()
        isVisible = true
        opacity = 1
        scale = reduceMotion ? 1 : 0.65
        animationTask = Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
                try? await Task.sleep(nanoseconds: 400_000_000)
            } else {
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.55)) { scale = 1.15 }
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.68)) { scale = 1 }
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) { opacity = 0 }
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

extension View {
    func favoriteArtworkFeedback(
        isEnabled: Bool = true,
        onFavorite: @escaping () -> Void
    ) -> some View {
        modifier(FavoriteArtworkFeedbackModifier(isEnabled: isEnabled, onFavorite: onFavorite))
    }
}
