import SwiftUI

/// Native macOS auxiliary window shell for Profile, Downloads, and similar tools.
public struct MacAuxiliaryWindowScaffold<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let minWidth: CGFloat
    private let minHeight: CGFloat
    private let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        minWidth: CGFloat = 720,
        minHeight: CGFloat = 560,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.content = content()
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
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
    }
}
