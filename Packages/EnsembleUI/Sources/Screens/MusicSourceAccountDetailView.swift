import EnsembleCore
import SwiftUI

/// Account-level source detail screen for managing server libraries and sync operations.
public struct MusicSourceAccountDetailView: View {
    @StateObject private var viewModel: MusicSourceAccountDetailViewModel

    public init(accountId: String) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMusicSourceAccountDetailViewModel(accountId: accountId)
        )
    }

    public var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await viewModel.syncEnabledLibraries()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.accentColor)
                        Text("Sync Enabled Libraries")
                        Spacer()
                        if viewModel.isSyncingEnabledLibraries {
                            ProgressView()
                        }
                    }
                }
                .disabled(!viewModel.hasEnabledLibraries || viewModel.isSyncingEnabledLibraries)

                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if viewModel.isAccountMissing {
                Section {
                    Text("This account is no longer available.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(viewModel.sections) { server in
                    Section {
                        if server.libraries.isEmpty {
                            Text("No music libraries found")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(server.libraries) { library in
                                LibrarySyncStatusRow(row: library) {
                                    viewModel.toggleLibrary(library)
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(server.serverName)
                            if let platform = server.serverPlatform {
                                Text("(\(platform))")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.accountIdentifier)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct LibrarySyncStatusRow: View {
    let row: MusicSourceAccountDetailViewModel.LibraryRow
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: row.isEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundColor(row.isEnabled ? .accentColor : .secondary)

                    Text(row.title)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if row.isEnabled {
                EnabledLibraryStatusView(status: row.status ?? MusicSourceStatus())
                    .padding(.leading, 28)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.secondary)
                    Text("Not synced")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EnabledLibraryStatusView: View {
    let status: MusicSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: syncIcon)
                    .foregroundColor(syncColor)
                    .font(.caption)

                Text(syncText)
                    .font(.caption)
                    .foregroundColor(syncColor)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Image(systemName: connectionIcon)
                    .foregroundColor(connectionColor)
                    .font(.caption)

                Text(status.connectionState.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var syncIcon: String {
        switch status.syncStatus {
        case .idle:
            return "checkmark.circle"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .lastSynced:
            return "clock"
        }
    }

    private var syncColor: Color {
        switch status.syncStatus {
        case .idle, .lastSynced:
            return .secondary
        case .syncing:
            return .accentColor
        case .error:
            return .red
        }
    }

    private var syncText: String {
        switch status.syncStatus {
        case .idle:
            return "Ready"
        case .syncing(let progress):
            return "Syncing \(Int(progress * 100))%"
        case .error(let message):
            return message
        case .lastSynced(let date):
            return "Last synced \(timeAgo(date))"
        }
    }

    private var connectionColor: Color {
        switch status.connectionState.statusColor {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .orange:
            return .orange
        case .red:
            return .red
        case .gray:
            return .gray
        }
    }

    private var connectionIcon: String {
        switch status.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .offline, .unknown:
            return "xmark.circle.fill"
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
