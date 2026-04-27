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
    private let configuration: EnsembleScaffold.BrowseSplit.Configuration
    private let compact: Compact
    private let sidebar: Sidebar
    private let detail: (Selection) -> Detail
    private let placeholder: Placeholder
    @State private var adjustedSidebarWidth: CGFloat?
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var isResizeHandleHovered = false

    public init(
        selection: Binding<Selection?>,
        minimumSplitWidth: CGFloat = EnsembleDesign.Breakpoint.browseSplitMinimumWidth,
        sidebarWidth: CGFloat = 340,
        minimumSidebarWidth: CGFloat = 260,
        maximumSidebarWidth: CGFloat = 460,
        minimumDetailWidth: CGFloat = 420,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: @escaping (Selection) -> Detail,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.init(
            selection: selection,
            configuration: EnsembleScaffold.BrowseSplit.Configuration(
                minimumSplitWidth: minimumSplitWidth,
                sidebarWidth: sidebarWidth,
                minimumSidebarWidth: minimumSidebarWidth,
                maximumSidebarWidth: maximumSidebarWidth,
                minimumDetailWidth: minimumDetailWidth
            ),
            compact: compact,
            sidebar: sidebar,
            detail: detail,
            placeholder: placeholder
        )
    }

    public init(
        selection: Binding<Selection?>,
        configuration: EnsembleScaffold.BrowseSplit.Configuration,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: @escaping (Selection) -> Detail,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self._selection = selection
        self.configuration = configuration
        self.compact = compact()
        self.sidebar = sidebar()
        self.detail = detail
        self.placeholder = placeholder()
    }

    public var body: some View {
        GeometryReader { geometry in
            if usesSplitLayout(for: geometry.size) {
                splitLayout(for: geometry.size)
            } else {
                compact
            }
        }
    }

    @ViewBuilder
    private func splitLayout(for size: CGSize) -> some View {
        swiftUISplitLayout(for: size)
    }

    private func swiftUISplitLayout(for size: CGSize) -> some View {
        let currentSidebarWidth = resolvedSidebarWidth(for: size)
        return HStack(spacing: 0) {
            sidebar
                .frame(width: currentSidebarWidth)
                .frame(maxHeight: .infinity)
                .clipped()
                .zIndex(0)

            resizeHandle(currentSidebarWidth: currentSidebarWidth, containerWidth: size.width)
                .zIndex(1)

            detailContent
                .zIndex(0)
        }
        .transaction { transaction in
            if dragStartSidebarWidth != nil {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .coordinateSpace(name: EnsembleScaffold.BrowseSplit.coordinateSpaceName)
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let selection {
                detail(selection)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resizeHandle(currentSidebarWidth: CGFloat, containerWidth: CGFloat) -> some View {
        ZStack {
            Divider()

            // Masks list separators that can otherwise draw through the translucent thumb.
            RoundedRectangle(cornerRadius: EnsembleDesign.Spacing.xs + 1, style: .continuous)
                .fill(resizeHandleBackingColor)
                .frame(width: 10, height: 64)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(EnsembleDesign.Color.secondaryText.opacity(isResizeHandleHovered ? 0.7 : 0.35))
                .frame(width: 3, height: 48)
                .opacity(isResizeHandleHovered ? 1 : 0.65)
        }
        .frame(width: configuration.resizeHandleWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(EnsembleScaffold.BrowseSplit.coordinateSpaceName))
                .onChanged { value in
                    let startWidth = dragStartSidebarWidth ?? currentSidebarWidth
                    let nextWidth = clampedSidebarWidth(
                        startWidth + value.translation.width,
                        containerWidth: containerWidth
                    )
                    let previousWidth = adjustedSidebarWidth ?? currentSidebarWidth
                    guard dragStartSidebarWidth == nil || abs(nextWidth - previousWidth) >= 0.5 else {
                        return
                    }

                    var transaction = Transaction()
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if dragStartSidebarWidth == nil {
                            dragStartSidebarWidth = startWidth
                        }
                        adjustedSidebarWidth = nextWidth
                    }
                }
                .onEnded { _ in
                    var transaction = Transaction()
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        dragStartSidebarWidth = nil
                    }
                }
        )
        .onHover { hovering in
            isResizeHandleHovered = hovering
        }
        .accessibilityLabel("Resize browse panes")
        .accessibilityHint("Drag horizontally to change the selection pane width.")
    }

    private var resizeHandleBackingColor: Color {
        EnsembleDesign.Color.windowSurface
    }

    private func usesSplitLayout(for size: CGSize) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom != .phone else { return false }
        #endif
        return size.width >= configuration.minimumSplitWidth
    }

    private func resolvedSidebarWidth(for size: CGSize) -> CGFloat {
        clampedSidebarWidth(adjustedSidebarWidth ?? configuration.sidebarWidth, containerWidth: size.width)
    }

    private func clampedSidebarWidth(_ proposedWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let availableMaximum = min(
            configuration.maximumSidebarWidth,
            max(
                configuration.minimumSidebarWidth,
                containerWidth - configuration.minimumDetailWidth - configuration.resizeHandleWidth
            )
        )
        return min(max(proposedWidth, configuration.minimumSidebarWidth), availableMaximum)
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
        VStack(spacing: EnsembleDesign.Spacing.popoverActionHorizontal) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(0.75))

            Text(title)
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
