import EnsembleCore
import SwiftUI

// MARK: - Media Header Data

public struct MediaHeaderData {
    let title: String
    let subtitle: String?
    let metadataLine: String
    let artworkPath: String?
    let sourceKey: String?

    public init(
        title: String,
        subtitle: String? = nil,
        metadataLine: String,
        artworkPath: String?,
        sourceKey: String?
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataLine = metadataLine
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
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
        ScrollView {
            VStack(spacing: 0) {
                // Header
                headerView

                // Action buttons
                actionButtons

                // Tracks
                if viewModel.isLoading && viewModel.tracks.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else {
                    tracksSection
                }
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadTracks()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(
                path: headerData.artworkPath,
                sourceKey: headerData.sourceKey,
                size: .extraLarge,
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
                nowPlayingVM.play(tracks: viewModel.tracks)
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
                nowPlayingVM.play(tracks: viewModel.tracks.shuffled())
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
        .disabled(viewModel.tracks.isEmpty)
    }

    private var tracksSection: some View {
        MediaTrackList(
            tracks: viewModel.tracks,
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            groupByDisc: groupByDisc,
            currentTrackId: nowPlayingVM.currentTrack?.id
        ) { track, index in
            nowPlayingVM.play(tracks: viewModel.tracks, startingAt: index)
        }
    }
}
