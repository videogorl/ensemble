import EnsembleCore
import SwiftUI
import Nuke

// MARK: - Media Header Data

public struct MediaHeaderData {
    let title: String
    let subtitle: String?
    let metadataLine: String
    let artworkPath: String?
    let sourceKey: String?
    let ratingKey: String?
    let artistRatingKey: String? // Added for cross-navigation

    public init(
        title: String,
        subtitle: String? = nil,
        metadataLine: String,
        artworkPath: String?,
        sourceKey: String?,
        ratingKey: String? = nil,
        artistRatingKey: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataLine = metadataLine
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.artistRatingKey = artistRatingKey
    }
}

// MARK: - Media Detail View

public struct MediaDetailView<ViewModel: MediaDetailViewModelProtocol>: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    let headerData: MediaHeaderData
    let navigationTitle: String
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let groupByDisc: Bool
    let showFilter: Bool
    let mediaType: PinnedItemType?

    @State private var artworkImage: UIImage?
    @State private var currentLoadPath: String?
    @State private var showFilterSheet = false
    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    public init(
        viewModel: ViewModel,
        nowPlayingVM: NowPlayingViewModel,
        headerData: MediaHeaderData,
        navigationTitle: String,
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        groupByDisc: Bool = false,
        showFilter: Bool = true,
        mediaType: PinnedItemType? = nil
    ) {
        self.viewModel = viewModel
        self.nowPlayingVM = nowPlayingVM
        self.headerData = headerData
        self.navigationTitle = navigationTitle
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.groupByDisc = groupByDisc
        self.showFilter = showFilter
        self.mediaType = mediaType
    }

    public var body: some View {
        Group {
            if showFilter {
                baseContent
                    .searchable(text: $viewModel.filterOptions.searchText, prompt: "Search tracks")
                    .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showFilterSheet = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")

                                    // Badge indicator when filters are active
                                    if viewModel.filterOptions.hasActiveFilters {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                            }
                        }
                        #else
                        ToolbarItem(placement: .automatic) {
                            Button {
                                showFilterSheet = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                    if viewModel.filterOptions.hasActiveFilters {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                            }
                        }
                        #endif
                    }
                    .sheet(isPresented: $showFilterSheet) {
                        FilterSheet(
                            filterOptions: $viewModel.filterOptions
                        )
                    }
            } else {
                baseContent
            }
        }
        .toolbar {
            // Pin/Unpin menu button
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if let mediaType = mediaType,
                   let ratingKey = headerData.ratingKey {
                    pinMenuButton(ratingKey: ratingKey, mediaType: mediaType)
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if let mediaType = mediaType,
                   let ratingKey = headerData.ratingKey {
                    pinMenuButton(ratingKey: ratingKey, mediaType: mediaType)
                }
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }
        .task {
            await viewModel.loadTracks()
            if let path = headerData.artworkPath {
                await loadArtworkImage(path: path, sourceKey: headerData.sourceKey)
            }
        }
    }

    /// Toolbar menu with Pin/Unpin action
    private func pinMenuButton(ratingKey: String, mediaType: PinnedItemType) -> some View {
        let isPinned = pinManager.isPinned(id: ratingKey)
        return Menu {
            Button {
                if isPinned {
                    pinManager.unpin(id: ratingKey)
                } else {
                    pinManager.pin(
                        id: ratingKey,
                        sourceKey: headerData.sourceKey ?? "",
                        type: mediaType,
                        title: headerData.title
                    )
                }
            } label: {
                if isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Base content without filter UI — shared between filtered and unfiltered modes
    private var baseContent: some View {
        ZStack(alignment: .top) {
            // Background gradient
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    headerView

                    // Action buttons
                    actionButtons

                    // Tracks
                    if viewModel.isLoading && viewModel.filteredTracks.isEmpty {
                        ProgressView()
                            .padding(.top, 40)
                    } else if viewModel.filteredTracks.isEmpty {
                        Text("No tracks")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        tracksSection
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    private var backgroundGradient: some View {
        BlurredArtworkBackground(
            image: artworkImage,
            topDimming: 0.1,
            bottomDimming: 0.4
        )
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 500)
    }
    
    private func loadArtworkImage(path: String, sourceKey: String?) async {
        await MainActor.run {
            self.currentLoadPath = path
        }
        
        if let url = await deps.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: sourceKey,
            ratingKey: headerData.ratingKey,
            fallbackPath: nil,  // No fallback for album/artist/playlist detail views
            fallbackRatingKey: nil,
            size: 600
        ) {
            let request = ImageRequest(url: url)
            
            // Try synchronous cache lookup first
            if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                await MainActor.run {
                    if self.currentLoadPath == path {
                        self.artworkImage = cachedImage.image
                    }
                }
                return
            }
            
            // Load asynchronously if not cached
            if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                await MainActor.run {
                    // Only update if this is still the current path
                    if self.currentLoadPath == path {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.artworkImage = uiImage
                        }
                    }
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(
                path: headerData.artworkPath,
                sourceKey: headerData.sourceKey,
                size: .medium,
                cornerRadius: 12
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)

            VStack(spacing: 8) {
                Text(headerData.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let subtitle = headerData.subtitle {
                    if let artistId = headerData.artistRatingKey {
                        Group {
                            if #available(iOS 16.0, macOS 13.0, *) {
                                NavigationLink(value: NavigationCoordinator.Destination.artist(id: artistId)) {
                                    Text(subtitle)
                                        .font(.title3)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                            } else {
                                NavigationLink {
                                    ArtistDetailLoader(artistId: artistId, nowPlayingVM: nowPlayingVM)
                                } label: {
                                    Text(subtitle)
                                        .font(.title3)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } else {
                        Text(subtitle)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }

                Text(headerData.metadataLine)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Play button
            Button {
                nowPlayingVM.play(tracks: viewModel.filteredTracks)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }

            // Shuffle button
            Button {
                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }

            // Radio button (for Artist or Album views)
            radioButton
        }
        .padding(.horizontal)
        .padding(.bottom)
        .disabled(viewModel.filteredTracks.isEmpty)
    }

    @ViewBuilder
    private var radioButton: some View {
        // Radio button for Artist or Album views - queues all tracks, shuffles, enables radio
        if let _ = viewModel as? ArtistDetailViewModel {
            Button {
                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
            #if os(macOS)
            .help("Artist Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
        // Check if this is an Album detail view
        else if let _ = viewModel as? AlbumDetailViewModel {
            Button {
                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
            #if os(macOS)
            .help("Album Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        #if os(iOS)
        let trackCount = viewModel.filteredTracks.count
        let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount * 68 + (groupByDisc ? 100 : 0))
        
        MediaTrackList(
            tracks: viewModel.filteredTracks,
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            groupByDisc: groupByDisc,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            onPlayNext: { track in
                nowPlayingVM.playNext(track)
            },
            onPlayLast: { track in
                nowPlayingVM.playLast(track)
            }
        ) { track, index in
            nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
        }
        .frame(height: height)
        #else
        // Basic List fallback for macOS
        VStack(spacing: 0) {
            ForEach(Array(viewModel.filteredTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: showArtwork,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) }
                ) {
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if index < viewModel.filteredTracks.count - 1 {
                    Divider().padding(.leading, showArtwork ? 68 : 16)
                }
            }
        }
        #endif
    }
}
