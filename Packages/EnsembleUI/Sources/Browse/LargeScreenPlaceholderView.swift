import EnsembleDesignTokens
import SwiftUI

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
                .font(EnsembleDesign.Typography.mediaPlaceholderIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(0.75))

            Text(title)
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
