import EnsembleCore
import SwiftUI

/// Displays log session content using lazy line-by-line rendering.
/// Loads the most recent lines first (tail) and lets the user load
/// earlier content on demand. File I/O happens off the main thread
/// to avoid freezing the UI on large logs.
public struct LogDetailView: View {
    let session: LogSession

    /// How many lines to show per chunk when loading earlier content.
    private static let chunkSize = 2000

    // All lines from the file, in order. Populated off the main thread.
    @State private var allLines: [String] = []
    // How many lines (from the tail) are currently visible.
    @State private var visibleLineCount: Int = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var scrollTarget: String?

    private let logService = DependencyContainer.shared.persistentLogService

    public init(session: LogSession) {
        self.session = session
    }

    /// The slice of lines currently rendered (most recent chunk first load,
    /// expanding toward the top as the user taps "Load earlier").
    private var visibleLines: ArraySlice<String> {
        let total = allLines.count
        guard total > 0 else { return [] }
        let start = max(total - visibleLineCount, 0)
        return allLines[start..<total]
    }

    private var hasMoreLines: Bool {
        visibleLineCount < allLines.count
    }

    private var hiddenLineCount: Int {
        max(allLines.count - visibleLineCount, 0)
    }

    public var body: some View {
        Group {
            if isLoading {
                EnsembleStateScaffold(kind: .loading, title: "Loading log…")
            } else if let error = loadError {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Couldn’t load log",
                    message: error
                )
            } else if allLines.isEmpty {
                EnsembleStateScaffold(
                    kind: .empty,
                    title: "Log file is empty",
                    iconSystemName: EnsembleDesign.Icon.settings
                )
            } else {
                logContentView
            }
        }
        .navigationTitle(formattedDate)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                toolbarButtons
            }
            #else
            ToolbarItem { Spacer() }
            ToolbarItem(placement: .primaryActionIfAvailable) {
                toolbarButtons
            }
            #endif
        }
        .task {
            await loadLogContent()
        }
    }

    // MARK: - Subviews

    private var logContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // "Load earlier" button when there are more lines above
                    if hasMoreLines {
                        Button {
                            loadMoreLines()
                        } label: {
                            Text("\(hiddenLineCount) earlier lines — tap to load more")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }

                    // Render visible lines lazily — only on-screen lines are laid out
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, TrackListLayoutMetrics.rowInterItemSpacing)
                            .padding(.vertical, 1)
                            .id("line-\(allLines.count - visibleLineCount + index)")
                    }
                }
            }
            .onChange(of: scrollTarget) { target in
                guard let target = target else { return }
                withAnimation(.none) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
                scrollTarget = nil
            }
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Button {
                Task { await refreshLogContent() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            Button {
                shareLogFile()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Sharing

    /// Flush buffered writes, copy to a temp file, and share the copy.
    /// Sharing the original file URL directly can cause iOS file coordination
    /// to interfere with the active log writer, potentially making the original
    /// inaccessible until the share completes.
    private func shareLogFile() {
        logService.flushSession()
        let sourceURL = session.fileURL
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(sourceURL.lastPathComponent)

        // Remove stale temp copy if present
        try? FileManager.default.removeItem(at: tempURL)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            ShareSheetPresenter.present(items: [tempURL])
        } catch {
            // Fall back to sharing the original if copy fails
            ShareSheetPresenter.present(items: [sourceURL])
        }
    }

    // MARK: - Loading

    /// Read the file off the main thread, split into lines, show the tail.
    private func loadLogContent() async {
        isLoading = true
        loadError = nil

        let url = session.fileURL
        let result: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                return .success(lines)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let lines):
            allLines = lines
            // Show the tail initially — most recent entries are most relevant
            visibleLineCount = min(lines.count, Self.chunkSize)
            isLoading = false
            // Scroll to the very bottom after a brief layout pass
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                scrollTarget = "line-\(allLines.count - 1)"
            }
        case .failure(let error):
            loadError = "Failed to load log file: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Flush buffered writes then reload the file.
    private func refreshLogContent() async {
        logService.flushSession()
        // Brief pause lets the async flush hit disk before the read
        try? await Task.sleep(nanoseconds: 50_000_000)
        await loadLogContent()
    }

    /// Expand the visible window toward the top of the file.
    private func loadMoreLines() {
        visibleLineCount = min(visibleLineCount + Self.chunkSize, allLines.count)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.date)
    }
}
