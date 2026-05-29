import EnsembleCore
import SwiftUI
import Nuke
#if canImport(UIKit)
import UIKit
#endif

private struct SendableArtistPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

final class ArtistDetailArtworkContinuityStore: ObservableObject {
    var lastImage: PlatformImage?
    var lastBlurredImage: PlatformImage?
    var lastIdentity: String?
}

private struct ArtistDetailArtworkContinuityKey: EnvironmentKey {
    static let defaultValue = ArtistDetailArtworkContinuityStore()
}

extension EnvironmentValues {
    var artistDetailArtworkContinuity: ArtistDetailArtworkContinuityStore {
        get { self[ArtistDetailArtworkContinuityKey.self] }
        set { self[ArtistDetailArtworkContinuityKey.self] = newValue }
    }
}

public struct ArtistsView: View {
    public enum PresentationMode {
        case compactRoot
        case selectionColumn
    }

    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedArtist: Binding<DisplayArtist?>?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showFilterSheet = false
    @State private var localSelectedArtist: DisplayArtist?

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        presentationMode: PresentationMode = .compactRoot,
        selectedArtist: Binding<DisplayArtist?>? = nil
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.presentationMode = presentationMode
        self.externalSelectedArtist = selectedArtist
    }

    public var body: some View {
        Group {
            if artistSnapshot.phase != .idle && !artistSnapshot.hasVisibleContent {
                loadingView
            } else if !artistSnapshot.hasVisibleContent {
                emptyView
            } else {
                rootContent
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $libraryVM.artistsFilterOptions.searchText, prompt: "Filter artists")
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
        .toolbar {
            EnsembleBrowseToolbar(isVisible: isBrowseToolbarVisible) {
                artistFilterButton
                artistSortMenu
            }
        }
        .if(selectedArtist == nil) { view in
            view.toolbarMaterialBackground()
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.artistsFilterOptions,
                availableGenres: artistSnapshot.availableGenres,
                showGenreFilter: true
            )
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            adaptiveArtistView
        case .selectionColumn:
            artistSelectionList
        }
    }

    private var selectedArtist: DisplayArtist? {
        externalSelectedArtist?.wrappedValue ?? localSelectedArtist
    }

    private var artistSnapshot: ArtistBrowseSnapshot {
        libraryVM.immediateArtistBrowseSnapshot
    }

    private var isBrowseToolbarVisible: Bool {
        artistSnapshot.hasVisibleContent &&
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

    private var artistFilterButton: some View {
        EnsembleBrowseFilterButton(
            title: "Filter Artists",
            hasActiveFilters: libraryVM.artistsFilterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
        }
    }

    private var artistSortMenu: some View {
        Menu {
            ForEach(ArtistSortOption.allCases, id: \.self) { option in
                Button {
                    if libraryVM.artistSortOption == option {
                        libraryVM.artistsFilterOptions.sortDirection =
                            libraryVM.artistsFilterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        libraryVM.artistSortOption = option
                        libraryVM.artistsFilterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if libraryVM.artistSortOption == option {
                            Image(systemName: libraryVM.artistsFilterOptions.sortDirection == .ascending
                                  ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
        .accessibilityLabel("Sort Artists")
    }

    private var artistSelectionList: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        artistGenreChipBar

                        if libraryVM.artistSortOption == .name {
                            LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(artistSnapshot.sections) { section in
                                    Section(header: sectionHeader(section.letter)) {
                                        ForEach(section.artists) { displayArtist in
                                            artistSelectionRow(displayArtist)
                                        }
                                    }
                                    .id(section.letter)
                                }
                            }
                            .padding(.vertical)
                        } else {
                            LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(artistSnapshot.displayArtists) { displayArtist in
                                    artistSelectionRow(displayArtist)
                                }
                            }
                            .padding(.vertical)
                        }
                    }
                }
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay {
                    if shouldShowScrollIndex(width: geometry.size.width) {
                        ScrollIndex(
                            letters: artistSnapshot.sections.map { $0.letter },
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .foregroundScrollActivity()
            }
        }
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

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading artists…")
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Artists",
            iconSystemName: EnsembleDesign.Icon.artists,
            recovery: libraryEmptyRecovery(emptyMessage: "No artists found in enabled libraries"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    private func libraryEmptyRecovery(emptyMessage: String) -> EnsembleLibraryEmptyStateScaffold.Recovery {
        if libraryVM.isRestoringCloudSources {
            return .restoringCloudSources
        } else if !libraryVM.hasAnySources {
            return .noSources
        } else if libraryVM.isSyncing {
            return .syncing
        } else if !libraryVM.hasEnabledLibraries {
            return .noEnabledLibraries
        } else {
            return .empty(message: emptyMessage)
        }
    }

    private var artistListView: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        artistGenreChipBar

                        if libraryVM.artistSortOption == .name {
                            LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(artistSnapshot.sections) { section in
                                    Section(header: sectionHeader(section.letter)) {
                                        DisplayArtistGrid(
                                            artists: section.artists,
                                            nowPlayingVM: nowPlayingVM
                                        )
                                        .id(section.letter)
                                    }
                                }
                            }
                            .padding(.vertical)
                        } else {
                            DisplayArtistGrid(
                                artists: artistSnapshot.displayArtists,
                                nowPlayingVM: nowPlayingVM
                            )
                            .padding(.vertical)
                        }
                    }
                }
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay {
                    if shouldShowScrollIndex(width: geometry.size.width) {
                        ScrollIndex(
                            letters: artistSnapshot.sections.map { $0.letter },
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .foregroundScrollActivity()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var artistGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: artistSnapshot.availableGenres,
            selectedGenres: $libraryVM.artistsFilterOptions.selectedGenres,
            excludedGenres: $libraryVM.artistsFilterOptions.excludedGenres
        )
    }

    private func shouldShowScrollIndex(width: CGFloat) -> Bool {
        presentationMode == .compactRoot &&
        libraryVM.artistSortOption == .name &&
        !artistSnapshot.displayArtists.isEmpty &&
        ScrollIndex.isVisible(forContainerWidth: width)
    }

    private func sectionHeader(_ letter: String) -> some View {
        EnsembleBrowseSectionHeader(letter)
    }
}

private struct DisplayArtistRow: View {
    let displayArtist: DisplayArtist
    let onTap: () -> Void

    var body: some View {
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
        .onTapGesture(perform: onTap)
    }
}

private struct DisplayArtistGrid: View {
    let artists: [DisplayArtist]
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let columns = EnsembleScaffold.MediaCard.personGridColumns

    var body: some View {
        LazyVGrid(columns: columns, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
            ForEach(artists) { displayArtist in
                artistCardLink(displayArtist)
            }
        }
        .padding(.horizontal)
        .sheet(item: $metadataEditorRequest) { request in
            TextInputView(
                title: request.kind.title,
                message: "Changes are sent directly to Plex and then refreshed locally.",
                placeholder: request.kind.fieldLabel,
                initialText: request.currentTitle,
                actionTitle: "Save",
                onSubmit: request.onSave
            )
        }
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
                onEditMetadata: {
                    presentArtistMetadataEditor(displayArtist.primaryArtist)
                }
            )
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

                if displayArtist.isMerged {
                    Text("\(displayArtist.artists.count) sources")
                        .font(EnsembleDesign.Typography.cardSubtitle)
                        .lineLimit(1)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
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
                let result = try await deps.metadataMutationWorkflow.editArtist(artist, title: newTitle)
                await MainActor.run {
                    deps.toastCenter.show(result.successToast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationWorkflow.editFailureToast(
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

    var body: some View {
        ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM)
    }
}

// MARK: - Artist Detail View

struct ArtistHeroFrame: Equatable {
    let minY: CGFloat
    let width: CGFloat
}

private struct ArtistHeroFramePreferenceKey: PreferenceKey {
    static var defaultValue: ArtistHeroFrame?

    static func reduce(value: inout ArtistHeroFrame?, nextValue: () -> ArtistHeroFrame?) {
        value = nextValue() ?? value
    }
}

private struct StableArtistArtworkImage<Fallback: View>: View {
    let image: PlatformImage?
    @ViewBuilder let fallback: () -> Fallback

    @State private var currentImage: PlatformImage?

    init(image: PlatformImage?, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.image = image
        self.fallback = fallback
        self._currentImage = State(initialValue: image)
    }

    var body: some View {
        ZStack {
            if currentImage == nil {
                fallback()
            }

            if let currentImage {
                platformImage(currentImage)
            }
        }
        .task(id: imageIdentity) {
            updateImage()
        }
    }

    private var imageIdentity: ObjectIdentifier? {
        image.map(ObjectIdentifier.init)
    }

    @ViewBuilder
    private func platformImage(_ image: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private func updateImage() {
        guard currentImage.map(ObjectIdentifier.init) != imageIdentity else {
            return
        }

        guard let image else {
            return
        }

        currentImage = image
    }
}

public struct ArtistDetailView: View {
    @StateObject private var viewModel: ArtistDetailViewModel
    @StateObject private var mergedViewModel: MergedArtistDetailViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let displayArtist: DisplayArtist
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var dependencies
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    private let pinManager = DependencyContainer.shared.pinManager
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    // Targeted NVM observation: only re-evaluate for track changes and playlist target
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var isArtistPinned: Bool
    @State private var isBioExpanded = false
    @State private var artworkImage: PlatformImage?
    @State private var blurredArtworkImage: PlatformImage?
    @State private var continuityArtworkImage: PlatformImage?
    @State private var compactHeroRestingFrame: ArtistHeroFrame?
    @State private var artworkLoadUnavailable = false
    @State private var currentArtworkLoadIdentity: String?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var showToolbarTitle = false
    @State private var artistHeaderActionWidth: CGFloat = 0
    @State private var favoritedTrackListWidth: CGFloat = 0
    @State private var sourceFavoritedTrackListWidths: [String: CGFloat] = [:]
    @Environment(\.artistDetailArtworkContinuity) private var artistArtworkContinuity
    @Environment(\.openURL) private var openURL

    public init(
        artist: Artist,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.init(displayArtist: .single(artist), nowPlayingVM: nowPlayingVM)
    }

    public init(
        displayArtist: DisplayArtist,
        nowPlayingVM: NowPlayingViewModel
    ) {
        let artist = displayArtist.primaryArtist
        self.displayArtist = displayArtist
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeArtistDetailViewModel(artist: artist))
        self._mergedViewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMergedArtistDetailViewModel(displayArtist: displayArtist)
        )
        self.nowPlayingVM = nowPlayingVM
        let pinnedIdentities = Set(DependencyContainer.shared.pinManager.pinnedItems.map(\.sourceScopedID))
        self._isArtistPinned = State(initialValue: pinnedIdentities.contains(artist.sourceScopedID))
    }

    public var body: some View {
        MediaDetailSurface(
            artworkImage: artworkImage,
            preBlurredArtworkImage: blurredArtworkImage,
            preBlurredArtworkCacheKey: artistBackdropBlurCacheKey,
            artworkContinuityIdentity: displayArtist.id,
            backgroundHeight: EnsembleScaffold.ArtistDetail.backgroundHeight,
            darkLegibilityOpacity: EnsembleScaffold.ArtistDetail.darkLegibilityOverlayOpacity,
            lightLegibilityOpacity: EnsembleScaffold.ArtistDetail.lightLegibilityOverlayOpacity,
            contentBleedsUnderTopChrome: true
        ) {
            artistDetailScrollContent
        }
        .coordinateSpace(name: "artistDetailScroll")
        .collapsingToolbarTitle(
            viewModel.artist.name,
            threshold: 0,
            showToolbarTitle: $showToolbarTitle
        )
        .onPreferenceChange(ArtistHeroFramePreferenceKey.self) { frame in
            updateCompactHeroRestingFrame(frame)
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            EnsembleDetailToolbarActions {
                artistPinMenuButton
            }
        }
        .artworkBackedToolbarBleed(hidesTopScrollEdgeEffect: !showToolbarTitle)
        .miniPlayerBottomSpacing()
        .trackListRuntimeObservation(
            activeDownloadTrackIdentities: $activeDownloadTrackIdentities,
            availabilityGeneration: $availabilityGeneration
        )
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            recentPlaylistTitle: $nvmRecentPlaylistTitle
        )
        .onReceive(pinManager.$pinnedItems) { pinnedItems in
            updateArtistPinState(pinnedItems: pinnedItems)
        }
        .task(id: viewModel.artist.sourceScopedID) {
            async let artworkLoad: () = loadArtworkImage()
            async let albumsLoad: () = viewModel.loadAlbums()
            async let tracksLoad: () = viewModel.loadTracks()
            async let detailLoad: () = viewModel.loadArtistDetail()
            if displayArtist.isMerged {
                await mergedViewModel.load()
            }
            _ = await (artworkLoad, albumsLoad, tracksLoad, detailLoad)
        }
        .task(id: artworkImageIdentity) {
            updateArtworkContinuity()
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private var artistDetailScrollContent: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width

            ScrollView {
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    artistHeader(containerWidth: containerWidth)

                    if displayArtist.isMerged {
                        if mergedViewModel.isLoading && mergedViewModel.sourceSections.isEmpty {
                            ProgressView()
                                .padding(.top, EnsembleScaffold.ArtistDetail.loadingTopPadding)
                        } else if !mergedViewModel.sourceSections.isEmpty {
                            mergedSourceSections
                                .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                        }
                    } else {
                        // Albums Section
                        if viewModel.isLoading && viewModel.albums.isEmpty {
                            ProgressView()
                                .padding(.top, EnsembleScaffold.ArtistDetail.loadingTopPadding)
                        } else if !viewModel.albums.isEmpty {
                            albumsSection
                                .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                        }

                        // Favorited Tracks (4+ stars)
                        if !viewModel.favoritedTracks.isEmpty {
                            favoritedTracksSection
                                .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                        }
                    }

                    // About section (quick facts + bio + Wikipedia)
                    if hasAboutContent {
                        aboutSection
                            .padding(.horizontal)
                            .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                    }

                    // Related Artists (only those in user's library)
                    if !viewModel.resolvedSimilarArtists.isEmpty {
                        relatedArtistsSection(artists: viewModel.resolvedSimilarArtists)
                            .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundScrollActivity()
        }
    }

    private func updateArtistPinState(pinnedItems: [PinnedItem]) {
        let latest = pinnedItems.contains { $0.sourceScopedID == viewModel.artist.sourceScopedID }
        if latest != isArtistPinned {
            isArtistPinned = latest
        }
    }

    /// Toolbar menu with Pin/Unpin action for the artist
    private var artistPinMenuButton: some View {
        let isPinned = isArtistPinned
        let isDownloaded = dependencies.offlineDownloadService.isArtistDownloadEnabled(viewModel.artist)
        let canDownload = DownloadCapabilityPolicy.canAttemptDownload(
            for: viewModel.artist.sourceCompositeKey,
            accountManager: dependencies.accountManager
        )
        let downloadableMergedArtists = mergedDownloadableArtists
        return Menu {
            Button {
                dependencies.pinMutationWorkflow.togglePin(
                    id: viewModel.artist.id,
                    sourceKey: viewModel.artist.sourceCompositeKey ?? "",
                    type: .artist,
                    title: viewModel.artist.name,
                    isPinned: isPinned
                )
            } label: {
                MediaActionLabel(kind: .pin(isPinned: isPinned))
            }

            if displayArtist.isMerged, !downloadableMergedArtists.isEmpty {
                Button {
                    Task {
                        for artist in downloadableMergedArtists {
                            await dependencies.downloadMutationWorkflow.setArtistDownloadEnabled(
                                artist,
                                isEnabled: true
                            )
                        }
                    }
                } label: {
                    MediaActionLabel(kind: .downloadAll)
                }
            } else if canDownload {
                Button {
                    Task {
                        await dependencies.downloadMutationWorkflow.setArtistDownloadEnabled(
                            viewModel.artist,
                            isEnabled: !isDownloaded
                        )
                    }
                } label: {
                    MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                }
            }
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
    }

    private var mergedDownloadableArtists: [Artist] {
        guard displayArtist.isMerged else { return [] }
        return displayArtist.artists.filter { canDownload($0) }
    }

    private var artworkArtist: Artist {
        displayArtist.artworkArtist
    }

    private var artistBackdropBlurCacheKey: String? {
        "\(artworkDescriptor(for: artworkArtist).stableBlurCacheKey)|artist-hero"
    }
    
    private func loadArtworkImage() async {
        let artist = artworkArtist
        let loadIdentity = "\(displayArtist.id)|\(artist.sourceScopedID)"
        let continuityIdentity = displayArtist.id

        await MainActor.run {
            if currentArtworkLoadIdentity != loadIdentity {
                artworkImage = nil
                blurredArtworkImage = nil
                continuityArtworkImage = artistArtworkContinuity.lastIdentity == continuityIdentity
                    ? artistArtworkContinuity.lastImage
                    : nil
            }
            currentArtworkLoadIdentity = loadIdentity
            artworkLoadUnavailable = false
        }

        let descriptor = artworkDescriptor(for: artist)

        guard let resolved = await ArtworkImageResolver.resolvedImage(
            for: descriptor,
            artworkLoader: dependencies.artworkLoader
        ) else {
            await MainActor.run {
                guard currentArtworkLoadIdentity == loadIdentity else { return }
                artworkLoadUnavailable = true
            }
            return
        }

        let heroImage = await Self.artistHeroImage(from: resolved.image)
        await MainActor.run {
            guard currentArtworkLoadIdentity == loadIdentity else { return }
            artworkImage = heroImage
        }

        let blurredImage = await ArtworkImageResolver.preBlurredImage(
            for: heroImage,
            cacheKey: "\(resolved.blurCacheKey)|artist-hero"
        )
        await MainActor.run {
            guard currentArtworkLoadIdentity == loadIdentity else { return }
            blurredArtworkImage = blurredImage
            artistArtworkContinuity.lastBlurredImage = blurredImage
        }
    }

    private func artworkDescriptor(for artist: Artist) -> ArtworkResolutionDescriptor {
        ArtworkResolutionDescriptor(
            path: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey,
            ratingKey: artist.id,
            fallbackPath: artist.fallbackThumbPath,
            fallbackRatingKey: artist.fallbackRatingKey,
            cacheHint: PersistentArtworkCacheHint(artist: artist),
            fallbackCacheHint: PersistentArtworkCacheHint(
                ratingKey: artist.fallbackRatingKey,
                kind: .album,
                sourcePath: artist.fallbackThumbPath
            ),
            size: 1000,
            priority: .high
        )
    }

    private var displayedArtworkImage: PlatformImage? {
        if artworkImage == nil, artworkLoadUnavailable || !hasArtworkCandidate {
            return nil
        }
        if artistArtworkContinuity.lastIdentity == displayArtist.id {
            return continuityArtworkImage ?? artistArtworkContinuity.lastImage ?? artworkImage
        }
        return continuityArtworkImage ?? artworkImage
    }

    private var artworkImageIdentity: ObjectIdentifier? {
        artworkImage.map(ObjectIdentifier.init)
    }

    private var hasArtworkCandidate: Bool {
        artworkArtist.thumbPath?.isEmpty == false || artworkArtist.fallbackThumbPath?.isEmpty == false
    }

    private func updateArtworkContinuity() {
        guard let artworkImage else {
            if continuityArtworkImage == nil {
                continuityArtworkImage = artistArtworkContinuity.lastIdentity == displayArtist.id
                    ? artistArtworkContinuity.lastImage
                    : nil
            }
            return
        }

        if continuityArtworkImage.map(ObjectIdentifier.init) != ObjectIdentifier(artworkImage) {
            continuityArtworkImage = artworkImage
        }
        artistArtworkContinuity.lastImage = artworkImage
        artistArtworkContinuity.lastIdentity = displayArtist.id
    }

    private static func artistHeroImage(from image: PlatformImage) async -> PlatformImage {
        #if os(iOS)
        let sendableImage = SendableArtistPlatformImage(image)
        return await Task.detached(priority: .utility) {
            Self.trimmedArtistHeroImage(from: sendableImage.value)
        }.value
        #else
        return trimmedArtistHeroImage(from: image)
        #endif
    }

    nonisolated private static func trimmedArtistHeroImage(from image: PlatformImage) -> PlatformImage {
        #if os(iOS)
        guard let cgImage = image.cgImage else {
            return image
        }
        let heroImage = transparentTrimmedImage(cgImage) ?? cgImage
        return UIImage(cgImage: heroImage, scale: 1, orientation: image.imageOrientation)
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let heroImage = transparentTrimmedImage(cgImage) ?? cgImage
        return NSImage(cgImage: heroImage, size: NSSize(width: heroImage.width, height: heroImage.height))
        #endif
    }

    nonisolated private static func transparentTrimmedImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        let alphaThreshold: UInt8 = 8

        for y in 0..<height {
            for x in 0..<width {
                let alphaIndex = y * bytesPerRow + x * bytesPerPixel + 3
                if pixels[alphaIndex] > alphaThreshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )

        guard cropRect.width < CGFloat(width) || cropRect.height < CGFloat(height) else {
            return nil
        }

        return image.cropping(to: cropRect)
    }

    private var detailAlbums: [Album] {
        displayArtist.isMerged ? mergedViewModel.filteredAlbums : viewModel.filteredAlbums
    }

    private var detailTracks: [Track] {
        displayArtist.isMerged ? mergedViewModel.filteredTracks : viewModel.filteredTracks
    }

    private var detailTrackCount: Int {
        displayArtist.isMerged ? mergedViewModel.trackCount : viewModel.trackCount
    }

    private var detailFavoritedTracks: [Track] {
        displayArtist.isMerged ? mergedViewModel.favoritedTracks : viewModel.favoritedTracks
    }

    // MARK: - Hero Banner

    @ViewBuilder
    private func artistHeader(containerWidth: CGFloat) -> some View {
        Group {
            if usesWideArtistHeader(containerWidth: containerWidth) {
                wideArtistHeader
            } else {
                compactArtistHeader(containerWidth: containerWidth)
            }
        }
    }

    private func usesWideArtistHeader(containerWidth: CGFloat) -> Bool {
        containerWidth >= EnsembleScaffold.ArtistDetail.wideHeaderThreshold
    }

    private func compactArtistHeader(containerWidth: CGFloat) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            heroBanner(containerWidth: containerWidth)

            compactActionButtons
                .padding(.top, EnsembleScaffold.ArtistDetail.compactActionTopPadding)
        }
    }

    private var wideArtistHeader: some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.ArtistDetail.sectionTopPadding) {
            wideArtistArtwork

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
                Text(viewModel.artist.name)
                    .font(EnsembleDesign.Typography.screenTitle)
                    .background(TitleOffsetTracker(coordinateSpace: "artistDetailScroll"))

                artistStatsLine

                artistHeaderFacts

                wideActionButtons
                    .frame(maxWidth: EnsembleScaffold.ArtistDetail.wideActionMaxWidth)
                    .padding(.top, EnsembleScaffold.DetailSurface.actionTopPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MeasuredWidthReader(onChange: updateArtistHeaderActionWidth))
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
        .padding(.top, EnsembleScaffold.ArtistDetail.wideHeaderTopPadding)
        .padding(.bottom, EnsembleScaffold.ArtistDetail.compactActionTopPadding)
    }

    private var wideArtistArtwork: some View {
        StableArtistArtworkImage(image: displayedArtworkImage) {
            ArtworkView(
                artist: viewModel.artist,
                size: .medium,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.medium.cgSize.width),
                isResponsive: true
            )
        }
        .frame(
            width: EnsembleScaffold.ArtistDetail.wideArtworkDimension,
            height: EnsembleScaffold.ArtistDetail.wideArtworkDimension
        )
        .clipShape(Circle())
        .ensembleArtworkShadow()
    }

    private var artistStatsLine: some View {
        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            if !hasArtistStatsContent {
                Text(" ")
                    .hidden()
            }
            if displayArtist.isMerged {
                Text("\(displayArtist.artists.count) sources")
            }
            if !detailAlbums.isEmpty {
                if displayArtist.isMerged {
                    Text("•")
                }
                Text("\(detailAlbums.count) album\(detailAlbums.count == 1 ? "" : "s")")
            }
            if !detailAlbums.isEmpty && !detailTracks.isEmpty {
                Text("•")
            }
            if !detailTracks.isEmpty {
                Text("\(detailTrackCount) song\(detailTrackCount == 1 ? "" : "s")")
            }
        }
        .font(EnsembleDesign.Typography.detailSubtitle)
        .foregroundColor(EnsembleDesign.Color.secondaryText)
    }

    private var hasArtistStatsContent: Bool {
        displayArtist.isMerged || !detailAlbums.isEmpty || !detailTracks.isEmpty
    }

    private var artistHeaderFacts: some View {
        let factLines = artistHeaderFactLines

        return VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.factsSpacing) {
            artistHeaderFactLine(factLines.primary)
            artistHeaderFactLine(factLines.secondary)
        }
        .font(EnsembleDesign.Typography.stateMessage)
        .foregroundColor(EnsembleDesign.Color.secondaryText)
        .lineLimit(1)
    }

    private var artistHeaderFactLines: (primary: String?, secondary: String?) {
        guard let detail = viewModel.artistDetail, hasQuickFacts(detail) else {
            return (nil, nil)
        }

        let secondary: String?
        if !detail.genres.isEmpty {
            secondary = detail.genres.prefix(3).joined(separator: ", ")
        } else if !detail.styles.isEmpty {
            secondary = detail.styles.prefix(3).joined(separator: ", ")
        } else {
            secondary = nil
        }

        return (detail.country, secondary)
    }

    @ViewBuilder
    private func artistHeaderFactLine(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text(text)
        } else {
            Text(" ")
                .hidden()
        }
    }

    private func updateArtistHeaderActionWidth(_ newWidth: CGFloat) {
        if abs(artistHeaderActionWidth - newWidth) > 1 {
            artistHeaderActionWidth = newWidth
        }
    }

    private func compactHeroHeight(containerWidth: CGFloat) -> CGFloat {
        if containerWidth > 0 {
            return containerWidth
        }

        #if os(iOS)
        return UIScreen.main.bounds.width
        #else
        return EnsembleScaffold.ArtistDetail.wideHeaderThreshold
        #endif
    }

    static func compactHeroOverscroll(frameMinY: CGFloat, restingMinY: CGFloat?) -> CGFloat {
        guard let restingMinY else { return 0 }
        return max(frameMinY - restingMinY, 0)
    }

    private func heroBanner(containerWidth: CGFloat) -> some View {
        GeometryReader { geometry in
            let bannerHeight = geometry.size.height
            let safeAreaInsets = geometry.safeAreaInsets
            let globalMinY = geometry.frame(in: .global).minY
            let overscroll = Self.compactHeroOverscroll(
                frameMinY: globalMinY,
                restingMinY: compactHeroRestingFrame?.minY
            )
            let artworkWidth = geometry.size.width + safeAreaInsets.leading + safeAreaInsets.trailing
            let artworkHeight = bannerHeight + safeAreaInsets.top + overscroll

            ZStack(alignment: .bottom) {
                // The resolved hero image fills the banner directly; ArtworkView is
                // only the unresolved fallback so it doesn't constrain the final image.
                StableArtistArtworkImage(image: displayedArtworkImage) {
                    ArtworkView(
                        artist: artworkArtist,
                        size: .large,
                        cornerRadius: 0,
                        isResponsive: true
                    )
                }
                .frame(width: artworkWidth, height: artworkHeight)
                .clipped()
                .mask {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.68),
                            .init(color: .clear, location: 0.96)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                // Shift up to cover the safe area + overscroll gap
                .offset(x: -safeAreaInsets.leading, y: -(safeAreaInsets.top + overscroll))
                .preference(
                    key: ArtistHeroFramePreferenceKey.self,
                    value: ArtistHeroFrame(minY: globalMinY, width: geometry.size.width)
                )

                // Artist info overlay — offset counteracts overscroll so
                // the text stays visually pinned instead of drifting down
                VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.metadataSpacing) {
                    Text(viewModel.artist.name)
                        .font(EnsembleDesign.Typography.screenTitle)
                        .background(TitleOffsetTracker(coordinateSpace: "artistDetailScroll"))

                    if !detailAlbums.isEmpty || !detailTracks.isEmpty {
                        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                            if displayArtist.isMerged {
                                Text("\(displayArtist.artists.count) sources")
                            }
                            if !detailAlbums.isEmpty {
                                if displayArtist.isMerged {
                                    Text("•")
                                }
                                Text("\(detailAlbums.count) album\(detailAlbums.count == 1 ? "" : "s")")
                            }
                            if !detailAlbums.isEmpty && !detailTracks.isEmpty {
                                Text("•")
                            }
                            if !detailTracks.isEmpty {
                                Text("\(detailTrackCount) song\(detailTrackCount == 1 ? "" : "s")")
                            }
                        }
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .offset(y: -overscroll)
            }
        }
        .frame(height: compactHeroHeight(containerWidth: containerWidth))
        .frame(maxWidth: .infinity)
    }

    private func updateCompactHeroRestingFrame(_ frame: ArtistHeroFrame?) {
        guard let frame else { return }
        guard let restingFrame = compactHeroRestingFrame else {
            compactHeroRestingFrame = frame
            return
        }

        if abs(restingFrame.width - frame.width) > 1 {
            compactHeroRestingFrame = frame
        }
    }

    // MARK: - Action Buttons

    private var compactActionButtons: some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: TrackListLayoutMetrics.rowHorizontalPadding,
            bottomPadding: EnsembleDesign.Spacing.lg,
            isDisabled: detailTracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: detailTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: detailTracks)
            }
        ) {
            // Radio button - queue all shuffled, enable sonically similar
            Button {
                nowPlayingVM.enableRadio(tracks: detailTracks)
            } label: {
                MediaDetailSurface<EmptyView>.IconActionLabel(systemImage: EnsembleDesign.Icon.radio)
            }
            .mediaDetailActionButtonStyle(role: .secondary)
            #if os(macOS)
            .help("Artist Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
    }

    private var wideActionButtons: some View {
        MediaDetailSurface<EmptyView>.AdaptivePlaybackActionRow(
            availableWidth: max(artistHeaderActionWidth, 1),
            isDisabled: detailTracks.isEmpty,
            includesExtraActions: true,
            play: {
                nowPlayingVM.play(tracks: detailTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: detailTracks)
            }
        ) {
            Button {
                nowPlayingVM.enableRadio(tracks: detailTracks)
            } label: {
                MediaDetailSurface<EmptyView>.IconActionLabel(systemImage: EnsembleDesign.Icon.radio)
            }
            .mediaDetailActionButtonStyle(role: .secondary)
            #if os(macOS)
            .help("Artist Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
    }

    // MARK: - About Section (Quick Facts + Description + Wikipedia)

    /// Whether there's any content to show in the About section
    private var hasAboutContent: Bool {
        let hasDetail = viewModel.artistDetail != nil
        let hasFacts = hasDetail && hasQuickFacts(viewModel.artistDetail!)
        let hasBio = viewModel.artist.summary != nil && !viewModel.artist.summary!.isEmpty
        return hasFacts || hasBio
    }

    private func hasQuickFacts(_ detail: ArtistDetail) -> Bool {
        detail.country != nil || !detail.genres.isEmpty || !detail.styles.isEmpty
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("About \(viewModel.artist.name)")

            // Quick facts
            if let detail = viewModel.artistDetail, hasQuickFacts(detail) {
                VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.controlSpacing) {
                    if let country = detail.country {
                        factRow(label: "From", value: country)
                    }
                    if !detail.genres.isEmpty {
                        factRow(label: "Genre", value: detail.genres.joined(separator: ", "))
                    }
                    if !detail.styles.isEmpty {
                        factRow(label: "Style", value: detail.styles.joined(separator: ", "))
                    }
                }
            }

            // Description
            if let summary = viewModel.artist.summary, !summary.isEmpty {
                descriptionContent(summary: summary)
            }

            // Wikipedia link (below description)
            if let url = viewModel.artistDetail?.wikipediaURL {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                        Image(systemName: EnsembleDesign.Icon.externalLink)
                        Text("Wikipedia")
                    }
                    .font(EnsembleDesign.Typography.stateMessage.weight(.medium))
                    .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func descriptionContent(summary: String) -> some View {
        // Plex sends paragraphs separated by \r\n; split on any newline variant
        let paragraphs = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.descriptionSpacing) {
            Text("Description")
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            // Tappable description text to toggle expanded/collapsed
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                if isBioExpanded {
                    // Expanded: show all paragraphs with paragraph spacing
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .font(EnsembleDesign.Typography.rowPrimary)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, index == paragraphs.indices.lowerBound ? EnsembleDesign.Spacing.none : EnsembleDesign.Spacing.md)
                    }
                } else {
                    // Collapsed: show truncated text
                    Text(paragraphs.first ?? summary)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .foregroundColor(EnsembleDesign.Color.primaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isBioExpanded.toggle()
                }
            }

            // Expand/collapse link
            if paragraphs.count > 1 || summary.count > 200 {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isBioExpanded.toggle()
                    }
                } label: {
                    Text(isBioExpanded ? "Show less" : "Read more")
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .fontWeight(.medium)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
        }
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            Text(label)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .frame(width: EnsembleScaffold.ArtistDetail.factLabelWidth, alignment: .leading)
            Text(value)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
    }

    // MARK: - Related Artists Section

    /// Shows only related artists that exist in the user's library (across all sources)
    private func relatedArtistsSection(artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("Related Artists")
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: EnsembleDesign.Spacing.lg) {
                    ForEach(artists, id: \.sourceScopedID) { artist in
                        navigationCoordinator.routeLink(
                            to: .artistDetail(artist)
                        ) {
                            similarArtistCard(artist: artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Card for a related artist in the user's library
    private func similarArtistCard(artist: Artist) -> some View {
        VStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
            ArtworkView(
                artist: artist,
                size: .thumbnail,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width)
            )

            Text(artist.name)
                .font(EnsembleDesign.Typography.cardSubtitle)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: ArtworkSize.thumbnail.cgSize.width)
        }
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("Albums")
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            AlbumGrid(
                albums: detailAlbums,
                nowPlayingVM: nowPlayingVM
            )
        }
    }

    private var mergedSourceSections: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.sectionTopPadding) {
            ForEach(mergedViewModel.sourceSections) { section in
                mergedSourceSection(section)
            }
        }
    }

    private func mergedSourceSection(_ section: MergedArtistSourceSection) -> some View {
        let albums = mergedViewModel.filteredAlbums(for: section)
        let favoritedTracks = mergedViewModel.favoritedTracks(for: section)

        return VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: EnsembleDesign.Spacing.md) {
                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                    Text(section.sourceTitle)
                        .font(EnsembleDesign.Typography.sectionTitle)
                        .foregroundColor(EnsembleDesign.Color.primaryText)

                    Text(sourceSectionMetadata(section, albums: albums, favoritedTracks: favoritedTracks, totalTracks: section.tracks))
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }

                Spacer()

                if canDownload(section.artist) {
                    sourceDownloadButton(for: section.artist)
                }
            }
            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            if !albums.isEmpty {
                AlbumGrid(
                    albums: albums,
                    nowPlayingVM: nowPlayingVM
                )
            }

            if !favoritedTracks.isEmpty {
                sourceFavoritedTracksSection(section: section, tracks: favoritedTracks)
            }
        }
    }

    private func sourceSectionMetadata(
        _ section: MergedArtistSourceSection,
        albums: [Album],
        favoritedTracks: [Track],
        totalTracks: [Track]
    ) -> String {
        [
            "\(albums.count) album\(albums.count == 1 ? "" : "s")",
            "\(totalTracks.count) song\(totalTracks.count == 1 ? "" : "s")",
            "\(favoritedTracks.count) favorited",
            displaySourceSubtitle(section.sourceSubtitle)
        ].joined(separator: " · ")
    }

    private func displaySourceSubtitle(_ sourceSubtitle: String) -> String {
        guard settingsManager.demoModeEnabled else { return sourceSubtitle }
        return "\(DemoModeRedaction.serverName) · \(DemoModeRedaction.accountIdentifier)"
    }

    private func sourceDownloadButton(for artist: Artist) -> some View {
        let isDownloaded = dependencies.offlineDownloadService.isArtistDownloadEnabled(artist)
        return Button {
            Task {
                await dependencies.downloadMutationWorkflow.setArtistDownloadEnabled(
                    artist,
                    isEnabled: !isDownloaded
                )
            }
        } label: {
            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isDownloaded ? "Remove Download" : "Download")
    }

    private func canDownload(_ artist: Artist) -> Bool {
        DownloadCapabilityPolicy.canAttemptDownload(
            for: artist.sourceCompositeKey,
            accountManager: dependencies.accountManager
        )
    }

    private func sourceFavoritedTracksSection(
        section: MergedArtistSourceSection,
        tracks: [Track]
    ) -> some View {
        let width = sourceFavoritedTrackListWidths[section.id] ?? 0

        return VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("Favorited Tracks")
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            MediaDetailSurface<EmptyView>.CompactPlaybackActionRow(
                isDisabled: tracks.isEmpty,
                play: {
                    nowPlayingVM.play(tracks: tracks)
                },
                shuffle: {
                    nowPlayingVM.shufflePlay(tracks: tracks)
                }
            )

            favoriteTrackList(tracks: tracks, supplementalMetadataWidth: width)
        }
        .measuredWidth { newWidth in
            if abs((sourceFavoritedTrackListWidths[section.id] ?? 0) - newWidth) > 1 {
                sourceFavoritedTrackListWidths[section.id] = newWidth
            }
        }
    }

    // MARK: - Favorited Tracks Section

    private var favoritedTracksSection: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("Favorited Tracks")
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            MediaDetailSurface<EmptyView>.CompactPlaybackActionRow(
                isDisabled: detailFavoritedTracks.isEmpty,
                play: {
                    nowPlayingVM.play(tracks: detailFavoritedTracks)
                },
                shuffle: {
                    nowPlayingVM.shufflePlay(tracks: detailFavoritedTracks)
                }
            )

            favoriteTrackList(tracks: detailFavoritedTracks, supplementalMetadataWidth: favoritedTrackListWidth)
        }
        .measuredWidth(onChange: updateFavoritedTrackListWidth)
    }

    private func favoriteTrackList(
        tracks: [Track],
        supplementalMetadataWidth: CGFloat
    ) -> some View {
            let interactionModel = TrackRowInteractionModel(
                onPlayNext: { track in
                    nowPlayingVM.playNext(track)
                },
                onPlayLast: { track in
                    nowPlayingVM.playLast(track)
                },
                onAddToPlaylist: { track in
                    presentPlaylistPicker(with: [track])
                },
                onAddToRecentPlaylist: { track in
                    addToRecentPlaylist(track)
                },
                onToggleFavorite: { track in
                    Task {
                        await nowPlayingVM.toggleTrackFavorite(track)
                    }
                },
                onGoToAlbum: { track in
                    if let albumId = track.albumRatingKey {
                        self.navigationCoordinator.routeFromMenu(
                            to: .album(id: albumId, sourceKey: track.sourceCompositeKey),
                            in: self.navigationCoordinator.selectedTab
                        )
                    }
                },
                onGetInfo: { track in
                    libraryItemInfoRequest = .track(track)
                },
                onShareLink: { track in
                    ShareActions.shareTrackLink(track, deps: dependencies)
                },
                onShareFile: { track in
                    ShareActions.shareTrackFile(track, deps: dependencies)
                },
                isTrackFavorited: { track in
                    nowPlayingVM.isTrackFavorited(track)
                },
                canAddToRecentPlaylist: { track in
                    recentPlaylistTitle(for: track) != nil
                },
                recentPlaylistTitle: nvmRecentPlaylistTitle
            )

            // Track list (UIKit table for consistent swipe actions and row height)
            #if os(iOS)
            let trackCount = tracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount) * TrackListLayoutMetrics.defaultRowHeight

            return MediaTrackList(
                tracks: tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                interactionModel: interactionModel,
                supplementalMetadataWidth: supplementalMetadataWidth,
                onGoToArtist: nil // Already in artist view
            ) { track, index in
                nowPlayingVM.play(tracks: tracks, startingAt: index)
            }
            .frame(height: height)
            #else
            return SongsTrackListHost(
                tracks: tracks,
                configuration: .songs(
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                    supplementalMetadataWidth: supplementalMetadataWidth,
                    interactionModel: interactionModel
                )
            ) { _, index in
                nowPlayingVM.play(tracks: tracks, startingAt: index)
            }
            .frame(height: CGFloat(tracks.count) * TrackListLayoutMetrics.defaultRowHeight)
            #endif
    }

    private func updateFavoritedTrackListWidth(_ newWidth: CGFloat) {
        if abs(favoritedTrackListWidth - newWidth) > 1 {
            favoritedTrackListWidth = newWidth
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private func addToRecentPlaylist(_ track: Track) {
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        PlaylistActionPresentationHost.recentPlaylistTitle(for: [track], nowPlayingVM: nowPlayingVM)
    }
}
