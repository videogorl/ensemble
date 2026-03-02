import EnsembleCore
import SwiftUI

public struct DownloadManagerSettingsView: View {
    @StateObject private var viewModel: DownloadManagerSettingsViewModel

    public init() {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeDownloadManagerSettingsViewModel()
        )
    }

    public var body: some View {
        List {
            Section {
                NavigationLink {
                    OfflineServersView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .frame(width: 24)
                        Text("Servers")
                    }
                }
            } header: {
                Text("Bulk Downloads")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Choose whole libraries to keep synced for offline playback.")
            }

            Section {
                if viewModel.items.isEmpty {
                    Text("No offline items selected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.items) { item in
                        DownloadManagerItemRow(item: item)
                            .standardDeleteSwipeAction {
                                Task {
                                    await viewModel.removeDownload(key: item.key)
                                }
                            }
                    }
                }
            } header: {
                Text("Items")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Albums, artists, and playlists appear here with current offline progress.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Manage Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
}

private struct DownloadManagerItemRow: View {
    let item: DownloadManagerItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundColor(.secondary)
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if item.totalTrackCount > 0 && item.status != .completed {
                ProgressView(value: Double(item.progress))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch item.kind {
        case .album:
            return "square.stack"
        case .artist:
            return "person.2"
        case .playlist:
            return "music.note.list"
        case .library:
            return "music.note.house"
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .pending:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Downloaded"
        case .paused:
            return "Paused"
        case .failed:
            return "Failed"
        }
    }
}
