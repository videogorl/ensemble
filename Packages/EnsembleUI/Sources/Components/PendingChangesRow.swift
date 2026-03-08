import SwiftUI

/// Shared row for navigating to the Pending Mutations screen.
/// Used in both Downloads settings and Music Source Account Detail.
public struct PendingChangesRow: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .frame(width: 24)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pending Changes")
                    .font(.body)
                Text("Offline edits waiting to sync")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}
