import EnsembleCore
import SwiftUI

/// Account-level source detail screen for managing server libraries and sync operations.
public struct MusicSourceAccountDetailView: View {
    @StateObject private var viewModel: MusicSourceAccountDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @State private var showingRemoveSourceAlert = false

    public init(accountId: String) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMusicSourceAccountDetailViewModel(accountId: accountId)
        )
    }

    public var body: some View {
        List {
            // Pending offline mutations — navigate to detail
            if viewModel.pendingMutationCount > 0 {
                Section {
                    NavigationLink {
                        PendingMutationsView()
                    } label: {
                        PendingChangesRow(count: viewModel.pendingMutationCount)
                    }
                }
            }

            if viewModel.isAccountMissing {
                Section {
                    Text("This account is no longer available.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            } else {
                if viewModel.isReauthenticationRequired {
                    Section {
                        Text("Session expired. Re-authenticate this account to change libraries or sync.")
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } else {
                    // Server/library sections
                    ForEach(viewModel.sections) { server in
                        Section {
                            // Show scan progress bar when server is scanning
                            if let scanProgress = viewModel.scanProgressByServer[server.id] {
                                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
                                    HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                                        Image(systemName: EnsembleDesign.Icon.search)
                                            .font(EnsembleDesign.Typography.rowSecondary)
                                            .foregroundColor(EnsembleDesign.Color.accent)
                                        Text("Scanning library…")
                                            .font(EnsembleDesign.Typography.rowSecondary)
                                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                                    }
                                    ProgressView(value: Double(scanProgress), total: EnsembleScaffold.UtilityRow.percentProgressTotal)
                                        .tint(EnsembleDesign.Color.accent)
                                }
                                .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
                            }

                            if let refreshError = viewModel.serverLibraryErrors[server.id] {
                                Text(refreshError)
                                    .font(EnsembleDesign.Typography.rowSecondary)
                                    .foregroundColor(EnsembleDesign.Color.destructive)
                            }

                            if server.libraries.isEmpty {
                                Text("No music libraries found")
                                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                            } else {
                                ForEach(server.libraries) { library in
                                    LibrarySyncStatusRow(row: library) {
                                        Task {
                                            await viewModel.toggleLibrary(library)
                                        }
                                    }
                                    .disabled(viewModel.isReauthenticationRequired)
                                }
                            }
                        } header: {
                            HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                                Text(server.serverName)
                                if let platform = server.serverPlatform {
                                    Text("(\(platform))")
                                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                                }
                                Spacer()
                                ServerFeatureBadges(section: server)
                            }
                        }
                    }
                }

                // Sync buttons
                Section {
                    Button {
                        Task {
                            await viewModel.syncEnabledLibraries()
                        }
                    } label: {
                        HStack {
                            EnsembleUtilityIcon(EnsembleDesign.Icon.refreshCycle)
                            Text("Sync Enabled Libraries")
                            Spacer()
                            if viewModel.isSyncingEnabledLibraries {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!viewModel.hasEnabledLibraries || viewModel.isSyncingEnabledLibraries || viewModel.isReauthenticationRequired)

                    Button {
                        Task {
                            await viewModel.refreshAvailableLibraries()
                        }
                    } label: {
                        HStack {
                            EnsembleUtilityIcon(EnsembleDesign.Icon.retry)
                            Text("Refresh Available Libraries")
                            Spacer()
                            if viewModel.isRefreshingInventory {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isRefreshingInventory || viewModel.isReauthenticationRequired)

                    if viewModel.isRefreshingInventory {
                        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                            ProgressView()
                            Text("Checking for library updates…")
                                .font(EnsembleDesign.Typography.rowSecondary)
                                .foregroundColor(EnsembleDesign.Color.secondaryText)
                        }
                    }

                    if let error = viewModel.error {
                        Text(error)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.destructive)
                    }
                }

                // Feature legend (plain text, no cell styling)
                Section {
                    VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                        featureLegendRow(icon: EnsembleDesign.Icon.ticket, text: "Plex Pass: Higher quality transcoding and lyrics")
                        featureLegendRow(icon: EnsembleDesign.Icon.lyrics, text: "Lyrics: Time-synced lyrics via LyricFind")
                        featureLegendRow(icon: EnsembleDesign.Icon.infinity, text: "Radio: Sonically similar radio stations")
                    }
                    .padding(.vertical, EnsembleScaffold.UtilityRow.negativeListPadding)
                    .listRowBackground(Color.clear)
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    #endif
                } header: {
                    EnsembleUtilitySectionHeader("Legend")
                }

                // Remove source
                Section {
                    Button(role: .destructive) {
                        showingRemoveSourceAlert = true
                    } label: {
                        HStack {
                            Text("Remove Source")
                            Spacer()
                            if viewModel.isRemovingAccount {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isRemovingAccount)
                }
            }
        }
        .navigationTitle(viewModel.accountIdentifier)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .miniPlayerBottomSpacing()
        .alert("Remove Source", isPresented: $showingRemoveSourceAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    let removed = await viewModel.removeSourceAccount()
                    if removed {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This removes the source account and clears synced library data from this source.")
        }
        .task {
            await viewModel.performInitialRefreshIfNeeded()
        }
    }

    private func featureLegendRow(icon: String, text: String) -> some View {
        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            Image(systemName: icon)
                .font(EnsembleDesign.Typography.statusBadgeIcon)
                .foregroundColor(EnsembleDesign.Color.accent)
                .frame(width: EnsembleScaffold.UtilityRow.inlineIconWidth)
            Text(text)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
    }
}

private struct LibrarySyncStatusRow: View {
    let row: MusicSourceAccountDetailViewModel.LibraryRow
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            Button(action: onToggle) {
                HStack(spacing: EnsembleScaffold.UtilityRow.controlSpacing) {
                    Image(systemName: row.isEnabled ? EnsembleDesign.Icon.checkmark : EnsembleDesign.Icon.selectionCircle)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .foregroundColor(row.isEnabled ? EnsembleDesign.Color.accent : EnsembleDesign.Color.secondaryText)

                    Text(row.title)
                        .foregroundColor(EnsembleDesign.Color.primaryText)

                    Spacer()

                    if row.allowSync == true {
                        Image(systemName: EnsembleDesign.Icon.downloaded)
                            .font(EnsembleDesign.Typography.statusBadgeIcon)
                            .foregroundColor(EnsembleDesign.Color.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if row.isEnabled {
                EnabledLibraryStatusView(status: row.status ?? MusicSourceStatus())
                    .padding(.leading, EnsembleScaffold.UtilityRow.nestedLeadingPadding)
            } else {
                HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                    Image(systemName: EnsembleDesign.Icon.removeCircle)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    Text("Not synced")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
                .padding(.leading, EnsembleScaffold.UtilityRow.nestedLeadingPadding)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
    }
}

private struct EnabledLibraryStatusView: View {
    let status: MusicSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
            HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                Image(systemName: syncIcon)
                    .foregroundColor(syncColor)
                    .font(EnsembleDesign.Typography.rowSecondary)

                Text(syncText)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(syncColor)
                    .lineLimit(2)
            }

            HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                Image(systemName: connectionIcon)
                    .foregroundColor(connectionColor)
                    .font(EnsembleDesign.Typography.rowSecondary)

                Text(connectionText)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }

    private var syncIcon: String {
        switch status.syncStatus {
        case .idle:
            return EnsembleDesign.Icon.checkmarkOutline
        case .syncing:
            return EnsembleDesign.Icon.refreshCycle
        case .error:
            return EnsembleDesign.Icon.error
        case .lastSynced:
            return EnsembleDesign.Icon.clock
        }
    }

    private var syncColor: Color {
        switch status.syncStatus {
        case .idle, .lastSynced:
            return EnsembleDesign.Color.secondaryText
        case .syncing:
            return EnsembleDesign.Color.accent
        case .error:
            return EnsembleDesign.Color.destructive
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
            return EnsembleDesign.Color.success
        case .yellow:
            return EnsembleDesign.Color.pending
        case .orange:
            return EnsembleDesign.Color.warning
        case .red:
            if case .unknown = status.connectionState {
                return EnsembleDesign.Color.secondaryText
            }
            return EnsembleDesign.Color.destructive
        case .gray:
            return EnsembleDesign.Color.neutralStatus
        }
    }

    private var connectionIcon: String {
        switch status.connectionState {
        case .connected:
            return EnsembleDesign.Icon.checkmark
        case .connecting:
            return EnsembleDesign.Icon.refreshCycle
        case .degraded:
            return EnsembleDesign.Icon.error
        case .offline:
            return EnsembleDesign.Icon.closeCircle
        case .unknown:
            return EnsembleDesign.Icon.unknown
        }
    }

    private var connectionText: String {
        if case .unknown = status.connectionState {
            return "Checking connection…"
        }
        return status.connectionState.description
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

/// Compact inline badges for server-level feature availability (Plex Pass, Lyrics, Radio).
private struct ServerFeatureBadges: View {
    let section: MusicSourceAccountDetailViewModel.ServerSection

    var body: some View {
        HStack(spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
            if section.hasPlexPass {
                Image(systemName: EnsembleDesign.Icon.ticket)
                    .font(EnsembleDesign.Typography.statusBadgeIcon)
                    .foregroundColor(EnsembleDesign.Color.accent)
            }
            if section.capabilities?.hasLyrics == true {
                Image(systemName: EnsembleDesign.Icon.lyrics)
                    .font(EnsembleDesign.Typography.statusBadgeIcon)
                    .foregroundColor(EnsembleDesign.Color.accent)
            }
            if section.capabilities?.hasRadio == true {
                Image(systemName: EnsembleDesign.Icon.infinity)
                    .font(EnsembleDesign.Typography.statusBadgeIcon)
                    .foregroundColor(EnsembleDesign.Color.accent)
            }
        }
    }
}
