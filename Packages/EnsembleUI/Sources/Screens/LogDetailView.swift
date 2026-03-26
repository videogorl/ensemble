import EnsembleCore
import SwiftUI

/// Displays the full text content of a log session file.
/// Provides a share button to export the log via the system share sheet.
public struct LogDetailView: View {
    let session: LogSession

    @State private var logContent: String = ""
    @State private var isLoading = true

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
                Button {
                    ShareSheetPresenter.present(items: [session.fileURL])
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button {
                    ShareSheetPresenter.present(items: [session.fileURL])
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            #endif
        }
        .task {
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
