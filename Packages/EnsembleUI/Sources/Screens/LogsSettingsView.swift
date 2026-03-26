import EnsembleCore
import SwiftUI

/// Settings sub-view for managing persistent session logs.
/// Shows a toggle to enable/disable logging, a list of saved session files
/// with swipe-to-delete, and navigation to view individual log contents.
public struct LogsSettingsView: View {
    @ObservedObject private var logService = DependencyContainer.shared.persistentLogService
    @State private var isLoggingEnabled: Bool = UserDefaults.standard.bool(forKey: "persistentLoggingEnabled")

    public init() {}

    public var body: some View {
        List {
            // Toggle section
            Section {
                Toggle(isOn: $isLoggingEnabled) {
                    HStack {
                        Image(systemName: "text.badge.checkmark")
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Persistent Logging")
                            Text("When enabled, app logs are saved each session. Useful for diagnosing issues.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: isLoggingEnabled) { newValue in
                    logService.isEnabled = newValue
                }
            }

            // Sessions list
            Section {
                if logService.sessions.isEmpty {
                    Text("No log sessions yet.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(logService.sessions) { session in
                        NavigationLink {
                            LogDetailView(session: session)
                        } label: {
                            LogSessionRow(session: session)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            guard logService.sessions.indices.contains(index) else { continue }
                            logService.deleteSession(logService.sessions[index])
                        }
                    }
                }
            } header: {
                Text("Sessions")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            }

            // Delete All button (only when sessions exist)
            if !logService.sessions.isEmpty {
                Section {
                    Button(role: .destructive) {
                        logService.deleteAllSessions()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .frame(width: 44)
                            Text("Delete All Sessions")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            logService.loadSessions()
        }
    }
}

// MARK: - Session Row

/// A single row displaying a log session's date and file size.
private struct LogSessionRow: View {
    let session: LogSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedDate)
                .font(.body)
            Text(formattedSize)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.date)
    }

    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: session.fileSize)
    }
}
