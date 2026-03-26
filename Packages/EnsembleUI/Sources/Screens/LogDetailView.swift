import EnsembleCore
import SwiftUI

/// Displays the full text content of a log session file.
/// Provides share and refresh buttons. The refresh button flushes
/// the log writer then reloads the file from disk so you can watch
/// a live session grow.
public struct LogDetailView: View {
    let session: LogSession

    @State private var logContent: String = ""
    @State private var isLoading = true

    private let logService = DependencyContainer.shared.persistentLogService

    public init(session: LogSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView("Loading log...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if logContent.isEmpty {
                VStack {
                    Text("Log file is empty.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(formattedDate)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        refreshLogContent()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        ShareSheetPresenter.present(items: [session.fileURL])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        refreshLogContent()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        ShareSheetPresenter.present(items: [session.fileURL])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            #endif
        }
        .task {
            loadLogContent()
        }
    }

    /// Flush buffered writes then reload the file, showing a brief spinner.
    private func refreshLogContent() {
        isLoading = true
        // Flush the writer so any buffered lines hit disk before we read
        logService.flushSession()
        // Small delay lets the async flush complete before the synchronous read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            loadLogContent()
        }
    }

    /// Load the log file content from disk.
    private func loadLogContent() {
        do {
            logContent = try String(contentsOf: session.fileURL, encoding: .utf8)
        } catch {
            logContent = "Failed to load log file: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.date)
    }
}
