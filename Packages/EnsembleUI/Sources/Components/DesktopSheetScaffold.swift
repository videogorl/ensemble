import SwiftUI

/// Shared desktop-oriented sheet scaffold with a title bar and bottom action area.
/// Used on macOS to avoid iOS-style NavigationView/Form modals collapsing into
/// awkward split or table layouts.
public struct DesktopSheetScaffold<Content: View, Footer: View>: View {
    private let title: String
    private let subtitle: String?
    private let minWidth: CGFloat
    private let minHeight: CGFloat
    private let content: Content
    private let footer: Footer

    public init(
        title: String,
        subtitle: String? = nil,
        minWidth: CGFloat = EnsembleScaffold.AccountSetup.macMinimumWidth,
        minHeight: CGFloat = EnsembleScaffold.AccountSetup.macMinimumHeight,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.chipVertical) {
                Text(title)
                    .font(EnsembleDesign.Typography.sectionTitle)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EnsembleDesign.Spacing.xxl)
            .padding(.vertical, EnsembleDesign.Spacing.sheetSectionPadding)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: EnsembleDesign.Spacing.md) {
                Spacer()
                footer
            }
            .padding(.horizontal, EnsembleDesign.Spacing.xl)
            .padding(.vertical, EnsembleDesign.Spacing.md)
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}
