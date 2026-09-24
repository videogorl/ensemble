import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Account-level source detail screen for managing server libraries and sync operations.
public struct MusicSourceAccountDetailView: View {
    @StateObject private var viewModel: MusicSourceAccountDetailViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveSourceAlert = false

    public init(accountId: String) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMusicSourceAccountDetailViewModel(accountId: accountId)
        )
    }

    public var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: displayAccountIdentifier) {
            List {
                accountListSections
            }
        } regularContent: {
            accountCardSections
        }
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

    @ViewBuilder
    private var accountListSections: some View {
        if viewModel.pendingMutationCount > 0 {
            Section {
                pendingChangesLink
            }
        }

        if viewModel.isAccountMissing {
            Section {
                Text("This account is no longer available.")
                    .foregroundColor(EnsembleDesign.Color.secondaryText)

                if let error = viewModel.error {
                    Text(error)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.destructive)
                }
            }
        } else {
            if viewModel.isReauthenticationRequired {
                Section {
                    Text("Session expired. Re-authenticate this account to change libraries or sync.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            } else {
                ForEach(viewModel.sections) { server in
                    Section {
                        serverLibraryRows(for: server, cardRows: false)
                    } header: {
                        serverHeader(server)
                    }
                }
            }

            Section {
                syncActionsRows(cardRows: false)
            }

            Section {
                featureLegendContent
                    .padding(.vertical, EnsembleScaffold.UtilityRow.negativeListPadding)
                    .listRowBackground(Color.clear)
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    #endif
            } header: {
                EnsembleUtilitySectionHeader("Legend")
            }

            Section {
                removeSourceButton
            }
        }
    }

    @ViewBuilder
    private var accountCardSections: some View {
        if viewModel.pendingMutationCount > 0 {
            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    pendingChangesLink
                }
            }
        }

        if viewModel.isAccountMissing {
            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    Text("This account is no longer available.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }

                if let error = viewModel.error {
                    EnsembleUtilityCardDivider()
                    EnsembleUtilityCardRow {
                        Text(error)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.destructive)
                    }
                }
            }
        } else {
            if viewModel.isReauthenticationRequired {
                EnsembleUtilityCardSection {
                    EnsembleUtilityCardRow {
                        Text("Session expired. Re-authenticate this account to change libraries or sync.")
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            } else {
                ForEach(viewModel.sections) { server in
                    EnsembleUtilityCardSection {
                        EnsembleUtilityCardRow {
                            serverHeader(server)
                        }

                        EnsembleUtilityCardDivider()

                        serverLibraryRows(for: server, cardRows: true)
                    }
                }
            }

            EnsembleUtilityCardSection {
                syncActionsRows(cardRows: true)
            }

            EnsembleUtilityCardSection("Legend") {
                EnsembleUtilityCardRow {
                    featureLegendContent
                }
            }

            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    removeSourceButton
                }
            }
        }
    }

    private var pendingChangesLink: some View {
        NavigationLink {
            PendingMutationsView()
        } label: {
            PendingChangesRow(count: viewModel.pendingMutationCount)
        }
    }

    private func serverHeader(_ server: MusicSourceAccountDetailViewModel.ServerSection) -> some View {
        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            Text(displayServerName(server.serverName))
            if let platform = server.serverPlatform {
                Text("(\(platform))")
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            Spacer()
            ServerFeatureBadges(section: server)
        }
    }

    @ViewBuilder
    private func serverLibraryRows(
        for server: MusicSourceAccountDetailViewModel.ServerSection,
        cardRows: Bool
    ) -> some View {
        if let scanProgress = viewModel.scanProgressByServer[server.id] {
            utilityRow(cardRows: cardRows) {
                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
                    EnsembleUtilityInlineStatusRow(
                        iconSystemName: EnsembleDesign.Icon.search,
                        text: "Scanning library…",
                        iconColor: EnsembleDesign.Color.accent
                    )
                    ProgressView(value: Double(scanProgress), total: EnsembleScaffold.UtilityRow.percentProgressTotal)
                        .tint(EnsembleDesign.Color.accent)
                }
                .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
            }
        }

        if let refreshError = viewModel.serverLibraryErrors[server.id] {
            utilityRow(cardRows: cardRows) {
                Text(refreshError)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }

        if server.libraries.isEmpty {
            utilityRow(cardRows: cardRows) {
                Text("No music libraries found")
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        } else {
            ForEach(server.libraries) { library in
                utilityRow(cardRows: cardRows) {
                    LibrarySyncStatusRow(row: library) {
                        Task {
                            await viewModel.toggleLibrary(library)
                        }
                    }
                    .disabled(viewModel.isReauthenticationRequired)
                }

                if cardRows && library.id != server.libraries.last?.id {
                    EnsembleUtilityCardDivider()
                }
            }
        }
    }

    @ViewBuilder
    private func syncActionsRows(cardRows: Bool) -> some View {
        utilityRow(cardRows: cardRows) {
            Button {
                Task {
                    await viewModel.syncEnabledLibraries()
                }
            } label: {
                HStack {
                    EnsembleUtilityRowLabel(
                        iconSystemName: EnsembleDesign.Icon.refreshCycle,
                        title: "Force Full Sync",
                        subtitle: "Re-fetch all metadata, even when Plex reports no changes"
                    )
                    Spacer()
                    if viewModel.isSyncingEnabledLibraries {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.hasEnabledLibraries || viewModel.isSyncingEnabledLibraries || viewModel.isReauthenticationRequired)
        }

        if cardRows {
            EnsembleUtilityCardDivider()
        }

        utilityRow(cardRows: cardRows) {
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
        }

        if viewModel.isRefreshingInventory {
            if cardRows {
                EnsembleUtilityCardDivider()
            }
            utilityRow(cardRows: cardRows) {
                HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                    ProgressView()
                    Text("Checking for library updates…")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }

        if let error = viewModel.error {
            if cardRows {
                EnsembleUtilityCardDivider()
            }
            utilityRow(cardRows: cardRows) {
                Text(error)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }
    }

    @ViewBuilder
    private func utilityRow<Content: View>(
        cardRows: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if cardRows {
            EnsembleUtilityCardRow {
                content()
            }
        } else {
            content()
        }
    }

    private var featureLegendContent: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
            featureLegendRow(icon: EnsembleDesign.Icon.ticket, text: "Plex Pass: Higher quality transcoding and lyrics")
            featureLegendRow(icon: EnsembleDesign.Icon.lyrics, text: "Lyrics: Time-synced lyrics via LyricFind")
            featureLegendRow(icon: EnsembleDesign.Icon.infinity, text: "Radio: Sonically similar radio stations")
        }
    }

    private var removeSourceButton: some View {
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

    private func featureLegendRow(icon: String, text: String) -> some View {
        EnsembleUtilityInlineStatusRow(
            iconSystemName: icon,
            text: text,
            iconColor: EnsembleDesign.Color.accent,
            iconFont: EnsembleDesign.Typography.statusBadgeIcon,
            spacing: EnsembleScaffold.UtilityRow.rowSpacing
        )
    }

    private var displayAccountIdentifier: String {
        DemoModeRedaction.accountIdentifier(
            viewModel.accountIdentifier,
            isEnabled: settingsManager.demoModeEnabled
        )
    }

    private func displayServerName(_ serverName: String) -> String {
        DemoModeRedaction.serverName(serverName, isEnabled: settingsManager.demoModeEnabled)
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
                EnabledLibraryStatusView(
                    status: row.status ?? MusicSourceStatus(),
                    expectedTrackCount: row.expectedTrackCount,
                    syncedTrackCount: row.syncedTrackCount
                )
                    .padding(.leading, EnsembleScaffold.UtilityRow.nestedLeadingPadding)
            } else {
                EnsembleUtilityInlineStatusRow(
                    iconSystemName: EnsembleDesign.Icon.removeCircle,
                    text: notSyncedText
                )
                .padding(.leading, EnsembleScaffold.UtilityRow.nestedLeadingPadding)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
    }

    private var notSyncedText: String {
        if let expectedTrackCount = row.expectedTrackCount {
            return "\(MusicSourceAccountFormatters.trackCount(expectedTrackCount)) tracks not synced"
        }
        return "Not synced"
    }
}

private struct EnabledLibraryStatusView: View {
    let status: MusicSourceStatus
    let expectedTrackCount: Int?
    let syncedTrackCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
            EnsembleUtilityInlineStatusRow(
                iconSystemName: syncIcon,
                text: syncText,
                iconColor: syncColor,
                textColor: syncColor,
                lineLimit: 2
            )

            EnsembleUtilityInlineStatusRow(
                iconSystemName: connectionIcon,
                text: connectionText,
                iconColor: connectionColor
            )
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
            if let trackCountText {
                return "Last synced \(timeAgo(date)) • \(trackCountText)"
            }
            return "Last synced \(timeAgo(date))"
        }
    }

    private var trackCountText: String? {
        guard let syncedTrackCount else { return nil }
        let synced = MusicSourceAccountFormatters.trackCount(syncedTrackCount)
        guard let expectedTrackCount, expectedTrackCount > syncedTrackCount else {
            return "\(synced) tracks synced"
        }
        let expected = MusicSourceAccountFormatters.trackCount(expectedTrackCount)
        return "\(synced) of \(expected) tracks synced"
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

private enum MusicSourceAccountFormatters {
    static func trackCount(_ count: Int) -> String {
        trackCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private static let trackCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

/// Compact inline badges for server-level feature availability (Plex Pass, Lyrics, Radio).
private struct ServerFeatureBadges: View {
    let section: MusicSourceAccountDetailViewModel.ServerSection

    var body: some View {
        HStack(spacing: EnsembleScaffold.UtilityRow.detailTextSpacing) {
            if section.plexPassSupport.isSupported {
                EnsembleUtilityIcon(
                    EnsembleDesign.Icon.ticket,
                    font: EnsembleDesign.Typography.statusBadgeIcon,
                    width: EnsembleScaffold.UtilityRow.inlineIconWidth
                )
            }
            if section.lyricsSupport.isSupported {
                EnsembleUtilityIcon(
                    EnsembleDesign.Icon.lyrics,
                    font: EnsembleDesign.Typography.statusBadgeIcon,
                    width: EnsembleScaffold.UtilityRow.inlineIconWidth
                )
            }
            if section.radioSupport.isSupported {
                EnsembleUtilityIcon(
                    EnsembleDesign.Icon.infinity,
                    font: EnsembleDesign.Typography.statusBadgeIcon,
                    width: EnsembleScaffold.UtilityRow.inlineIconWidth
                )
            }
        }
    }
}
