import EnsembleCore
import SwiftUI

public struct DownloadManagerSettingsView: View {
    @StateObject private var viewModel: DownloadManagerSettingsViewModel
    @Environment(\.dependencies) private var deps
    @AppStorage("downloadQuality") private var downloadQuality = "original"
    @State private var showRemoveAllConfirmation = false

    public init() {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeDownloadManagerSettingsViewModel()
        )
    }

    public var body: some View {
        List {
            Section {
                Picker("Download Quality", selection: $downloadQuality) {
                    qualityOption("Original", tag: "original")
                    qualityOption("High (320 kbps)", tag: "high")
                    qualityOption("Medium (192 kbps)", tag: "medium")
                    qualityOption("Low (128 kbps)", tag: "low")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Downloads")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                if let estimates = viewModel.sizeEstimates {
                    Text("Estimated size at this quality: \(estimates.formattedSize(for: downloadQuality))")
                } else {
                    Text("This matches Settings > Audio Quality > Download Quality.")
                }
            }

            // Size comparison across quality levels
            if let estimates = viewModel.sizeEstimates {
                Section {
                    sizeRow(label: "Current on disk", size: estimates.actualBytes)
                    sizeRow(label: "Original", size: estimates.actualBytes, note: "varies by file")
                    sizeRow(label: "High (320 kbps)", size: estimates.highBytes)
                    sizeRow(label: "Medium (192 kbps)", size: estimates.mediumBytes)
                    sizeRow(label: "Low (128 kbps)", size: estimates.lowBytes)
                } header: {
                    Text("Estimated Size")
                        .foregroundColor(.accentColor)
                        .textCase(nil)
                } footer: {
                    Text("Transcoded quality estimates are approximate. Original quality varies by source file.")
                }
            }

            // Remove all downloads button
            if viewModel.hasDownloads {
                Section {
                    Button(role: .destructive) {
                        showRemoveAllConfirmation = true
                    } label: {
                        Text("Remove All Downloads")
                    }
                } footer: {
                    Text("Removes all downloaded files, targets, and queued items.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .alert("Remove All Downloads?", isPresented: $showRemoveAllConfirmation) {
            Button("Remove All", role: .destructive) {
                Task {
                    await viewModel.removeAllDownloads()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all downloaded files and remove all items marked for download. This cannot be undone.")
        }
        .navigationTitle("Manage Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.refresh()
        }
        .onChange(of: downloadQuality) { _ in
            // Stop any in-progress downloads immediately when quality changes
            // so we don't keep downloading at the old quality
            Task {
                await deps.offlineDownloadService.cancelInProgressDownloads()
            }
        }
    }

    // MARK: - Helpers

    private func qualityOption(_ label: String, tag: String) -> some View {
        Text(label).tag(tag)
    }

    private func sizeRow(label: String, size: Int64, note: String? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(formatBytes(size))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
