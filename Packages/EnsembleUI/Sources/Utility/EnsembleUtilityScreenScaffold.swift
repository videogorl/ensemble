import SwiftUI

/// Shared shell for menu-like utility screens such as Profile and Downloads.
/// iOS callers can keep native grouped lists, while macOS callers can compose
/// sections as quiet cards that avoid bordered table/list chrome.
public struct EnsembleUtilityScreenScaffold<Content: View>: View {
    private let title: String?
    private let content: Content

    public init(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityScreen.sectionSpacing) {
                if let title {
                    Text(title)
                        .font(EnsembleDesign.Typography.sectionTitle)
                        .foregroundColor(EnsembleDesign.Color.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                content
            }
            .frame(maxWidth: EnsembleScaffold.UtilityScreen.contentMaxWidth, alignment: .topLeading)
            .padding(.horizontal, EnsembleScaffold.UtilityScreen.outerHorizontalPadding)
            .padding(.vertical, EnsembleScaffold.UtilityScreen.outerVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(EnsembleScaffold.AuxiliaryWindow.backgroundColor)
    }
}

/// Adaptive wrapper for utility screens that should keep grouped-list chrome on iOS
/// and quiet card sections inside macOS auxiliary windows.
public struct EnsembleAdaptiveUtilityScaffold<CompactContent: View, RegularContent: View>: View {
    private let title: String
    private let compactContent: CompactContent
    private let regularContent: RegularContent

    public init(
        title: String,
        @ViewBuilder compactContent: () -> CompactContent,
        @ViewBuilder regularContent: () -> RegularContent
    ) {
        self.title = title
        self.compactContent = compactContent()
        self.regularContent = regularContent()
    }

    public var body: some View {
        #if os(macOS)
        EnsembleUtilityScreenScaffold(title: title) {
            regularContent
        }
        .navigationTitle(title)
        #else
        compactContent
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        #endif
    }
}

/// A macOS-friendly utility section with an optional title and footer.
public struct EnsembleUtilityCardSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    public init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.sm) {
            if let title {
                EnsembleUtilitySectionHeader(title)
                    .padding(.horizontal, EnsembleScaffold.UtilityScreen.sectionHeaderHorizontalPadding)
            }

            VStack(spacing: EnsembleDesign.Spacing.none) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: EnsembleScaffold.UtilityScreen.cardCornerRadius, style: .continuous)
                    .fill(EnsembleScaffold.UtilityScreen.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EnsembleScaffold.UtilityScreen.cardCornerRadius, style: .continuous)
                    .stroke(EnsembleDesign.Color.divider, lineWidth: EnsembleScaffold.UtilityScreen.cardStrokeWidth)
            )

            if let footer {
                Text(footer)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .padding(.horizontal, EnsembleScaffold.UtilityScreen.sectionHeaderHorizontalPadding)
            }
        }
    }
}

/// Standard row padding for macOS utility cards.
public struct EnsembleUtilityCardRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, EnsembleScaffold.UtilityScreen.rowHorizontalPadding)
            .padding(.vertical, EnsembleScaffold.UtilityScreen.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Divider aligned with utility row content in card sections.
public struct EnsembleUtilityCardDivider: View {
    public init() {}

    public var body: some View {
        Divider()
            .padding(.leading, EnsembleScaffold.UtilityScreen.dividerLeadingPadding)
    }
}
