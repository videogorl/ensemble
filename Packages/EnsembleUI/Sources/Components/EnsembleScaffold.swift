import SwiftUI

/// Shared adaptive UI patterns that sit above raw design tokens.
public enum EnsembleScaffold {
    public enum BrowseToolbar {
        public static let itemSpacing = EnsembleDesign.Spacing.lg
        public static let activeBadgeSize = EnsembleDesign.Spacing.sm
        public static let activeBadgeOffset = EnsembleDesign.Spacing.xxs
    }

    public enum FilterPresentation {
        public enum Style: Equatable {
            case toolbarPopover
            case sheet
            case inline
        }

        #if os(iOS)
        /// Default filter presentation policy for iOS and iPadOS library browse screens.
        public static func preferredStyle(horizontalSizeClass: UserInterfaceSizeClass?) -> Style {
            if #available(iOS 26.0, *), horizontalSizeClass == .regular {
                return .toolbarPopover
            }
            return .sheet
        }
        #else
        /// Default filter presentation policy for macOS library browse screens.
        public static func preferredStyle() -> Style {
            .toolbarPopover
        }
        #endif
    }

    public enum BrowseSplit {
        public struct Configuration: Equatable {
            public let minimumSplitWidth: CGFloat
            public let sidebarWidth: CGFloat
            public let minimumSidebarWidth: CGFloat
            public let maximumSidebarWidth: CGFloat
            public let minimumDetailWidth: CGFloat
            public let resizeHandleWidth: CGFloat

            public init(
                minimumSplitWidth: CGFloat = EnsembleDesign.Breakpoint.browseSplitMinimumWidth,
                sidebarWidth: CGFloat = 340,
                minimumSidebarWidth: CGFloat = 260,
                maximumSidebarWidth: CGFloat = 460,
                minimumDetailWidth: CGFloat = 420,
                resizeHandleWidth: CGFloat = 12
            ) {
                self.minimumSplitWidth = minimumSplitWidth
                self.sidebarWidth = sidebarWidth
                self.minimumSidebarWidth = minimumSidebarWidth
                self.maximumSidebarWidth = maximumSidebarWidth
                self.minimumDetailWidth = minimumDetailWidth
                self.resizeHandleWidth = resizeHandleWidth
            }

            public static let rootBrowse = Configuration(
                minimumSplitWidth: 720,
                sidebarWidth: 340,
                minimumSidebarWidth: 280,
                maximumSidebarWidth: 420,
                minimumDetailWidth: 360
            )
        }

        public static let coordinateSpaceName = "LargeScreenBrowseSplitView"
    }

    public enum DetailSurface {
        public static let wideHeaderThreshold = EnsembleDesign.Breakpoint.detailWideHeader
        public static let compactHeaderSpacing = EnsembleDesign.Spacing.lg
        public static let wideHeaderSpacing = EnsembleDesign.Spacing.xxl
        public static let metadataSpacing = EnsembleDesign.Spacing.sm
        public static let actionTopPadding = EnsembleDesign.Spacing.xs
        public static let headerPadding = EnsembleDesign.Spacing.lg
        public static let actionVerticalPadding = EnsembleDesign.Spacing.md
        public static let actionCornerRadius = EnsembleDesign.Radius.control
        public static let listCardCornerRadius = EnsembleDesign.Radius.card
        public static let listCardHorizontalPadding = EnsembleDesign.Spacing.lg

        public enum ArtworkShadow {
            public static let color = Color.black.opacity(0.2)
            public static let radius: CGFloat = 20
            public static let x: CGFloat = 0
            public static let y: CGFloat = 10
        }

        public static var listCardBackground: Color {
            EnsembleDesign.Color.groupedSurface
        }
    }

    public enum AuxiliaryWindow {
        public struct Configuration: Equatable {
            public let minWidth: CGFloat
            public let idealWidth: CGFloat
            public let maxWidth: CGFloat
            public let minHeight: CGFloat
            public let idealHeight: CGFloat

            public init(
                minWidth: CGFloat = 380,
                idealWidth: CGFloat = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth,
                maxWidth: CGFloat = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth,
                minHeight: CGFloat,
                idealHeight: CGFloat
            ) {
                self.minWidth = minWidth
                self.idealWidth = idealWidth
                self.maxWidth = maxWidth
                self.minHeight = minHeight
                self.idealHeight = idealHeight
            }

            public static let profile = Configuration(
                minHeight: 560,
                idealHeight: 640
            )

            public static let downloads = Configuration(
                minHeight: 640,
                idealHeight: 720
            )
        }
    }
}

/// Platform-aligned browse toolbar host that keeps the macOS search spacer pattern in one place.
public struct EnsembleBrowseToolbar<Content: View>: ToolbarContent {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    public init(
        isVisible: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isVisible = isVisible
        self.content = content
    }

    public var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            if isVisible {
                HStack(spacing: EnsembleScaffold.BrowseToolbar.itemSpacing) {
                    content()
                }
            }
        }
        #else
        ToolbarItem {
            Spacer()
        }
        ToolbarItem(placement: .primaryActionIfAvailable) {
            if isVisible {
                HStack(spacing: EnsembleScaffold.BrowseToolbar.itemSpacing) {
                    content()
                }
            }
        }
        #endif
    }
}

/// Standard filter button for browse screens, including the active-filter badge treatment.
public struct EnsembleBrowseFilterButton: View {
    let title: String
    let hasActiveFilters: Bool
    let action: () -> Void

    public init(
        title: String = "Filter",
        hasActiveFilters: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.hasActiveFilters = hasActiveFilters
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: EnsembleDesign.Icon.filter)

                if hasActiveFilters {
                    Circle()
                        .fill(EnsembleDesign.Color.destructive)
                        .frame(
                            width: EnsembleScaffold.BrowseToolbar.activeBadgeSize,
                            height: EnsembleScaffold.BrowseToolbar.activeBadgeSize
                        )
                        .offset(
                            x: EnsembleScaffold.BrowseToolbar.activeBadgeOffset,
                            y: -EnsembleScaffold.BrowseToolbar.activeBadgeOffset
                        )
                }
            }
        }
        .accessibilityLabel(title)
    }
}

/// Presents filter UI using the shared platform policy: compact screens keep sheets, while
/// regular-width modern iPadOS and macOS use toolbar popovers.
public struct EnsembleFilterPresentationModifier<PresentedContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let presentedContent: () -> PresentedContent
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(
        isPresented: Binding<Bool>,
        @ViewBuilder presentedContent: @escaping () -> PresentedContent
    ) {
        self._isPresented = isPresented
        self.presentedContent = presentedContent
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        #if os(iOS)
        switch EnsembleScaffold.FilterPresentation.preferredStyle(horizontalSizeClass: horizontalSizeClass) {
        case .toolbarPopover:
            content.popover(isPresented: $isPresented, arrowEdge: .top) {
                presentedContent()
            }
        case .sheet, .inline:
            content.sheet(isPresented: $isPresented) {
                presentedContent()
            }
        }
        #else
        switch EnsembleScaffold.FilterPresentation.preferredStyle() {
        case .toolbarPopover:
            content.popover(isPresented: $isPresented, arrowEdge: .top) {
                presentedContent()
            }
        case .sheet, .inline:
            content.sheet(isPresented: $isPresented) {
                presentedContent()
            }
        }
        #endif
    }
}

public extension View {
    func ensembleFilterPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        modifier(
            EnsembleFilterPresentationModifier(
                isPresented: isPresented,
                presentedContent: content
            )
        )
    }
}

/// Consistent empty/loading/error state used by browse and utility screens.
public struct EnsembleStateScaffold<Action: View>: View {
    public enum Presentation {
        case fullScreen
        case compactFooter

        var outerSpacing: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.lg
            case .compactFooter: return EnsembleDesign.Spacing.md
            }
        }

        var textSpacing: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.sm
            case .compactFooter: return EnsembleDesign.Spacing.xs
            }
        }

        var iconFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.emptyStateIcon
            case .compactFooter: return EnsembleDesign.Typography.mediaPlaceholderIcon
            }
        }

        var titleFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.stateTitle
            case .compactFooter: return .headline
            }
        }

        var messageFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.stateMessage
            case .compactFooter: return .caption
            }
        }

        var topPadding: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.xxxl
            case .compactFooter: return 40
            }
        }

        var bottomPadding: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.xxxl
            case .compactFooter: return EnsembleDesign.Spacing.none
            }
        }
    }

    public enum Kind {
        case empty
        case loading
        case error

        var defaultIcon: String {
            switch self {
            case .empty: return EnsembleDesign.Icon.musicNote
            case .loading: return EnsembleDesign.Icon.musicNote
            case .error: return EnsembleDesign.Icon.error
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String?
    let iconSystemName: String?
    let presentation: Presentation
    @ViewBuilder let action: () -> Action

    public init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        presentation: Presentation = .fullScreen,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.iconSystemName = iconSystemName
        self.presentation = presentation
        self.action = action
    }

    public var body: some View {
        VStack(spacing: presentation.outerSpacing) {
            if kind == .loading {
                ProgressView()
            } else {
                Image(systemName: iconSystemName ?? kind.defaultIcon)
                    .font(presentation.iconFont)
                    .foregroundColor(EnsembleDesign.Color.placeholderText)
            }

            VStack(spacing: presentation.textSpacing) {
                Text(title)
                    .font(presentation.titleFont)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(presentation.messageFont)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            action()
        }
        .padding(.horizontal, EnsembleDesign.Spacing.xxl)
        .padding(.top, presentation.topPadding)
        .padding(.bottom, presentation.bottomPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: presentation == .fullScreen ? .infinity : nil
        )
    }
}

public extension EnsembleStateScaffold where Action == EmptyView {
    init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        presentation: Presentation = .fullScreen
    ) {
        self.init(
            kind: kind,
            title: title,
            message: message,
            iconSystemName: iconSystemName,
            presentation: presentation
        ) {
            EmptyView()
        }
    }
}
