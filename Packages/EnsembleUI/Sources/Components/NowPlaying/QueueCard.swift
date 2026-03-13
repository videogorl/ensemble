import EnsembleCore
import SwiftUI

/// Right card displaying scrollable queue with pinned header and secondary controls
/// Includes shuffle, repeat, autoplay buttons relocated from Controls card
public struct QueueCard: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }
    
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @Environment(\.dismiss) private var dismiss
    
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?
    
    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }
    
    /// Whether this card is the active page in the carousel.
    /// TabView's .page style renders ALL children simultaneously — gate the heavy
    /// QueueTableView (UIKit UITableView) behind this to avoid layout/rendering off-screen.
    private var isVisible: Bool {
        currentPage == 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)

            if isVisible {
                // Queue list — QueueTableView manages its own scrolling now.
                // No SwiftUI ScrollView wrapper — that was defeating cell recycling
                // by forcing IntrinsicTableView to report full contentSize.
                queueListView
                    .mask(
                        VStack(spacing: 0) {
                            // Top fade
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.1)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 50)

                            // Middle: full opacity
                            Rectangle().fill(Color.black)

                            // Bottom fade
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black, location: 0.7),
                                    .init(color: .clear, location: 1)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 80)
                        }
                    )
            } else {
                // Lightweight placeholder — avoids UITableView layout off-screen
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0) // Push secondary controls to bottom, matching ControlsCard

            // Secondary controls + spacing for fixed page indicator
            VStack(spacing: 8) {
                secondaryControlsView
                    .padding(.top, 16) // Extra padding above secondary controls
                Spacer().frame(height: 36) // Reserve space for fixed page indicator
            }
            .padding(.bottom, 20)
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(
                nowPlayingVM: viewModel,
                tracks: payload.tracks,
                title: payload.title
            )
        }
        .task {
            await refreshLastPlaylistQuickTarget()
        }
        .onChange(of: viewModel.currentTrack?.id) { _ in
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
        .onChange(of: viewModel.lastPlaylistTarget?.id) { _ in
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text(viewModel.showHistory ? "History" : "Queue")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Spacer()
            
            HStack(spacing: 16) {
                // History toggle
                Button(action: {
                    withAnimation(.spring()) {
                        viewModel.toggleHistory()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14))
                        Text("History")
                            .font(.subheadline)
                    }
                    .foregroundColor(viewModel.showHistory ? .accentColor : .secondary)
                }
                
                // Tertiary actions menu
                Menu {
                    Button {
                        let snapshot = viewModel.queueSnapshotForPlaylistSave()
                        presentPlaylistPicker(with: snapshot, title: "Save Queue as Playlist")
                    } label: {
                        Label("Save Queue as Playlist", systemImage: "square.and.arrow.down")
                    }
                    
                    // TODO: Future "Replay" action for replaying past queues
                    // Button { } label: { Label("Replay Queue...", systemImage: "clock.arrow.circlepath") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.primary.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Queue List
    
    private var queueListView: some View {
        ZStack {
            if !viewModel.queue.isEmpty || !viewModel.playbackHistory.isEmpty {
                #if canImport(UIKit)
                let queueItemsToShow = Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1))
                let capturedCurrentIndex = viewModel.currentQueueIndex
                
                QueueTableView(
                    queueItems: queueItemsToShow,
                    history: viewModel.playbackHistory,
                    showHistory: viewModel.showHistory,
                    currentQueueIndex: -1,
                    onItemTap: { item, absoluteIndex in
                        viewModel.playFromQueue(at: capturedCurrentIndex + 1 + absoluteIndex)
                    },
                    onHistoryTap: { item, historyIndex in
                        viewModel.playFromHistory(at: historyIndex)
                    },
                    onPlayNext: { track in
                        viewModel.playNext(track)
                    },
                    onPlayLast: { track in
                        viewModel.playLast(track)
                    },
                    onAddToPlaylist: { track in
                        presentPlaylistPicker(with: [track], title: "Add to Playlist")
                    },
                    onAddToRecentPlaylist: { track in
                        guard let lastPlaylistQuickTarget,
                              viewModel.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return }
                        Task {
                            _ = try? await viewModel.addTracks([track], to: lastPlaylistQuickTarget)
                        }
                    },
                    onGoToAlbum: { track in
                        if let albumId = track.albumRatingKey {
                            DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
                            dismiss()
                        }
                    },
                    onGoToArtist: { track in
                        if let artistId = track.artistRatingKey {
                            DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
                            dismiss()
                        }
                    },
                    canAddToRecentPlaylist: { track in
                        guard let lastPlaylistQuickTarget else { return false }
                        return viewModel.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0
                    },
                    recentPlaylistTitle: lastPlaylistQuickTarget?.title,
                    onRemoveFromQueue: { absoluteIndex in
                        viewModel.removeFromQueue(at: capturedCurrentIndex + 1 + absoluteIndex)
                    },
                    onMoveItem: { itemId, sourceIndex, destinationIndex in
                        let offset = capturedCurrentIndex + 1
                        viewModel.moveQueueItem(byId: itemId, from: sourceIndex + offset, to: destinationIndex + offset)
                    }
                )
                
                // Recommendations exhausted indicator
                if viewModel.recommendationsExhausted && viewModel.isAutoplayEnabled {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 14))
                            Text("End of recommendations")
                                .font(.subheadline)
                        }
                        .foregroundColor(.secondary)
                        .padding(.vertical, 16)
                    }
                }
                #else
                Text("Queue view not available on macOS")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 40)
                #endif
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 48))
                        .foregroundColor(.primary.opacity(0.3))
                    
                    Text("Queue is empty")
                        .font(.headline)
                        .foregroundColor(.primary.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }
    
    // MARK: - Secondary Controls (Relocated from Controls Card)
    
    private var secondaryControlsView: some View {
        HStack(spacing: 30) {
            // Shuffle
            Button(action: viewModel.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(viewModel.isShuffleEnabled ? .accentColor : .primary.opacity(0.7))
            }
            
            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: viewModel.repeatMode.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.repeatMode.isActive ? .accentColor : .primary.opacity(0.7))
            }
            
            // Autoplay — dimmed and non-interactive when offline (no network for recommendations)
            Button(action: viewModel.toggleAutoplay) {
                Image(systemName: autoplayIcon)
                    .font(.title3)
                    .foregroundColor(autoplayColor)
            }
            .disabled(!deps.networkMonitor.isConnected)
            .opacity(!deps.networkMonitor.isConnected ? 0.25 : 1.0)
        }
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 0)
    }
    
    private var autoplayIcon: String {
        viewModel.isAutoplayEnabled ? "infinity" : "infinity"
    }
    
    private var autoplayColor: Color {
        viewModel.isAutoplayEnabled ? .accentColor : .primary.opacity(0.7)
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func refreshLastPlaylistQuickTarget() async {
        guard let currentTrack = viewModel.currentTrack else {
            lastPlaylistQuickTarget = nil
            return
        }
        lastPlaylistQuickTarget = await viewModel.resolveLastPlaylistTarget(for: [currentTrack])
    }
    
    private func presentPlaylistPicker(with tracks: [Track], title: String) {
        guard !tracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "No tracks available",
                    message: "Try again in a moment.",
                    dedupeKey: "playlist-picker-empty-\(title)"
                )
            )
            return
        }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
    }
}
