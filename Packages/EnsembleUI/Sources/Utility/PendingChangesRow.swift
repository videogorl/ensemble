import EnsembleDesignTokens
import SwiftUI

/// Shared row for navigating to the Pending Mutations screen.
/// Used in both Downloads settings and Music Source Account Detail.
public struct PendingChangesRow: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Image(systemName: EnsembleDesign.Icon.recentPlaylist)
                .frame(width: EnsembleScaffold.UtilityRow.statusIconWidth)
                .foregroundColor(EnsembleDesign.Color.warning)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text("Pending Changes")
                    .font(EnsembleDesign.Typography.rowPrimary)
                Text("Offline edits waiting to sync")
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }

            Spacer()

            Text("\(count)")
                .font(EnsembleDesign.Typography.cardTitle)
                .foregroundColor(EnsembleDesign.Color.onAccent)
                .padding(.horizontal, EnsembleDesign.Spacing.sm)
                .padding(.vertical, EnsembleDesign.Spacing.xxs)
                .background(EnsembleDesign.Color.warning)
                .clipShape(Capsule())
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
    }
}
