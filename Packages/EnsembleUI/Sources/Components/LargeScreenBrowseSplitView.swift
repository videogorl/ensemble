import SwiftUI

/// Adaptive two-pane shell for large browse surfaces.
/// Compact widths keep the existing single-column content unchanged.
public struct LargeScreenBrowseSplitView<
    Selection: Identifiable,
    Sidebar: View,
    Detail: View,
    Placeholder: View,
    Compact: View
>: View {
    @Binding private var selection: Selection?
    private let minimumSplitWidth: CGFloat
    private let sidebarWidth: CGFloat
    private let compact: Compact
    private let sidebar: Sidebar
    private let detail: (Selection) -> Detail
    private let placeholder: Placeholder

    public init(
        selection: Binding<Selection?>,
        minimumSplitWidth: CGFloat = 820,
        sidebarWidth: CGFloat = 340,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: @escaping (Selection) -> Detail,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self._selection = selection
        self.minimumSplitWidth = minimumSplitWidth
        self.sidebarWidth = sidebarWidth
        self.compact = compact()
        self.sidebar = sidebar()
        self.detail = detail
        self.placeholder = placeholder()
    }

    public var body: some View {
        GeometryReader { geometry in
            if usesSplitLayout(for: geometry.size) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: min(sidebarWidth, geometry.size.width * 0.42))
                        .frame(maxHeight: .infinity)

                    Divider()

                    Group {
                        if let selection {
                            detail(selection)
                        } else {
                            placeholder
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                compact
            }
        }
    }

    private func usesSplitLayout(for size: CGSize) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom != .phone else { return false }
        #endif
        return size.width >= minimumSplitWidth
    }
}

public struct LargeScreenPlaceholderView: View {
    private let systemImage: String
    private let title: String

    public init(systemImage: String, title: String) {
        self.systemImage = systemImage
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.secondary.opacity(0.75))

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
