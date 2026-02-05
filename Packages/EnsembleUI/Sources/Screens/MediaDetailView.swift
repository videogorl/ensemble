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

    public init(
        title: String,
        subtitle: String? = nil,
        metadataLine: String,
        artworkPath: String?,
        sourceKey: String?,
        ratingKey: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataLine = metadataLine
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
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
    
    @State private var artworkImage: UIImage?
    @State private var currentLoadPath: String?
    @Environment(\.dependencies) private var deps

    public init(
        viewModel: ViewModel,
        nowPlayingVM: NowPlayingViewModel,
        headerData: MediaHeaderData,
        navigationTitle: String,
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        groupByDisc: Bool = false
    ) {
        self.viewModel = viewModel
        self.nowPlayingVM = nowPlayingVM
        self.headerData = headerData
        self.navigationTitle = navigationTitle
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.groupByDisc = groupByDisc
    }

    public var body: some View {
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
        .task {
            await viewModel.loadTracks()
            if let path = headerData.artworkPath {
                await loadArtworkImage(path: path, sourceKey: headerData.sourceKey)
            }
        }
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

    private var headerView: some View {        VStack(spacing: 16) {
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
                    Text(subtitle)
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                Text(headerData.metadataLine)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
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
        }
        .padding(.horizontal)
        .padding(.bottom)
        .disabled(viewModel.filteredTracks.isEmpty)
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
            currentTrackId: nowPlayingVM.currentTrack?.id
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
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id
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
