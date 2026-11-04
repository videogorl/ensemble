import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ArtistBrowseControls: View {
    @Bindable var libraryVM: LibraryViewModel
    private let artistSnapshotCache: BrowseSnapshotCache<ArtistBrowseSnapshot>

    init(libraryVM: LibraryViewModel) {
        self.libraryVM = libraryVM
        self.artistSnapshotCache = libraryVM.artistBrowse
    }

    var body: some View {
        if artistSnapshotCache.snapshot.hasVisibleContent || !libraryVM.artists.isEmpty {
            LibraryFilterButton(
                title: "Filter Artists",
                hasActiveFilters: libraryVM.artistsFilterOptions.hasActiveFilters
            ) {
                FilterSheet(
                    filterOptions: $libraryVM.artistsFilterOptions,
                    availableGenres: artistSnapshotCache.snapshot.availableGenres,
                    showGenreFilter: true
                )
            }
            EnsembleBrowseSortMenu(
                model: libraryVM,
                options: ArtistSortOption.allCases,
                option: \.artistSortOption,
                filterOptions: \.artistsFilterOptions
            )
            .accessibilityLabel("Sort Artists")
        }
    }
}

public struct ArtistsView: View {
    public enum PresentationMode {
        case compactRoot
        case selectionColumn
    }

    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedArtist: Binding<DisplayArtist?>?
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @State private var localSelectedArtist: DisplayArtist?
    private let artistSnapshotCache: BrowseSnapshotCache<ArtistBrowseSnapshot>

    private var artistFilterOptions: Binding<FilterOptions> {
        Binding(
            get: { libraryVM.artistsFilterOptions },
            set: { libraryVM.artistsFilterOptions = $0 }
        )
    }

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        presentationMode: PresentationMode = .compactRoot,
        selectedArtist: Binding<DisplayArtist?>? = nil
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.artistSnapshotCache = libraryVM.artistBrowse
        self.presentationMode = presentationMode
        self.externalSelectedArtist = selectedArtist
    }

    public var body: some View {
        LibraryBrowseScreen(
            title: "Artists",
            loadingTitle: "Loading artists…",
            state: LibraryBrowseState(isLoading: artistSnapshot.phase != .idle, hasContent: hasLibraryContent),
            empty: LibraryBrowseEmptyState(
                title: "No Artists",
                icon: EnsembleDesign.Icon.artists,
                recovery: libraryVM.emptyStateRecovery(message: "No artists found in enabled libraries")
            ),
            search: LibraryBrowseSearch(
                text: artistFilterOptions.searchText,
                prompt: "Filter artists",
                isVisible: !isMacBrowsePicker
            ),
            usesToolbarMaterial: selectedArtist == nil,
            controlsVisible: isBrowseToolbarVisible && !isMacBrowsePicker,
            refresh: { await libraryVM.refreshFromServer() },
            controls: { ArtistBrowseControls(libraryVM: libraryVM) },
            content: { rootContent }
        )
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            adaptiveArtistView
        case .selectionColumn:
            if #available(iOS 18.0, macOS 15.0, *) {
                nativeArtistSelectionList
            } else {
                artistSelectionList
            }
        }
    }

    private var selectedArtist: DisplayArtist? {
        externalSelectedArtist?.wrappedValue ?? localSelectedArtist
    }

    private var artistSnapshot: ArtistBrowseSnapshot {
        artistSnapshotCache.snapshot
    }

    private var isBrowseToolbarVisible: Bool {
        hasLibraryContent &&
        navigationCoordinator.pathSnapshot(for: .artists).isEmpty &&
        !navigationCoordinator.isRouteTransitionActive(for: .artists)
    }

    private func setSelectedArtist(_ artist: DisplayArtist?) {
        if let externalSelectedArtist {
            externalSelectedArtist.wrappedValue = artist
        } else {
            localSelectedArtist = artist
        }
    }

    private var selectedArtistBinding: Binding<DisplayArtist?> {
        Binding(
            get: { selectedArtist },
            set: { setSelectedArtist($0) }
        )
    }

    private var adaptiveArtistView: some View {
        LargeScreenBrowseSplitView(
            selection: selectedArtistBinding,
            configuration: .rootBrowse,
            compact: {
                artistListView
            },
            sidebar: {
                artistSelectionList
            },
            detail: { displayArtist in
                DisplayArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM)
                    .id(displayArtist.id)
            },
            placeholder: {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.artist, title: "Select an Artist")
            }
        )
    }

    private var isMacBrowsePicker: Bool {
        #if os(macOS)
        presentationMode == .selectionColumn
        #else
        false
        #endif
    }

    @available(iOS 18.0, macOS 15.0, *)
    private var nativeArtistSelectionList: some View {
        NativeBrowseScrollView {
            artistGenreChipBar
            if libraryVM.artistSortOption == .name {
                ForEach(artistSnapshot.sections) { section in
                    Section {
                        ForEach(section.artists) { artist in
                            artistSelectionRow(artist)
                        }
                    } header: {
                        EnsembleBrowseSectionHeader(section.letter).id(section.letter)
                    }
                }
            } else {
                ForEach(artistSnapshot.displayArtists) { artist in
                    artistSelectionRow(artist)
                }
            }
            LibraryBrowseCountFooter(
                count: artistSnapshot.displayArtists.count,
                singular: "artist", plural: "artists",
                bottomClearance: TrackListLayoutMetrics.miniPlayerBottomSpacing
            )
        }
        .accessibilityIdentifier("browse.artists")
    }

    private var artistSelectionList: some View {
        artistScroll { artists in
            ForEach(artists) { artistSelectionRow($0) }
        }
    }

    private func artistScroll<Group: View>(
        @ViewBuilder group: @escaping ([DisplayArtist]) -> Group
    ) -> some View {
        LibraryIndexedScroll(
            sections: artistSnapshot.sections,
            items: artistSnapshot.displayArtists,
            singular: "artist",
            plural: "artists",
            isSectioned: libraryVM.artistSortOption == .name,
            showsIndex: presentationMode == .compactRoot && libraryVM.artistSortOption == .name,
            chipBar: AnyView(artistGenreChipBar),
            group: group
        )
    }

    private func artistSelectionRow(_ displayArtist: DisplayArtist) -> some View {
        DisplayArtistRow(displayArtist: displayArtist) {
            setSelectedArtist(displayArtist)
        }
        .padding(.horizontal, EnsembleScaffold.BrowseSelection.horizontalPadding)
        .padding(.vertical, EnsembleScaffold.BrowseSelection.verticalPadding)
        .browseSelectionBackground(isSelected: selectedArtist?.id == displayArtist.id)
        .padding(.horizontal, EnsembleScaffold.BrowseSelection.outerHorizontalPadding)
        .id(displayArtist.id)
    }

    private var hasLibraryContent: Bool {
        artistSnapshot.hasVisibleContent || !libraryVM.artists.isEmpty
    }

    private var artistListView: some View {
        artistScroll { artists in
            DisplayArtistGrid(artists: artists, nowPlayingVM: nowPlayingVM)
        }
    }

    private var artistGenreChipBar: some View {
        GenreFilterHeader(availableGenres: artistSnapshot.availableGenres, filterOptions: artistFilterOptions)
    }
}

private struct DisplayArtistRow: View {
    let displayArtist: DisplayArtist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                ArtworkView(
                    artist: displayArtist.artworkArtist,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.tiny.cgSize.width)
                )

                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                    Text(displayArtist.name)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .lineLimit(1)
                        .foregroundColor(EnsembleDesign.Color.primaryText)

                    if displayArtist.isMerged {
                        Text("\(displayArtist.artists.count) sources")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }

                Spacer()

                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DisplayArtistGrid: View {
    let artists: [DisplayArtist]
    let nowPlayingVM: NowPlayingViewModel
    @Environment(DependencyContainer.self) private var deps
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let columns = EnsembleScaffold.MediaCard.personGridColumns

    var body: some View {
        LazyVGrid(columns: columns, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
            ForEach(artists) { displayArtist in
                artistCardLink(displayArtist)
            }
        }
        .padding(.horizontal)
        .metadataEditorSheet(request: $metadataEditorRequest)
    }

    @ViewBuilder
    private func artistCardLink(_ displayArtist: DisplayArtist) -> some View {
        navigationCoordinator.routeLink(to: .displayArtist(id: displayArtist.id)) {
            artistCardContent(displayArtist)
        }
        .buttonStyle(.plain)
        .contextMenu {
            artistContextMenu(for: displayArtist)
        }
    }

    @ViewBuilder
    private func artistContextMenu(for displayArtist: DisplayArtist) -> some View {
        if !displayArtist.isMerged {
            ArtistActionsContextMenu(
                artist: displayArtist.primaryArtist,
                nowPlayingVM: nowPlayingVM,
                onEditMetadata: { artist in
                    presentArtistMetadataEditor(artist)
                }
            )
        } else {
            MergedArtistHiddenContextMenu(displayArtist: displayArtist)
        }
    }

    private func artistCardContent(_ displayArtist: DisplayArtist) -> some View {
        VStack(spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(
                artist: displayArtist.artworkArtist,
                size: .thumbnail,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width)
            )

            VStack(spacing: EnsembleDesign.Spacing.xs) {
                Text(displayArtist.name)
                    .font(EnsembleDesign.Typography.cardTitle)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                Text(displayArtist.isMerged ? "\(displayArtist.artists.count) sources" : " ")
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .lineLimit(1)
                    .foregroundColor(
                        displayArtist.isMerged ? EnsembleDesign.Color.secondaryText : .clear
                    )
                    .accessibilityHidden(!displayArtist.isMerged)
            }
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
    }

    private func presentArtistMetadataEditor(_ artist: Artist) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
            kind: .artist,
            currentTitle: artist.name
        ) { newTitle in
            do {
                let toast = try await deps.metadataMutationService.editArtist(artist, title: newTitle)
                await MainActor.run {
                    deps.toastCenter.show(toast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationService.editFailureToast(
                            noun: "Artist",
                            itemID: artist.sourceScopedID,
                            error: error,
                            scope: .artist
                        )
                    )
                }
                throw error
            }
        }
    }
}

private struct DisplayArtistDetailView: View {
    let displayArtist: DisplayArtist
    let nowPlayingVM: NowPlayingViewModel
    @Environment(DependencyContainer.self) private var dependencies

    var body: some View {
        ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM, dependencies: dependencies)
    }
}
