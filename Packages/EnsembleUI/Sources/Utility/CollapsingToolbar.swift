import EnsembleDesignTokens
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Scroll Offset Title Preference Key

/// PreferenceKey that tracks the maxY position of a title element in scroll coordinates.
/// When the title scrolls above the nav bar threshold, the toolbar title appears.
struct TitleOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Collapsing Toolbar Title Modifier

/// Modifier that shows a toolbar title when the inline title scrolls out of view.
struct CollapsingToolbarTitleModifier: ViewModifier {
    let title: String
    let threshold: CGFloat  // maxY value below which toolbar title appears
    @Binding var showToolbarTitle: Bool

    private var shouldEnableCollapsingToolbarTitle: Bool {
        #if os(macOS)
        return false
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        Group {
            if shouldEnableCollapsingToolbarTitle {
                content
                    .onPreferenceChange(TitleOffsetPreferenceKey.self) { maxY in
                        let shouldShow = maxY < threshold
                        if shouldShow != showToolbarTitle {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showToolbarTitle = shouldShow
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(title)
                                .font(EnsembleDesign.Typography.toolbarTitle)
                                .lineLimit(1)
                                .opacity(showToolbarTitle ? 1 : 0)
                        }
                    }
                    #if os(iOS)
                    // SwiftUI toolbarBackground respects iOS 26 Liquid Glass.
                    .modifier(ToolbarBackgroundModifier(isTransparent: !showToolbarTitle))
                    #endif
            } else {
                content
                    .onAppear {
                        showToolbarTitle = false
                    }
            }
        }
    }
}

// MARK: - Title Offset Tracker

/// Attaches a GeometryReader background to track the title's position in scroll coordinates.
struct TitleOffsetTracker: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: TitleOffsetPreferenceKey.self,
                    value: geometry.frame(in: .named(coordinateSpace)).maxY
                )
        }
    }
}

// MARK: - Toolbar Background Modifier

#if os(iOS)
/// Uses SwiftUI's `.toolbarBackground` API to hide/show the nav bar background.
/// On iOS 26+ this also suppresses the Liquid Glass bar material.
private struct ToolbarBackgroundModifier: ViewModifier {
    let isTransparent: Bool

    func body(content: Content) -> some View {
        content
            .toolbarBackground(isTransparent ? .hidden : .visible, for: .navigationBar)
    }
}
#endif

// MARK: - View Extension

extension View {
    /// Adds a collapsing toolbar title that appears when the inline title scrolls out of view.
    func collapsingToolbarTitle(
        _ title: String,
        threshold: CGFloat = 0,
        showToolbarTitle: Binding<Bool>
    ) -> some View {
        self.modifier(CollapsingToolbarTitleModifier(
            title: title,
            threshold: threshold,
            showToolbarTitle: showToolbarTitle
        ))
    }

    /// Keeps top-edge content visible behind platform toolbar chrome.
    func toolbarMaterialBleed(hidesTopScrollEdgeEffect: Bool = false) -> some View {
        modifier(ToolbarMaterialBleedModifier(hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect))
    }

    /// Requests the native toolbar material without making the toolbar fully transparent.
    func toolbarMaterialBackground() -> some View {
        modifier(ToolbarMaterialBackgroundModifier())
    }

    /// Keeps artwork-backed surfaces visible behind platform toolbar chrome.
    func artworkBackedToolbarBleed(hidesTopScrollEdgeEffect: Bool = false) -> some View {
        toolbarMaterialBleed(hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect)
    }

}

private struct ToolbarMaterialBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
        content
        #endif
    }
}

private struct ToolbarMaterialBleedModifier: ViewModifier {
    let hidesTopScrollEdgeEffect: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            phoneContent(content)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectStyle(.automatic, for: .top)
        } else {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func phoneContent(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidesTopScrollEdgeEffect, for: .top)
        } else {
            content
        }
    }
    #endif
}
