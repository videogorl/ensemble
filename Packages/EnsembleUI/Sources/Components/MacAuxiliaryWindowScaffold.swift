import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Native macOS auxiliary window shell for Profile, Downloads, and similar tools.
public struct MacAuxiliaryWindowScaffold<Content: View>: View {
    private let maxWidth: CGFloat
    private let minHeight: CGFloat
    private let content: Content

    public init(
        maxWidth: CGFloat = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth,
        minHeight: CGFloat = 560,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .top) {
            windowBackground
                .ignoresSafeArea()
            content
                .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: maxWidth)
        .frame(minHeight: minHeight)
    }

    private var windowBackground: Color {
        EnsembleDesign.Color.windowSurface
    }
}
