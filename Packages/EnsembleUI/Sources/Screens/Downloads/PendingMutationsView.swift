import EnsembleDesignTokens
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
            EnsembleToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
        .refreshCommand {
            await viewModel.loadMutations()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EnsembleStateScaffold(
            kind: .empty,
            title: "No pending changes",
            iconSystemName: EnsembleDesign.Icon.checkmarkOutline,
            presentation: .compactFooter
        )
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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Type icon
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: EnsembleScaffold.UtilityRow.statusIconWidth)

            // Description + timestamp
            VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
                Text(row.description)
                    .font(EnsembleDesign.Typography.stateMessage)
                    .lineLimit(2)

                HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                    Text(row.createdAt, style: .relative)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)

                    if row.status == .failed {
                        Text("Failed")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .fontWeight(.medium)
                            .foregroundColor(EnsembleDesign.Color.destructive)
                    }

                    if row.retryCount > 0 {
                        Text("\(row.retryCount) retries")
                            .font(EnsembleDesign.Typography.cardMetadata)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            }

            Spacer()

            // Retry button for failed mutations
            if row.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: EnsembleDesign.Icon.retry)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
                .buttonStyle(.plain)
            } else {
                // Pending indicator
                Image(systemName: EnsembleDesign.Icon.clock)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: EnsembleDesign.Icon.delete)
            }
        }
    }

    private var iconName: String {
        switch row.mutationType {
        case .trackRating, .collectionRating:
            return EnsembleDesign.Icon.favorite
        case .playlistAdd:
            return EnsembleDesign.Icon.addToPlaylist
        case .playlistRemove:
            return EnsembleDesign.Icon.removeFromPlaylist
        case .playlistRename:
            return EnsembleDesign.Icon.edit
        case .playlistDelete:
            return EnsembleDesign.Icon.delete
        case .scrobble:
            return EnsembleDesign.Icon.musicNote
        }
    }

    private var iconColor: Color {
        switch row.status {
        case .failed:
            return EnsembleDesign.Color.destructive
        case .pending:
            return EnsembleDesign.Color.accent
        }
    }
}
