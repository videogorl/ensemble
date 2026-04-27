import SwiftUI

/// Empty state view shown when no music sources are configured
public struct EmptyLibraryView: View {
    let onAddSource: () -> Void

    public init(onAddSource: @escaping () -> Void) {
        self.onAddSource = onAddSource
    }

    public var body: some View {
        EnsembleStateScaffold(
            kind: .empty,
            title: "No Music Sources",
            message: "Add a Plex server to start listening to your music",
            iconSystemName: EnsembleDesign.Icon.library
        ) {
            Button(action: onAddSource) {
                Label("Add Music Source", systemImage: "plus.circle.fill")
                    .font(EnsembleDesign.Typography.actionLabel)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(EnsembleDesign.Color.accent)
                    .foregroundColor(EnsembleDesign.Color.onAccent)
                    .cornerRadius(EnsembleDesign.Radius.card)
            }
            .padding(.horizontal, EnsembleDesign.Spacing.xxxl)
        }
    }
}
