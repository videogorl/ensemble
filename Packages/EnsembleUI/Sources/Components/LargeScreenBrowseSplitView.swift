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
    private let minimumSidebarWidth: CGFloat
    private let maximumSidebarWidth: CGFloat
    private let minimumDetailWidth: CGFloat
    private let resizeHandleWidth: CGFloat = 12
    private let compact: Compact
    private let sidebar: Sidebar
    private let detail: (Selection) -> Detail
    private let placeholder: Placeholder
    private let onSidebarWidthChange: ((CGFloat?) -> Void)?
    @State private var adjustedSidebarWidth: CGFloat?
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var isResizeHandleHovered = false

    public init(
        selection: Binding<Selection?>,
        minimumSplitWidth: CGFloat = 820,
        sidebarWidth: CGFloat = 340,
        minimumSidebarWidth: CGFloat = 260,
        maximumSidebarWidth: CGFloat = 460,
        minimumDetailWidth: CGFloat = 420,
        onSidebarWidthChange: ((CGFloat?) -> Void)? = nil,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: @escaping (Selection) -> Detail,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self._selection = selection
        self.minimumSplitWidth = minimumSplitWidth
        self.sidebarWidth = sidebarWidth
        self.minimumSidebarWidth = minimumSidebarWidth
        self.maximumSidebarWidth = maximumSidebarWidth
        self.minimumDetailWidth = minimumDetailWidth
        self.compact = compact()
        self.sidebar = sidebar()
        self.detail = detail
        self.placeholder = placeholder()
        self.onSidebarWidthChange = onSidebarWidthChange
    }

    public var body: some View {
        GeometryReader { geometry in
            if usesSplitLayout(for: geometry.size) {
                let currentSidebarWidth = resolvedSidebarWidth(for: geometry.size)
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: currentSidebarWidth)
                        .frame(maxHeight: .infinity)

                    resizeHandle(currentSidebarWidth: currentSidebarWidth, containerWidth: geometry.size.width)

                    Group {
                        if let selection {
                            detail(selection)
                        } else {
                            placeholder
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transaction { transaction in
                    if dragStartSidebarWidth != nil {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .onAppear {
                    onSidebarWidthChange?(currentSidebarWidth)
                }
                .onChange(of: currentSidebarWidth) { newValue in
                    onSidebarWidthChange?(newValue)
                }
            } else {
                compact
                    .onAppear {
                        onSidebarWidthChange?(nil)
                    }
            }
        }
    }

    private func resizeHandle(currentSidebarWidth: CGFloat, containerWidth: CGFloat) -> some View {
        ZStack {
            Divider()

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(isResizeHandleHovered ? 0.7 : 0.35))
                .frame(width: 3, height: 48)
                .opacity(isResizeHandleHovered ? 1 : 0.65)
        }
        .frame(width: resizeHandleWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
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

    private func usesSplitLayout(for size: CGSize) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom != .phone else { return false }
        #endif
        return size.width >= minimumSplitWidth
    }

    private func resolvedSidebarWidth(for size: CGSize) -> CGFloat {
        clampedSidebarWidth(adjustedSidebarWidth ?? sidebarWidth, containerWidth: size.width)
    }

    private func clampedSidebarWidth(_ proposedWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let availableMaximum = min(
            maximumSidebarWidth,
            max(minimumSidebarWidth, containerWidth - minimumDetailWidth - resizeHandleWidth)
        )
        return min(max(proposedWidth, minimumSidebarWidth), availableMaximum)
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
