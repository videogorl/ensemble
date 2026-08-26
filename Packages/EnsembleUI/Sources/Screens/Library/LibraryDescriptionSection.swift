import EnsembleDesignTokens
import SwiftUI

struct LibraryDescriptionSection: View {
    let summary: String
    @Binding var isExpanded: Bool
    let spacing: CGFloat

    init(
        summary: String,
        isExpanded: Binding<Bool>,
        spacing: CGFloat = EnsembleDesign.Spacing.sm
    ) {
        self.summary = summary
        _isExpanded = isExpanded
        self.spacing = spacing
    }

    private var paragraphs: [String] {
        summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canExpand: Bool {
        paragraphs.count > 1 || summary.count > 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("Description")
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            descriptionText
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleExpansion()
                }

            if canExpand {
                Button {
                    toggleExpansion()
                } label: {
                    Text(isExpanded ? "Show less" : "Read more")
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .fontWeight(.medium)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionText: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            if isExpanded {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .foregroundColor(EnsembleDesign.Color.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            .top,
                            index == paragraphs.indices.lowerBound
                                ? EnsembleDesign.Spacing.none
                                : EnsembleDesign.Spacing.md
                        )
                }
            } else {
                Text(paragraphs.first ?? summary)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleExpansion() {
        isExpanded.toggle()
    }
}
