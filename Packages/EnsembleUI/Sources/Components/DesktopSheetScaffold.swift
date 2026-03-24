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
        minWidth: CGFloat = 720,
        minHeight: CGFloat = 560,
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
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}
