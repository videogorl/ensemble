import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @State private var adjustedSidebarWidth: CGFloat?
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var dragStartLocationX: CGFloat?
    @State private var isResizeHandleHovered = false

    public init(
        selection: Binding<Selection?>,
        minimumSplitWidth: CGFloat = 820,
        sidebarWidth: CGFloat = 340,
        minimumSidebarWidth: CGFloat = 260,
        maximumSidebarWidth: CGFloat = 460,
        minimumDetailWidth: CGFloat = 420,
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
        #if os(macOS)
        MacLargeScreenBrowseSplitView(
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            maximumSidebarWidth: maximumSidebarWidth,
            minimumDetailWidth: minimumDetailWidth,
            sidebar: AnyView(sidebar),
            detail: AnyView(detailContent)
        )
        #else
        swiftUISplitLayout(for: size)
        #endif
    }

    private func swiftUISplitLayout(for size: CGSize) -> some View {
        let currentSidebarWidth = resolvedSidebarWidth(for: size)
        return HStack(spacing: 0) {
            sidebar
                .frame(width: currentSidebarWidth)
                .frame(maxHeight: .infinity)

            resizeHandle(currentSidebarWidth: currentSidebarWidth, containerWidth: size.width)

            detailContent
        }
        .transaction { transaction in
            if dragStartSidebarWidth != nil {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .coordinateSpace(name: "LargeScreenBrowseSplitView")
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

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.secondary.opacity(isResizeHandleHovered ? 0.7 : 0.35))
                .frame(width: 3, height: 48)
                .opacity(isResizeHandleHovered ? 1 : 0.65)
        }
        .frame(width: resizeHandleWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("LargeScreenBrowseSplitView"))
                .onChanged { value in
                    let startWidth = dragStartSidebarWidth ?? currentSidebarWidth
                    let startLocationX = dragStartLocationX ?? value.location.x
                    let nextWidth = clampedSidebarWidth(
                        startWidth + value.location.x - startLocationX,
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
                            dragStartLocationX = startLocationX
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
                        dragStartLocationX = nil
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

#if os(macOS)
private struct MacLargeScreenBrowseSplitView: NSViewControllerRepresentable {
    let sidebarWidth: CGFloat
    let minimumSidebarWidth: CGFloat
    let maximumSidebarWidth: CGFloat
    let minimumDetailWidth: CGFloat
    let sidebar: AnyView
    let detail: AnyView

    func makeNSViewController(context: Context) -> MacLargeScreenBrowseSplitController {
        MacLargeScreenBrowseSplitController(
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            maximumSidebarWidth: maximumSidebarWidth,
            minimumDetailWidth: minimumDetailWidth
        )
    }

    func updateNSViewController(_ controller: MacLargeScreenBrowseSplitController, context: Context) {
        controller.update(
            sidebar: sidebar,
            detail: detail,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            maximumSidebarWidth: maximumSidebarWidth,
            minimumDetailWidth: minimumDetailWidth
        )
    }
}

private final class MacLargeScreenBrowseSplitController: NSSplitViewController {
    private let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let detailHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var initialSidebarWidth: CGFloat
    private var minimumSidebarWidth: CGFloat
    private var maximumSidebarWidth: CGFloat
    private var minimumDetailWidth: CGFloat
    private var didApplyInitialPosition = false

    init(
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        maximumSidebarWidth: CGFloat,
        minimumDetailWidth: CGFloat
    ) {
        self.initialSidebarWidth = sidebarWidth
        self.minimumSidebarWidth = minimumSidebarWidth
        self.maximumSidebarWidth = maximumSidebarWidth
        self.minimumDetailWidth = minimumDetailWidth
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarHost.view.translatesAutoresizingMaskIntoConstraints = false
        detailHost.view.translatesAutoresizingMaskIntoConstraints = false

        let sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.minimumThickness = minimumSidebarWidth
        sidebarItem.maximumThickness = maximumSidebarWidth
        sidebarItem.holdingPriority = .init(751)

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.canCollapse = false
        detailItem.canCollapseFromWindowResize = false
        detailItem.minimumThickness = minimumDetailWidth
        detailItem.holdingPriority = .init(250)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialDividerPositionIfNeeded()
    }

    func update(
        sidebar: AnyView,
        detail: AnyView,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        maximumSidebarWidth: CGFloat,
        minimumDetailWidth: CGFloat
    ) {
        sidebarHost.rootView = sidebar
        detailHost.rootView = detail

        self.initialSidebarWidth = sidebarWidth
        self.minimumSidebarWidth = minimumSidebarWidth
        self.maximumSidebarWidth = maximumSidebarWidth
        self.minimumDetailWidth = minimumDetailWidth

        if splitViewItems.count >= 2 {
            splitViewItems[0].minimumThickness = minimumSidebarWidth
            splitViewItems[0].maximumThickness = maximumSidebarWidth
            splitViewItems[1].minimumThickness = minimumDetailWidth
        }

        applyInitialDividerPositionIfNeeded()
    }

    private func applyInitialDividerPositionIfNeeded() {
        guard !didApplyInitialPosition, splitView.bounds.width > 0 else { return }
        let maximumPosition = min(
            maximumSidebarWidth,
            max(minimumSidebarWidth, splitView.bounds.width - minimumDetailWidth)
        )
        let position = min(max(initialSidebarWidth, minimumSidebarWidth), maximumPosition)
        splitView.setPosition(position, ofDividerAt: 0)
        didApplyInitialPosition = true
    }
}
#endif

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
