import EnsembleCore
import SwiftUI

public struct DownloadsView: View {
    @StateObject private var viewModel: DownloadsViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    let nowPlayingVM: NowPlayingViewModel

    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeDownloadsViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ZStack {
            downloadContentView

            if viewModel.isLoading && viewModel.items.isEmpty {
                loadingOverlay
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    DownloadManagerSettingsView()
                } label: {
                    Image(systemName: EnsembleDesign.Icon.editPlaylist)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                queueControlButton
            }
            #else
            EnsembleToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
                NavigationLink {
                    DownloadManagerSettingsView()
                } label: {
                    Label("Settings", systemImage: EnsembleDesign.Icon.editPlaylist)
                }
            }

            ToolbarItem(placement: .primaryActionIfAvailable) {
                queueControlButton
            }
            #endif
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .refreshCommand {
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private var downloadContentView: some View {
        #if os(macOS)
        macOSDownloadContent
        #else
        downloadListView
        #endif
    }

    private var downloadListView: some View {
        List {
            // Libraries section — shows each sync-enabled library with toggle + drill-in
            Section {
                if viewModel.librarySummaries.isEmpty {
                    Text(viewModel.librarySummariesPlaceholderText)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                } else {
                    ForEach(viewModel.librarySummaries) { library in
                        libraryRow(for: library)
                    }
                }
            } header: {
                EnsembleUtilitySectionHeader("Libraries")
            } footer: {
                Text("Toggle to enable entire libraries for offline playback. Tap a row to see downloaded tracks.")
            }

            // Pending Changes entry — only when there are queued mutations
            if viewModel.pendingMutationCount > 0 {
                Section {
                    NavigationLink {
                        PendingMutationsView()
                    } label: {
                        PendingChangesRow(count: viewModel.pendingMutationCount)
                    }
                }
            }

            Section {
                if viewModel.items.isEmpty {
                    Text("No offline items selected")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                } else {
                    ForEach(viewModel.items) { item in
                        if let progress = viewModel.removalInProgress[item.key] {
                            // Show removal progress indicator instead of normal row
                            RemovalProgressRow(progress: progress)
                        } else {
                            targetRow(for: item)
                                .standardDeleteSwipeAction {
                                    Task {
                                        await viewModel.removeDownloadTarget(key: item.key)
                                    }
                                }
                        }
                    }
                }
            } header: {
                EnsembleUtilitySectionHeader("Items")
            } footer: {
                Text("Playlists, albums, and artists selected for offline are listed here.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .miniPlayerBottomSpacing()
    }

    #if os(macOS)
    private var macOSDownloadContent: some View {
        EnsembleUtilityScreenScaffold {
            EnsembleUtilityCardSection(
                "Libraries",
                footer: "Toggle to enable entire libraries for offline playback. Open a row to see downloaded tracks."
            ) {
                if viewModel.librarySummaries.isEmpty {
                    EnsembleUtilityCardRow {
                        Text(viewModel.librarySummariesPlaceholderText)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } else {
                    ForEach(viewModel.librarySummaries) { library in
                        macOSLibraryRow(for: library)
                    }
                }
            }

            if viewModel.pendingMutationCount > 0 {
                EnsembleUtilityCardSection {
                    macNavigationRow {
                        PendingMutationsView()
                    } label: {
                        PendingChangesRow(count: viewModel.pendingMutationCount)
                    }
                }
            }

            EnsembleUtilityCardSection(
                "Items",
                footer: "Playlists, albums, and artists selected for offline are listed here."
            ) {
                if viewModel.items.isEmpty {
                    EnsembleUtilityCardRow {
                        Text("No offline items selected")
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } else {
                    ForEach(viewModel.items) { item in
                        if let progress = viewModel.removalInProgress[item.key] {
                            EnsembleUtilityCardRow {
                                RemovalProgressRow(progress: progress)
                            }
                        } else {
                            macOSTargetRow(for: item)
                        }
                    }
                }
            }
        }
        .miniPlayerBottomSpacing()
    }

    private func macOSLibraryRow(for library: LibraryDownloadSummary) -> some View {
        EnsembleUtilityCardRow {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                NavigationLink {
                    LibraryDownloadDetailView(
                        sourceCompositeKey: library.sourceCompositeKey,
                        title: displayLibraryTitle(for: library),
                        nowPlayingVM: nowPlayingVM
                    )
                } label: {
                    HStack {
                        libraryRowLabel(for: library)
                        Spacer()
                        macChevron
                    }
                }
                .buttonStyle(.plain)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.isLibraryEnabled(sourceCompositeKey: library.sourceCompositeKey) },
                        set: { enabled in
                            Task {
                                await viewModel.setLibraryEnabled(
                                    sourceCompositeKey: library.sourceCompositeKey,
                                    title: library.libraryName,
                                    isEnabled: enabled
                                )
                            }
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(libraryDownloadToggleLabel(for: library))
                .accessibilityValue(libraryDownloadToggleValue(for: library))
                .accessibilityHint(libraryDownloadToggleHint(for: library))
                .disabled(!library.canDownload || viewModel.libraryTogglesInProgress.contains(library.sourceCompositeKey))
            }
        }
    }

    @ViewBuilder
    private func macOSTargetRow(for item: DownloadedItemSummary) -> some View {
        EnsembleUtilityCardRow {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                if isTargetNavigable(item) {
                    NavigationLink {
                        destinationView(for: item)
                    } label: {
                        HStack {
                            DownloadedItemRow(item: item, demoModeEnabled: settingsManager.demoModeEnabled)
                            Spacer()
                            macChevron
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    DownloadedItemRow(item: item, demoModeEnabled: settingsManager.demoModeEnabled)
                }

                Button(role: .destructive) {
                    Task {
                        await viewModel.removeDownloadTarget(key: item.key)
                    }
                } label: {
                    Image(systemName: EnsembleDesign.Icon.delete)
                        .foregroundColor(EnsembleDesign.Color.destructive)
                }
                .buttonStyle(.plain)
                .help("Remove download")
            }
        }
    }

    private func macNavigationRow<Destination: View, LabelContent: View>(
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            EnsembleUtilityCardRow {
                HStack {
                    label()
                    Spacer()
                    macChevron
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var macChevron: some View {
        Image(systemName: EnsembleDesign.Icon.chevronRight)
            .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
            .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(EnsembleScaffold.UtilityRow.chevronSubtleOpacity))
            .frame(width: EnsembleScaffold.UtilityRow.chevronLaneWidth, alignment: .trailing)
    }
    #endif

    // MARK: - Library Row

    @ViewBuilder
    private func libraryRow(for library: LibraryDownloadSummary) -> some View {
        // Hidden NavigationLink provides drill-in without rendering a second chevron.
        // The visible row uses a ZStack overlay so the toggle stays interactive
        // while tapping anywhere else navigates.
        ZStack(alignment: .trailing) {
            // Invisible NavigationLink fills the row for tap-to-navigate
            NavigationLink {
                LibraryDownloadDetailView(
                    sourceCompositeKey: library.sourceCompositeKey,
                    title: displayLibraryTitle(for: library),
                    nowPlayingVM: nowPlayingVM
                )
            } label: {
                EmptyView()
            }
            .opacity(EnsembleScaffold.UtilityRow.hiddenNavigationLinkOpacity)

            // Visible row content: label, toggle, then chevron on trailing edge
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                libraryRowLabel(for: library)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.isLibraryEnabled(sourceCompositeKey: library.sourceCompositeKey) },
                        set: { enabled in
                            Task {
                                await viewModel.setLibraryEnabled(
                                    sourceCompositeKey: library.sourceCompositeKey,
                                    title: library.libraryName,
                                    isEnabled: enabled
                                )
                            }
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(libraryDownloadToggleLabel(for: library))
                .accessibilityValue(libraryDownloadToggleValue(for: library))
                .accessibilityHint(libraryDownloadToggleHint(for: library))
                .disabled(!library.canDownload || viewModel.libraryTogglesInProgress.contains(library.sourceCompositeKey))

                // Manual chevron since the hidden NavigationLink won't render one
                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
                    .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(EnsembleScaffold.UtilityRow.chevronSubtleOpacity))
                    .frame(width: EnsembleScaffold.UtilityRow.chevronLaneWidth, alignment: .trailing)
            }
        }
    }

    private func libraryRowLabel(for library: LibraryDownloadSummary) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                // Library icon
                Image(systemName: EnsembleDesign.Icon.libraryBuilding)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(EnsembleDesign.Color.accent)
                    .frame(
                        width: EnsembleScaffold.UtilityRow.compactArtworkDimension,
                        height: EnsembleScaffold.UtilityRow.compactArtworkDimension
                    )
                    .background(EnsembleScaffold.UtilityRow.insetIconBackground)
                    .clipShape(RoundedRectangle(cornerRadius: EnsembleDesign.Radius.compactControl, style: .continuous))

                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
                    Text(displayLibraryTitle(for: library))
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .lineLimit(1)

                    // Track count line
                    Text(libraryTrackCountText(for: library))
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)

                    // Size line
                    Text(librarySizeText(for: library))
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)

                    if !library.canDownload {
                        Text("Downloads unavailable")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            // Toggle-in-progress spinner
            if viewModel.libraryTogglesInProgress.contains(library.sourceCompositeKey) {
                HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Updating...")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }

            // Progress bar when downloading (has an active status and isn't complete)
            if let status = library.status, status != .completed, library.downloadedTrackCount > 0 || status == .downloading || status == .pending {
                ProgressView(value: Double(library.progress))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
    }

    private func libraryTrackCountText(for library: LibraryDownloadSummary) -> String {
        if library.downloadedTrackCount > 0 {
            return "\(library.downloadedTrackCount) of \(library.totalTrackCount) tracks downloaded"
        }
        return "\(library.totalTrackCount) tracks"
    }

    private func librarySizeText(for library: LibraryDownloadSummary) -> String {
        let downloadedSize = MediaFormatters.bytes(library.downloadedBytes)
        let estimatedSize = MediaFormatters.bytes(library.estimatedTotalBytes)

        if library.downloadedTrackCount > 0 {
            return "\(downloadedSize) / ~\(estimatedSize)"
        }
        return "~\(estimatedSize) estimated"
    }

    private func displayLibraryTitle(for library: LibraryDownloadSummary) -> String {
        let serverName = DemoModeRedaction.serverName(
            library.serverName,
            isEnabled: settingsManager.demoModeEnabled
        )
        return "\(serverName): \(library.libraryName)"
    }

    private func libraryDownloadToggleLabel(for library: LibraryDownloadSummary) -> String {
        "\(displayLibraryTitle(for: library)) offline download"
    }

    private func libraryDownloadToggleValue(for library: LibraryDownloadSummary) -> String {
        viewModel.isLibraryEnabled(sourceCompositeKey: library.sourceCompositeKey) ? "On" : "Off"
    }

    private func libraryDownloadToggleHint(for library: LibraryDownloadSummary) -> String {
        if library.canDownload {
            return "Enables or removes offline downloads for this library."
        }
        return "Downloads are unavailable for this library."
    }

    // MARK: - Target Rows

    @ViewBuilder
    private func targetRow(for item: DownloadedItemSummary) -> some View {
        if isTargetNavigable(item) {
            NavigationLink {
                destinationView(for: item)
            } label: {
                DownloadedItemRow(item: item, demoModeEnabled: settingsManager.demoModeEnabled)
            }
        } else {
            DownloadedItemRow(item: item, demoModeEnabled: settingsManager.demoModeEnabled)
        }
    }

    private func isTargetNavigable(_ item: DownloadedItemSummary) -> Bool {
        guard item.ratingKey != nil else { return false }
        switch item.kind {
        case .album, .artist, .playlist:
            return true
        case .library, .favorites:
            return false
        }
    }

    @ViewBuilder
    private func destinationView(for item: DownloadedItemSummary) -> some View {
        DownloadTargetDetailView(summary: item, nowPlayingVM: nowPlayingVM)
    }

    /// Whether any items have non-completed tracks (pending/downloading/paused)
    private var hasActiveDownloads: Bool {
        viewModel.items.contains { $0.status != .completed }
    }

    /// Toolbar button that switches between pause and resume states.
    @ViewBuilder
    private var queueControlButton: some View {
        if !viewModel.items.isEmpty {
            if viewModel.isQueueRunning {
                Button {
                    Task { await viewModel.pauseQueue() }
                } label: {
                    Label("Pause Downloads", systemImage: EnsembleDesign.Icon.pause)
                }
            } else if hasActiveDownloads {
                Button {
                    Task { await viewModel.resumeQueue() }
                } label: {
                    Label("Resume Downloads", systemImage: EnsembleDesign.Icon.play)
                }
            }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: EnsembleDesign.Spacing.md) {
            ProgressView()
            Text("Loading offline items...")
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(EnsembleDesign.Spacing.xl)
        .ensembleMaterial(.floatingControl, cornerRadius: EnsembleDesign.Radius.card)
    }

}

// MARK: - Supporting Row Views

private struct DownloadedItemRow: View {
    let item: DownloadedItemSummary
    let demoModeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                // Album/artist art thumbnail (circle for artists)
                ArtworkView(
                    path: item.thumbPath,
                    sourceKey: item.sourceCompositeKey,
                    ratingKey: item.ratingKey,
                    cacheHint: artworkCacheHint,
                    size: .thumbnail,
                    cornerRadius: item.kind == .artist
                        ? ArtworkCornerRadius.circle(for: EnsembleScaffold.UtilityRow.artworkDimension)
                        : ArtworkCornerRadius.square(for: EnsembleScaffold.UtilityRow.artworkDimension),
                    isResponsive: true
                )
                .frame(
                    width: EnsembleScaffold.UtilityRow.artworkDimension,
                    height: EnsembleScaffold.UtilityRow.artworkDimension
                )

                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
                    Text(item.title)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .lineLimit(1)
                    Text(metadataText)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)

                    if let sourceDisplayText {
                        Text(sourceDisplayText)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(statusText)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(statusColor)
            }

            if item.totalTrackCount > 0 && item.status != .completed {
                ProgressView(value: Double(item.progress))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
    }

    private var sourceDisplayText: String? {
        guard let context = DependencyContainer.shared.accountManager.sourceLibraryContext(for: item.sourceCompositeKey) else {
            return item.sourceDisplayText
        }
        return DemoModeRedaction.sourceDisplaySubtitle(
            serverName: context.serverName,
            libraryTitle: context.libraryTitle,
            accountName: context.accountName,
            isEnabled: demoModeEnabled
        )
    }

    private var metadataText: String {
        let size = MediaFormatters.bytes(item.downloadedBytes)
        if item.totalTrackCount > 0 {
            if item.status == .completed {
                return "\(item.completedTrackCount) \(trackLabel(for: item.completedTrackCount)) \u{2022} \(size)"
            }
            return "\(item.completedTrackCount) of \(item.totalTrackCount) \(trackLabel(for: item.totalTrackCount)) \u{2022} \(size)"
        }
        return "0 tracks \u{2022} \(size)"
    }

    private func trackLabel(for count: Int) -> String {
        count == 1 ? "track" : "tracks"
    }

    private var statusText: String {
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

    private var statusColor: Color {
        switch item.status {
        case .failed:
            return EnsembleDesign.Color.destructive
        case .downloading:
            return EnsembleDesign.Color.accent
        case .paused:
            return EnsembleDesign.Color.warning
        case .pending, .completed:
            return EnsembleDesign.Color.secondaryText
        }
    }

    private var artworkCacheHint: PersistentArtworkCacheHint? {
        guard let kind = PersistentArtworkCacheHint.Kind(item.kind) else { return nil }
        return PersistentArtworkCacheHint(
            ratingKey: item.ratingKey,
            kind: kind,
            sourcePath: item.thumbPath
        )
    }

}

/// Shows a spinner + progress bar while a target is being removed
private struct RemovalProgressRow: View {
    let progress: RemovalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                ProgressView()
                    .frame(
                        width: EnsembleScaffold.UtilityRow.artworkDimension,
                        height: EnsembleScaffold.UtilityRow.artworkDimension
                    )

                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
                    Text("Removing \(progress.targetTitle)...")
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .lineLimit(1)
                    Text("\(progress.completed) of \(progress.total) tracks")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }

                Spacer()
            }

            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
    }
}
