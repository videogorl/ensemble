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
    @ViewBuilder let action: () -> Action

    public init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.iconSystemName = iconSystemName
        self.action = action
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.lg) {
            if kind == .loading {
                ProgressView()
            } else {
                Image(systemName: iconSystemName ?? kind.defaultIcon)
                    .font(EnsembleDesign.Typography.emptyStateIcon)
                    .foregroundColor(EnsembleDesign.Color.placeholderText)
            }

            VStack(spacing: EnsembleDesign.Spacing.sm) {
                Text(title)
                    .font(EnsembleDesign.Typography.stateTitle)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            action()
        }
        .padding(.horizontal, EnsembleDesign.Spacing.xxl)
        .padding(.vertical, EnsembleDesign.Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension EnsembleStateScaffold where Action == EmptyView {
    init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil
    ) {
        self.init(kind: kind, title: title, message: message, iconSystemName: iconSystemName) {
            EmptyView()
        }
    }
}
