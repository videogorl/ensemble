import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Native macOS auxiliary window shell for Profile, Downloads, and similar tools.
public struct MacAuxiliaryWindowScaffold<Content: View>: View {
    private let configuration: EnsembleScaffold.AuxiliaryWindow.Configuration
    private let content: Content

    public init(
        configuration: EnsembleScaffold.AuxiliaryWindow.Configuration = .profile,
        @ViewBuilder content: () -> Content
    ) {
        self.configuration = configuration
        self.content = content()
    }

    public var body: some View {
        ZStack(alignment: .top) {
            windowBackground
                .ignoresSafeArea()
            content
                .frame(maxWidth: configuration.maxWidth, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: configuration.idealWidth)
        .frame(minHeight: configuration.minHeight)
    }

    private var windowBackground: Color {
        EnsembleScaffold.AuxiliaryWindow.backgroundColor
    }
}
