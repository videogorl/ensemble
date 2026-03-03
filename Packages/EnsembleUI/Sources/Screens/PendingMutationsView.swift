import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Shows pending and failed offline mutations with retry/delete actions
public struct PendingMutationsView: View {
    @StateObject private var viewModel: PendingMutationsViewModel

    public init() {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makePendingMutationsViewModel()
        )
    }

    public var body: some View {
        List {
            if viewModel.rows.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                ForEach(viewModel.rows) { row in
                    MutationRowView(row: row) {
                        Task { await viewModel.retryMutation(id: row.id) }
                    } onDelete: {
                        Task { await viewModel.deleteMutation(id: row.id) }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Pending Changes")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                clearAllButton
            }
            #else
            ToolbarItem(placement: .automatic) {
                clearAllButton
            }
            #endif
        }
        .task {
            await viewModel.loadMutations()
        }
        .refreshable {
            await viewModel.loadMutations()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No pending changes")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Clear All Button

    @ViewBuilder
    private var clearAllButton: some View {
        if viewModel.hasFailedMutations {
            Button {
                Task { await viewModel.clearAllFailed() }
            } label: {
                Text("Clear Failed")
            }
        }
    }
}

// MARK: - Mutation Row

private struct MutationRowView: View {
    let row: PendingMutationRow
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 24)

            // Description + timestamp
            VStack(alignment: .leading, spacing: 2) {
                Text(row.description)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(row.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if row.status == .failed {
                        Text("Failed")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }

                    if row.retryCount > 0 {
                        Text("\(row.retryCount) retries")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Retry button for failed mutations
            if row.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                // Pending indicator
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var iconName: String {
        switch row.mutationType {
        case .trackRating:
            return "heart"
        case .playlistAdd:
            return "text.badge.plus"
        case .playlistRemove:
            return "text.badge.minus"
        }
    }

    private var iconColor: Color {
        switch row.status {
        case .failed:
            return .red
        case .pending:
            return .accentColor
        }
    }
}
