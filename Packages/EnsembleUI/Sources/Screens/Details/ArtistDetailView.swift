import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct SendableArtistPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

final class ArtistDetailArtworkContinuityStore {
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

// MARK: - Artist Detail View

private struct StableArtistArtworkImage<Fallback: View>: View {
    let image: PlatformImage?
    let targetSize: CGSize?
    @ViewBuilder let fallback: () -> Fallback

    @State private var currentImage: PlatformImage?

    init(
        image: PlatformImage?,
        targetSize: CGSize? = nil,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) {
        self.image = image
        self.targetSize = targetSize
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
        let resolvedImage = Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #else
        let resolvedImage = Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #endif
        if let targetSize {
            resolvedImage
                .frame(width: targetSize.width, height: targetSize.height)
        } else {
            resolvedImage
        }
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
    @State private var viewModel: ArtistDetailViewModel
    @State private var mergedViewModel: MergedArtistDetailViewModel
    private var settingsManager: SettingsManager { dependencies.settingsManager }
    private let displayArtist: DisplayArtist
    private let includesHidden: Bool
    let nowPlayingVM: NowPlayingViewModel

    @Environment(DependencyContainer.self) private var dependencies
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(MediaSourceActionPresenter.self) private var sourceActionPresenter
    private var pinManager: PinManager { dependencies.pinManager }
    // Targeted observation: only re-evaluate when these specific values change
    private var activeDownloadTrackIdentities: Set<String> { dependencies.offlineDownloadService.activeDownloadTrackIdentities }
    private var availabilityGeneration: UInt64 { dependencies.trackAvailabilityResolver.availabilityGeneration }
    // Targeted NVM observation: only re-evaluate for track changes and playlist target
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var isArtistPinned: Bool
    @State private var isBioExpanded = false
    @State private var artworkImage: PlatformImage?
    @State private var blurredArtworkImage: PlatformImage?
    @State private var continuityArtworkImage: PlatformImage?
    @State private var artworkLoadUnavailable = false
    @State private var currentArtworkLoadIdentity: String?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var artistHeaderActionWidth: CGFloat = 0
    @State private var favoritedTrackListWidth: CGFloat = 0
    @Environment(\.artistDetailArtworkContinuity) private var artistArtworkContinuity
    @Environment(\.openURL) private var openURL

    public init(
        artist: Artist,
        nowPlayingVM: NowPlayingViewModel,
        dependencies: DependencyContainer,
        includesHidden: Bool = false
    ) {
        self.init(displayArtist: .single(artist), nowPlayingVM: nowPlayingVM, dependencies: dependencies, includesHidden: includesHidden)
    }

    public init(
        displayArtist: DisplayArtist,
        nowPlayingVM: NowPlayingViewModel,
        dependencies: DependencyContainer,
        includesHidden: Bool = false
    ) {
        let artist = displayArtist.primaryArtist
        self.displayArtist = displayArtist
        self.includesHidden = includesHidden
        self._viewModel = State(initialValue: ArtistDetailViewModel(
            artist: artist,
            libraryRepository: dependencies.libraryRepository,
            syncCoordinator: dependencies.syncCoordinator,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            includesHidden: includesHidden,
            libraryChanges: dependencies.libraryChanges
        ))
        self._mergedViewModel = State(initialValue: MergedArtistDetailViewModel(
            displayArtist: displayArtist,
            libraryRepository: dependencies.libraryRepository,
            syncCoordinator: dependencies.syncCoordinator,
            accountManager: dependencies.accountManager,
            hiddenMediaStore: dependencies.hiddenMediaStore,
            includesHidden: includesHidden,
            libraryChanges: dependencies.libraryChanges
        ))
        self.nowPlayingVM = nowPlayingVM
        let pinnedIdentities = Set(dependencies.pinManager.pinnedItems.map(\.sourceScopedID))
        self._isArtistPinned = State(
            initialValue: displayArtist.artists.allSatisfy { pinnedIdentities.contains($0.sourceScopedID) }
        )
    }

    public var body: some View {
        DetailScreen(
            title: viewModel.artist.name,
            style: .artist,
            backdrop: DetailBackdrop(
                artworkImage: artworkImage,
                blurredImage: blurredArtworkImage,
                blurCacheKey: artistBackdropBlurCacheKey,
                continuityIdentity: displayArtist.id
            )
        ) {
            if !detailAlbums.isEmpty {
                artistAlbumSortMenu
            }
            artistPinMenuButton
        } content: {
            artistDetailScrollContent
        }
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            recentPlaylistTitle: $nvmRecentPlaylistTitle
        )
        .onChange(of: pinManager.pinnedItems, initial: true) { _, pinnedItems in
            updateArtistPinState(pinnedItems: pinnedItems)
        }
        .task(id: viewModel.artist.sourceScopedID) {
            viewModel.start()
            mergedViewModel.start()
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
                            if !detailAlbums.isEmpty {
                                albumsSection
                                    .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                            }
                            if !detailFavoritedTracks.isEmpty {
                                favoritedTracksSection
                                    .padding(.top, EnsembleScaffold.ArtistDetail.sectionTopPadding)
                            }
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
                        if !detailFavoritedTracks.isEmpty {
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
        let identities = Set(pinnedItems.map(\.sourceScopedID))
        let latest = displayArtist.artists.allSatisfy { identities.contains($0.sourceScopedID) }
        if latest != isArtistPinned {
            isArtistPinned = latest
        }
    }

    /// Toolbar menu with Pin/Unpin action for the artist
    private var artistPinMenuButton: some View {
        let isPinned = isArtistPinned
        let downloadState = dependencies.offlineDownloadService.batchState(for: displayArtist.artists)
        let isDownloaded = downloadState.isEnabled
        let canDownload = viewModel.artist.actionAvailability(for: .download).isAvailable
        let downloadableMergedArtists = mergedDownloadableArtists
        return Menu {
            Button {
                if isPinned {
                    dependencies.pinManager.unpinAll(
                        identities: Set(displayArtist.artists.map(\.sourceScopedID))
                    )
                } else {
                    dependencies.pinManager.pinAll(items: displayArtist.artists.map { artist in
                        (id: artist.id, sourceKey: artist.sourceCompositeKey ?? "", type: .artist, title: displayArtist.name)
                    })
                }
            } label: {
                MediaActionLabel(kind: .pin(isPinned: isPinned))
            }

            if displayArtist.isMerged, !downloadableMergedArtists.isEmpty {
                Button {
                    Task {
                        await dependencies.offlineDownloadService.toggleDownloads(
                            for: displayArtist.artists
                        )
                    }
                } label: {
                    MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                }
            } else if canDownload {
                Button {
                    Task {
                        await dependencies.offlineDownloadService.setArtistDownloadEnabled(
                            viewModel.artist,
                            isEnabled: !isDownloaded
                        )
                    }
                } label: {
                    MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                }
            }

            HiddenMediaDetailMenuButton(
                candidates: displayArtist.artists.compactMap { $0.hiddenCandidate(deps: dependencies) },
                identity: displayArtist.isMerged ? nil : HiddenMediaIdentity(viewModel.artist)
            )
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
    }

    private var artistAlbumSortMenu: some View {
        EnsembleBrowseSortMenu(
            model: viewModel,
            options: AlbumSortOption.allCases.filter { $0 != .albumArtist },
            selection: { _ in albumSortOption },
            direction: { _ in albumSortDirection },
            select: selectAlbumSortOption
        )
        .accessibilityLabel("Sort Artist Albums")
    }

    private var detailFilterOptions: FilterOptions {
        displayArtist.isMerged ? mergedViewModel.filterOptions : viewModel.filterOptions
    }

    private var albumSortOption: AlbumSortOption {
        AlbumSortOption(rawValue: detailFilterOptions.sortBy) ?? .year
    }

    private var albumSortDirection: SortDirection {
        detailFilterOptions.sortBy == "default" ? .descending : detailFilterOptions.sortDirection
    }

    private func selectAlbumSortOption(_ option: AlbumSortOption, direction: SortDirection) {
        var filterOptions = detailFilterOptions
        filterOptions.sortDirection = direction
        filterOptions.sortBy = option.rawValue

        if displayArtist.isMerged {
            mergedViewModel.filterOptions = filterOptions
        } else {
            viewModel.filterOptions = filterOptions
        }
    }

    private var mergedDownloadableArtists: [Artist] {
        guard displayArtist.isMerged else { return [] }
        return displayArtist.artists.filter {
            resolvedDownloadMenuAvailability(
                isDownloaded: dependencies.offlineDownloadService.isArtistDownloadEnabled($0),
                sourceAvailability: $0.actionAvailability(for: .download)
            ).isAvailable
        }
    }

    private var artworkArtist: Artist {
        displayArtist.artworkArtist
    }

    private var artistBackdropBlurCacheKey: String? {
        "\(artworkRequest(for: artworkArtist).stableBlurCacheKey)|artist-hero"
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

        let request = artworkRequest(for: artist)

        guard let resolved = await dependencies.artworkLoader.resolvedImage(for: request) else {
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

        let blurredImage = await dependencies.artworkLoader.blurredImage(
            for: heroImage,
            cacheKey: "\(resolved.blurCacheKey)|artist-hero",
            scheduler: dependencies.foregroundWorkScheduler
        )
        await MainActor.run {
            guard currentArtworkLoadIdentity == loadIdentity else { return }
            blurredArtworkImage = blurredImage
            artistArtworkContinuity.lastBlurredImage = blurredImage
        }
    }

    private func artworkRequest(for artist: Artist) -> ArtworkRequest {
        ArtworkRequest(
            path: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey,
            ratingKey: artist.id,
            fallbackPath: artist.fallbackThumbPath,
            fallbackRatingKey: artist.fallbackRatingKey,
            identity: ArtworkRequest.Identity(artist: artist),
            fallbackIdentity: ArtworkRequest.Identity(
                ratingKey: artist.fallbackRatingKey,
                kind: .album,
                sourcePath: artist.fallbackThumbPath
            ),
            tier: .hero,
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

    private var detailSnapshot: ArtistDetailDisplaySnapshot {
        displayArtist.isMerged ? mergedViewModel.displaySnapshot : viewModel.displaySnapshot
    }

    private var detailAlbums: [Album] {
        detailSnapshot.filteredAlbums
    }

    private var detailStudioAlbums: [Album] {
        detailSnapshot.studioAlbums
    }

    private var detailSinglesAndEPs: [Album] {
        detailSnapshot.singlesAndEPs
    }

    private var detailTracks: [Track] {
        MergingProjection.tracks(
            detailSnapshot.filteredTracks,
            preferences: settingsManager.mergingPreferences
        )
    }

    private var detailTrackCount: Int {
        detailSnapshot.trackCount
    }

    private var detailFavoritedTracks: [Track] {
        MergingProjection.tracks(
            detailSnapshot.favoritedTracks,
            preferences: settingsManager.mergingPreferences
        )
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
                    .background(TitleOffsetTracker(coordinateSpace: DetailScreen<EmptyView, EmptyView>.scrollSpace))

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
        StableArtistArtworkImage(
            image: displayedArtworkImage,
            targetSize: CGSize(
                width: EnsembleScaffold.ArtistDetail.wideArtworkDimension,
                height: EnsembleScaffold.ArtistDetail.wideArtworkDimension
            )
        ) {
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
                Text(artistStatsAlbumText)
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

    static func compactHeroOverscroll(globalMinY: CGFloat) -> CGFloat {
        max(globalMinY, 0)
    }

    private func heroBanner(containerWidth: CGFloat) -> some View {
        GeometryReader { geometry in
            let bannerHeight = geometry.size.height
            let globalMinY = geometry.frame(in: .global).minY
            let overscroll = Self.compactHeroOverscroll(globalMinY: globalMinY)
            let artworkWidth = geometry.size.width
            let artworkHeight = bannerHeight + overscroll

            ZStack(alignment: .bottom) {
                // The resolved hero image fills the banner directly; ArtworkView is
                // only the unresolved fallback so it doesn't constrain the final image.
                StableArtistArtworkImage(
                    image: displayedArtworkImage,
                    targetSize: CGSize(width: artworkWidth, height: artworkHeight)
                ) {
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
                .offset(y: -overscroll)

                // Artist info overlay — offset counteracts overscroll so
                // the text stays visually pinned instead of drifting down
                VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.metadataSpacing) {
                    Text(viewModel.artist.name)
                        .font(EnsembleDesign.Typography.screenTitle)
                        .background(TitleOffsetTracker(coordinateSpace: DetailScreen<EmptyView, EmptyView>.scrollSpace))

                    if !detailAlbums.isEmpty || !detailTracks.isEmpty {
                        HStack(spacing: EnsembleScaffold.UtilityRow.rowSpacing) {
                            if displayArtist.isMerged {
                                Text("\(displayArtist.artists.count) sources")
                            }
                            if !detailAlbums.isEmpty {
                                if displayArtist.isMerged {
                                    Text("•")
                                }
                                Text(artistStatsAlbumText)
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
        .frame(height: max(containerWidth, 0))
        .frame(maxWidth: .infinity)
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
        let hasFacts = viewModel.artistDetail.map(hasQuickFacts) ?? false
        let hasBio = !(viewModel.artist.summary?.isEmpty ?? true)
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
                LibraryDescriptionSection(
                    summary: summary,
                    isExpanded: $isBioExpanded,
                    spacing: EnsembleScaffold.ArtistDetail.descriptionSpacing
                )
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
        let displayArtists = DisplayArtist.group(artists, preferences: settingsManager.mergingPreferences)
        return VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader("Related Artists")
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: EnsembleDesign.Spacing.lg) {
                    ForEach(displayArtists) { displayArtist in
                        navigationCoordinator.routeLink(
                            to: .displayArtist(id: displayArtist.id)
                        ) {
                            similarArtistCard(artist: displayArtist.artworkArtist)
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
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.sectionTopPadding) {
            if !detailStudioAlbums.isEmpty {
                albumReleaseSection(title: "Albums", albums: detailStudioAlbums)
            }

            if !detailSinglesAndEPs.isEmpty {
                albumReleaseSection(title: "Singles & EPs", albums: detailSinglesAndEPs)
            }
        }
    }

    private var artistStatsAlbumText: String {
        artistStatsAlbumText(albumCount: detailStudioAlbums.count, singlesAndEPCount: detailSinglesAndEPs.count)
    }

    private func artistStatsAlbumText(albumCount: Int, singlesAndEPCount: Int) -> String {
        let albumText = "\(albumCount) album\(albumCount == 1 ? "" : "s")"
        guard singlesAndEPCount > 0 else { return albumText }
        return "\(albumText), \(singlesAndEPCount) single\(singlesAndEPCount == 1 ? "" : "s")/EP\(singlesAndEPCount == 1 ? "" : "s")"
    }

    private func albumReleaseSection(title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.ArtistDetail.aboutSpacing) {
            EnsembleContentSectionHeader(title)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            AlbumGrid(
                albums: albums,
                nowPlayingVM: nowPlayingVM,
                navigationCoordinator: navigationCoordinator,
                includesHidden: includesHidden
            )
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

            favoriteTrackList(
                tracks: detailFavoritedTracks,
                mutationSourceTracks: detailSnapshot.favoritedTracks,
                supplementalMetadataWidth: favoritedTrackListWidth
            )
        }
        .measuredWidth(onChange: updateFavoritedTrackListWidth)
    }

    private func favoriteTrackList(
        tracks: [Track],
        mutationSourceTracks: [Track]? = nil,
        supplementalMetadataWidth: CGFloat
    ) -> some View {
            let interactionModel = TrackRowInteractionModel.nowPlayingActions(
                nowPlayingVM: nowPlayingVM,
                deps: dependencies,
                navigationCoordinator: navigationCoordinator,
                includeArtistNavigation: false,
                recentPlaylistTitle: nvmRecentPlaylistTitle,
                mutationCandidates: { track in
                    MergingProjection.mutationCandidates(
                        for: track,
                        in: mutationSourceTracks ?? tracks,
                        preferences: settingsManager.mergingPreferences
                    )
                },
                sourceActionPresenter: sourceActionPresenter
            ) { tracks in
                presentPlaylistPicker(with: tracks)
            } onGetInfo: { track in
                libraryItemInfoRequest = .track(track)
            }

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

}
