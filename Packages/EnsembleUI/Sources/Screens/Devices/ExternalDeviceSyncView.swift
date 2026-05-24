import EnsembleCore
import SwiftUI

public struct ExternalDeviceSyncView: View {
    @StateObject private var viewModel: ExternalDeviceSyncViewModel
    let selectedDeviceID: String?

    public init(selectedDeviceID: String? = nil) {
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeExternalDeviceSyncViewModel())
        self.selectedDeviceID = selectedDeviceID
    }

    public var body: some View {
        EnsembleUtilityScreenScaffold {
            if let selectedDevice {
                deviceSummary(selectedDevice)
            } else if viewModel.devices.isEmpty {
                EnsembleStateScaffold(
                    kind: .empty,
                    title: "No iPod Connected",
                    message: "Connect a classic iPod that mounts as a disk to sync Plex music.",
                    iconSystemName: EnsembleDesign.Icon.externalDevice
                )
            } else {
                EnsembleUtilityCardSection("Devices") {
                    ForEach(viewModel.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .navigationTitle(selectedDevice?.name ?? "Devices")
        .toolbar {
            EnsembleToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: EnsembleDesign.Icon.refreshCycle)
                }
                .help("Refresh devices")
            }
        }
        .task {
            await viewModel.startMonitoring()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .refreshCommand {
            await viewModel.refresh()
        }
    }

    private var selectedDevice: ExternalDevice? {
        guard let selectedDeviceID else {
            return viewModel.devices.first
        }
        return viewModel.devices.first { $0.id == selectedDeviceID }
    }

    private func deviceSummary(_ device: ExternalDevice) -> some View {
        VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                        Image(systemName: EnsembleDesign.Icon.externalDevice)
                            .foregroundColor(EnsembleDesign.Color.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.headline)
                            Text(statusText(for: device))
                                .font(.subheadline)
                                .foregroundColor(EnsembleDesign.Color.secondaryText)
                        }
                        Spacer()
                        if viewModel.syncingDeviceIDs.contains(device.id) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                EnsembleUtilityCardDivider()

                EnsembleUtilityCardRow {
                    VStack(alignment: .leading, spacing: 6) {
                        capacityHeader(for: device)
                        ProgressView(value: usedCapacityFraction(for: device))
                    }
                }
            }

            if let summary = viewModel.summary(for: device.id) {
                syncSummarySection(summary)
            }

            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    Button {
                        Task { await viewModel.syncNow(deviceID: device.id) }
                    } label: {
                        Label("Sync Now", systemImage: EnsembleDesign.Icon.refreshCycle)
                    }
                    .disabled(viewModel.syncingDeviceIDs.contains(device.id) || !isSupported(device))
                }
            }
        }
    }

    private func deviceRow(_ device: ExternalDevice) -> some View {
        EnsembleUtilityCardRow {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                Image(systemName: EnsembleDesign.Icon.externalDevice)
                    .foregroundColor(EnsembleDesign.Color.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                    Text(statusText(for: device))
                        .font(.caption)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
                Spacer()
            }
        }
    }

    private func syncSummarySection(_ summary: ExternalDeviceSyncSummary) -> some View {
        EnsembleUtilityCardSection("Last Sync") {
            syncMetricRow("Status", value: summary.status)
            syncMetricRow("Imported plays", value: "\(summary.importedPlays)")
            syncMetricRow("Imported ratings", value: "\(summary.importedRatings)")
            syncMetricRow("Imported playlists", value: "\(summary.importedPlaylists)")
            syncMetricRow("Exported tracks", value: "\(summary.exportedTracks)")
            syncMetricRow("Discarded unmapped items", value: "\(summary.discardedItems)")
            if let message = summary.message, !message.isEmpty {
                EnsembleUtilityCardDivider()
                EnsembleUtilityCardRow {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
    }

    private func syncMetricRow(_ title: String, value: String) -> some View {
        EnsembleUtilityCardRow {
            HStack {
                Text(title)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                Spacer()
                Text(value)
            }
        }
    }

    private func capacityHeader(for device: ExternalDevice) -> some View {
        HStack {
            Text("Capacity")
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            Spacer()
            Text("\(formattedBytes(device.totalCapacity - device.freeCapacity)) used of \(formattedBytes(device.totalCapacity))")
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .font(.caption)
    }

    private func statusText(for device: ExternalDevice) -> String {
        switch device.supportState {
        case .supported:
            return device.automaticSyncEnabled ? "Automatic sync enabled" : "Automatic sync disabled"
        case .unsupported(let message):
            return message
        }
    }

    private func isSupported(_ device: ExternalDevice) -> Bool {
        if case .supported = device.supportState {
            return true
        }
        return false
    }

    private func usedCapacityFraction(for device: ExternalDevice) -> Double {
        guard device.totalCapacity > 0 else { return 0 }
        let used = max(device.totalCapacity - device.freeCapacity, 0)
        return min(max(Double(used) / Double(device.totalCapacity), 0), 1)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
