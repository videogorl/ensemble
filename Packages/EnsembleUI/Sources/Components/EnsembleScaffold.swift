import SwiftUI

/// Shared adaptive UI patterns that sit above raw design tokens.
public enum EnsembleScaffold {
    public enum Chip {
        public static let horizontalPadding = EnsembleDesign.Spacing.chipHorizontal
        public static let verticalPadding = EnsembleDesign.Spacing.chipVertical
        public static let rowSpacing = EnsembleDesign.Spacing.sm
        public static let barHeight: CGFloat = 36
        public static let clearButtonIconSize: CGFloat = 14
        public static let badgeVerticalPadding: CGFloat = 3
        public static let badgeHorizontalPadding = EnsembleDesign.Spacing.sm
        public static let iconBadgeHorizontalPadding = EnsembleDesign.Spacing.chipVertical
        public static let borderWidth: CGFloat = 1
    }

    public enum MediaCard {
        public static let textSpacing = EnsembleDesign.Spacing.cardTextGap
        public static let contentSpacing = EnsembleDesign.Spacing.sm
        public static let gridSpacing = EnsembleDesign.Spacing.cardGridGap
        public static let rowSpacing = EnsembleDesign.Spacing.cardRowGap
        public static let hubArtworkDimension: CGFloat = 140
        public static let hubShadowY: CGFloat = 3
        public static let horizontalScrollMetadataHeight: CGFloat = 78
        public static let metadataTextHeight: CGFloat = 66
        public static let compactColumnMinimum: CGFloat = 100
        public static let compactColumnMaximum: CGFloat = 140
        public static let shelfColumnMinimum: CGFloat = 140
        public static let shelfColumnMaximum: CGFloat = 180
        public static let prominentColumnMinimum: CGFloat = 136
        public static let prominentColumnMaximum: CGFloat = 172
        public static let personColumnMaximum: CGFloat = 120
        public static let genreGradientTopOpacity = 0.8
        public static let genreGradientBottomOpacity = 0.4
        public static let genreHashMultiplier = 31
        public static let genrePalette: [Color] = [
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo
        ]

        public static var personGridColumns: [GridItem] {
            [
                GridItem(
                    .adaptive(minimum: compactColumnMinimum, maximum: personColumnMaximum),
                    spacing: gridSpacing,
                    alignment: .top
                )
            ]
        }
    }

    public enum Toast {
        public static let iconTextSpacing: CGFloat = 10
        public static let textSpacing = EnsembleDesign.Spacing.xxs
        public static let trailingSpacerMinLength = EnsembleDesign.Spacing.sm
        public static let horizontalPadding: CGFloat = 14
        public static let verticalPadding = EnsembleDesign.Spacing.md
        public static let borderOpacity = 0.4
    }

    public enum ProfileHeader {
        public static let contentSpacing = EnsembleDesign.Spacing.md
        public static let verticalPadding = EnsembleDesign.Spacing.xxl
        public static let imageDimension: CGFloat = 120
        public static let nameSpacing = EnsembleDesign.Spacing.xs
        public static let placeholderOpacity = 0.5
        public static let imageLoadingOpacity = 0.2
    }

    public enum ProfileToolbar {
        public static let imageDimension: CGFloat = 28
    }

    public enum BrowseToolbar {
        public static let itemSpacing = EnsembleDesign.Spacing.lg
        public static let activeBadgeSize = EnsembleDesign.Spacing.sm
        public static let activeBadgeOffset = EnsembleDesign.Spacing.xxs
    }

    public enum BrowseSectionHeader {
        public static let verticalPadding = EnsembleDesign.Spacing.sm
        public static let horizontalPadding = EnsembleDesign.Spacing.lg
        public static let backgroundOpacity = 0.9
    }

    public enum BrowseSelection {
        public static let horizontalPadding = EnsembleDesign.Spacing.lg
        public static let verticalPadding = EnsembleDesign.Spacing.sm
        public static let outerHorizontalPadding = EnsembleDesign.Spacing.sm
        public static let cornerRadius = EnsembleDesign.Radius.compactControl
        public static let fillColor = EnsembleDesign.Material.Role.selection.fallbackBackgroundColor
    }

    public enum Favorites {
        public static let heroIconSize: CGFloat = 80
        public static let heroTopPadding = EnsembleDesign.Spacing.xl
        public static let headerBottomPadding = EnsembleDesign.Spacing.xl
        public static let metadataSpacing = EnsembleDesign.Spacing.xs
    }

    public enum ArtistDetail {
        public static let wideHeaderThreshold: CGFloat = 700
        public static let backgroundHeight: CGFloat = 600
        public static let wideArtworkDimension: CGFloat = 240
        public static let wideActionMaxWidth: CGFloat = 520
        public static let wideHeaderTopPadding: CGFloat = 72
        public static let sectionTopPadding: CGFloat = 32
        public static let loadingTopPadding = TrackListLayoutMetrics.detailHorizontalPadding
        public static let compactActionTopPadding = EnsembleDesign.Spacing.xxl
        public static let metadataSpacing = EnsembleDesign.Spacing.sm
        public static let factsSpacing = EnsembleDesign.Spacing.chipVertical
        public static let descriptionSpacing = EnsembleDesign.Spacing.sm
        public static let aboutSpacing = EnsembleDesign.Spacing.lg
        public static let factLabelWidth: CGFloat = 50
        public static let actionIconDimension = EnsembleScaffold.UtilityRow.iconLaneWidth
        public static let wideArtworkShadowColor = Color.black.opacity(0.18)
        public static let wideArtworkShadowRadius: CGFloat = 18
        public static let wideArtworkShadowY = EnsembleScaffold.UtilityRow.rowSpacing
        public static let placeholderArtworkColor = Color.gray.opacity(0.2)
        public static let darkLegibilityOverlayOpacity = 0.45
        public static let lightLegibilityOverlayOpacity = 0.7
    }

    public enum AccountSetup {
        public static let macMinimumWidth: CGFloat = 720
        public static let macMinimumHeight: CGFloat = 560
        public static let contentMaxWidth: CGFloat = 620
        public static let pinCodeMaxWidth: CGFloat = 320
        public static let rowIconWidth: CGFloat = 44
        public static let iconSize: CGFloat = 60
        public static let pinCodeFontSize: CGFloat = 48
        public static let pinCodeTracking: CGFloat = 8
        public static let contentSpacing = EnsembleDesign.Spacing.xxl
        public static let sectionSpacing = EnsembleDesign.Spacing.lg
        public static let cardSpacing = EnsembleDesign.Spacing.sm
        public static let inlineIconSpacing = EnsembleDesign.Spacing.chipVertical
        public static let cardPadding = EnsembleDesign.Spacing.lg
        public static let horizontalPadding = EnsembleDesign.Spacing.xl
        public static let prominentHorizontalPadding = EnsembleDesign.Spacing.xxxl
        public static let footerVerticalPadding = EnsembleDesign.Spacing.md
        public static let cardCornerRadius = EnsembleDesign.Radius.card
        public static let cardBackground = Color.gray.opacity(0.1)
    }

    public enum UtilityRow {
        public static let iconLaneWidth = EnsembleScaffold.AccountSetup.rowIconWidth
        public static let inlineIconWidth: CGFloat = 14
        public static let statusIconWidth: CGFloat = 24
        public static let compactArtworkDimension: CGFloat = 40
        public static let downloadArtworkDimension: CGFloat = 44
        public static let artworkDimension: CGFloat = 48
        public static let textSpacing = EnsembleDesign.Spacing.xxs
        public static let detailTextSpacing = EnsembleDesign.Spacing.xs
        public static let inlineSpacing = EnsembleDesign.Spacing.chipVertical
        public static let rowSpacing = EnsembleDesign.Spacing.sm
        public static let controlSpacing: CGFloat = 10
        public static let nestedLeadingPadding: CGFloat = iconLaneWidth - EnsembleDesign.Spacing.lg
        public static let tightVerticalPadding = EnsembleDesign.Spacing.xxs
        public static let subtleVerticalPadding = EnsembleDesign.Spacing.xs
        public static let negativeListPadding: CGFloat = -EnsembleDesign.Spacing.xs
        public static let statusChipOpacity = 0.12
        public static let downloadErrorLeadingPadding: CGFloat = downloadArtworkDimension + rowSpacing + EnsembleDesign.Spacing.xs
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
        public static let loadingTopPadding = TrackListLayoutMetrics.detailHorizontalPadding
        public static let collapsedToolbarActionSpacing = EnsembleDesign.Spacing.lg
        public static let compactWideActionThreshold: CGFloat = 300
        public static let stackedWideActionThreshold: CGFloat = 420
        public static let compactWideActionHorizontalPadding: CGFloat = 18
        public static let wideActionHorizontalPadding = EnsembleDesign.Spacing.xxl
        public static let iconActionDimension = EnsembleScaffold.UtilityRow.iconLaneWidth

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

        public static let backgroundColor = EnsembleDesign.Material.Role.sheet.fallbackBackgroundColor
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
        EnsembleToolbarLeadingSpacer()
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

/// Platform-aligned leading toolbar spacer for macOS action groups.
/// SwiftUI's macOS toolbar layout can cluster primary actions near the title or
/// search field unless a flexible toolbar item precedes the action group.
public struct EnsembleToolbarLeadingSpacer: ToolbarContent {
    @Environment(\.isInLargeScreenBrowseDetailPane) private var isInLargeScreenBrowseDetailPane
    private let suppressesInLargeScreenBrowseDetailPane: Bool

    public init(suppressesInLargeScreenBrowseDetailPane: Bool = false) {
        self.suppressesInLargeScreenBrowseDetailPane = suppressesInLargeScreenBrowseDetailPane
    }

    public var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItem {
            if !suppressesInLargeScreenBrowseDetailPane || !isInLargeScreenBrowseDetailPane {
                Spacer()
            }
        }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            EmptyView()
        }
        #endif
    }
}

/// Standalone detail views on macOS need a leading flexible toolbar item so
/// actions align with the trailing edge instead of clustering near the title.
/// Detail panes inside LargeScreenBrowseSplitView already participate in the
/// split's shared toolbar geometry and should not add that spacer.
public struct EnsembleDetailToolbarLeadingSpacer: ToolbarContent {
    public init() {}

    public var body: some ToolbarContent {
        EnsembleToolbarLeadingSpacer(suppressesInLargeScreenBrowseDetailPane: true)
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

/// Standard section header treatment for indexed library browse lists.
public struct EnsembleBrowseSectionHeader: View {
    private let title: String
    private let backgroundColor: Color?

    public init(_ title: String, backgroundColor: Color? = nil) {
        self.title = title
        self.backgroundColor = backgroundColor
    }

    public var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(EnsembleDesign.Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EnsembleScaffold.BrowseSectionHeader.horizontalPadding)
            .padding(.vertical, EnsembleScaffold.BrowseSectionHeader.verticalPadding)
            .background(backgroundColor?.opacity(EnsembleScaffold.BrowseSectionHeader.backgroundOpacity))
    }
}

/// Standard title treatment for content shelves and sections.
public struct EnsembleContentSectionHeader: View {
    private let title: String
    private let showsDisclosure: Bool

    public init(_ title: String, showsDisclosure: Bool = false) {
        self.title = title
        self.showsDisclosure = showsDisclosure
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            if showsDisclosure {
                Spacer()

                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }
}

public extension View {
    func browseSelectionBackground(isSelected: Bool) -> some View {
        background(
            RoundedRectangle(
                cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
                style: .continuous
            )
            .fill(isSelected ? EnsembleScaffold.BrowseSelection.fillColor : Color.clear)
        )
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

/// Shared filled capsule action used inside empty/loading/error states.
public struct EnsembleStateActionLabel: View {
    private let title: String
    private let systemImage: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, EnsembleDesign.Spacing.xl)
            .padding(.vertical, EnsembleDesign.Spacing.compactControlVertical)
            .background(EnsembleDesign.Color.accent)
            .foregroundColor(EnsembleDesign.Color.onAccent)
            .clipShape(Capsule())
    }
}

/// Shared empty-state decision tree for library browse screens that depend on
/// configured music sources, enabled libraries, and sync/cloud-restore state.
public struct EnsembleLibraryEmptyStateScaffold: View {
    public enum Recovery {
        case restoringCloudSources
        case noSources
        case syncing
        case noEnabledLibraries
        case empty(message: String)

        var message: String? {
            switch self {
            case .restoringCloudSources:
                return "Restoring libraries from iCloud…"
            case .noSources:
                return "No music sources connected"
            case .syncing:
                return nil
            case .noEnabledLibraries:
                return "No libraries enabled"
            case .empty(let message):
                return message
            }
        }
    }

    private let title: String
    private let iconSystemName: String
    private let recovery: Recovery
    private let addSource: () -> Void
    private let manageSources: () -> Void

    public init(
        title: String,
        iconSystemName: String,
        recovery: Recovery,
        addSource: @escaping () -> Void,
        manageSources: @escaping () -> Void
    ) {
        self.title = title
        self.iconSystemName = iconSystemName
        self.recovery = recovery
        self.addSource = addSource
        self.manageSources = manageSources
    }

    public var body: some View {
        EnsembleStateScaffold(
            kind: .empty,
            title: title,
            message: recovery.message,
            iconSystemName: iconSystemName
        ) {
            recoveryAction
        }
    }

    @ViewBuilder
    private var recoveryAction: some View {
        switch recovery {
        case .restoringCloudSources:
            VStack(spacing: EnsembleDesign.Spacing.sm) {
                ProgressView()
                Text("This can take a moment on first launch.")
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .multilineTextAlignment(.center)
            }
        case .noSources:
            Button(action: addSource) {
                actionLabel("Add Source", systemImage: EnsembleDesign.Icon.addCircle)
            }
            .buttonStyle(.plain)
        case .syncing:
            HStack(spacing: EnsembleDesign.Spacing.sm) {
                ProgressView()
                Text("Sync in progress…")
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        case .noEnabledLibraries:
            Button(action: manageSources) {
                actionLabel("Manage Sources", systemImage: EnsembleDesign.Icon.editPlaylist)
            }
            .buttonStyle(.plain)
        case .empty:
            EmptyView()
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        EnsembleStateActionLabel(title, systemImage: systemImage)
    }
}
