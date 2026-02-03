import EnsembleCore
import SwiftUI

public struct SyncPanelView: View {
    @StateObject private var viewModel: SyncPanelViewModel
    @Environment(\.dismiss) private var dismiss

    public init() {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeSyncPanelViewModel())
    }

    public var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        Task {
                            await viewModel.syncAll()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.accentColor)
                            Text("Sync All Sources")
                            Spacer()
                            if viewModel.isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isSyncing)
                }

                Section("Music Sources") {
                    if viewModel.sources.isEmpty {
                        Text("No music sources configured")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.sources) { source in
                            SourceStatusRow(
                                source: source,
                                status: viewModel.statusFor(source),
                                onSync: {
                                    Task {
                                        await viewModel.syncSource(source)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Sync Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Source Status Row

struct SourceStatusRow: View {
    let source: MusicSource
    let status: MusicSourceStatus
    let onSync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.headline)

                    Text(source.accountName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onSync) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.accentColor)
                }
                .disabled(status.isSyncing)
            }

            // Status indicator
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .syncing(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40)
            }

        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

        case .lastSynced(let date):
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text("Last synced \(timeAgo(date))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

extension MusicSourceStatus {
    var isSyncing: Bool {
        if case .syncing = self {
            return true
        }
        return false
    }
}
