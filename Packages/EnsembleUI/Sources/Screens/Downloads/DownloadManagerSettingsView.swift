import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct DownloadManagerSettingsView: View {
    @State private var viewModel: DownloadManagerSettingsViewModel
    @Environment(DependencyContainer.self) private var deps
    @AppStorage(AudioQualityPreference.downloadQualityKey)
    private var downloadQuality = AudioQualityPreference.defaultDownloadQuality
    @AppStorage(DownloadSettingsPreference.allowCellularDownloadsKey)
    private var allowCellularDownloads = DownloadSettingsPreference.defaultAllowCellularDownloads
    @State private var showRemoveAllConfirmation = false

    public init(dependencies: DependencyContainer) {
        self._viewModel = State(initialValue: DownloadManagerSettingsViewModel(
            offlineDownloadService: dependencies.offlineDownloadService,
            targetRepository: dependencies.offlineDownloadTargetRepository,
            downloadManager: dependencies.downloadManager
        ))
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
                    .foregroundColor(EnsembleDesign.Color.accent)
                    .textCase(nil)
            } footer: {
                Text("Applies to new downloads. Use Redownload at Current Quality on a downloaded item to replace its files.")
                if let estimates = viewModel.sizeEstimates {
                    Text("Estimated size at this quality: \(estimates.formattedSize(for: downloadQuality))")
                } else {
                    Text("This matches Settings > Audio Quality > Download Quality.")
                }
            }

            // Network policy
            Section {
                Toggle("Allow Downloading on Cellular", isOn: $allowCellularDownloads)
            } footer: {
                Text("When enabled, downloads will proceed over cellular data. This may use significant data.")
            }

            // Size comparison across quality levels
            if let estimates = viewModel.sizeEstimates {
                Section {
                    sizeRow(label: "Current on disk", size: estimates.actualBytes)
                    sizeRow(label: "Original", size: estimates.highBytes, note: estimates.formattedSize(for: "original"))
                    sizeRow(label: "High (320 kbps)", size: estimates.highBytes)
                    sizeRow(label: "Medium (192 kbps)", size: estimates.mediumBytes)
                    sizeRow(label: "Low (128 kbps)", size: estimates.lowBytes)
                } header: {
                    Text("Estimated Size")
                        .foregroundColor(EnsembleDesign.Color.accent)
                        .textCase(nil)
                } footer: {
                    Text("Estimates are based on downloaded content. Original quality varies by source file.")
                }
            }

            if viewModel.replacementCount > 0 {
                Section {
                    Button("Cancel File Replacements (\(viewModel.replacementCount))") {
                        Task { await viewModel.cancelReplacements() }
                    }
                } footer: {
                    Text("Keeps the existing downloaded files. New downloads remain queued.")
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
        .miniPlayerBottomSpacing()
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
            viewModel.start()
            await viewModel.refresh()
        }
        .onChange(of: allowCellularDownloads) { _ in
            // Re-evaluate whether the queue should run based on new network policy
            Task {
                await deps.offlineDownloadService.reevaluateQueuePolicy()
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
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            } else {
                Text(MediaFormatters.bytes(size))
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }
}
