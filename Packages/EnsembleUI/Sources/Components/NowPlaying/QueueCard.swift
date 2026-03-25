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
            .chromelessMediaControlButton()
            .chromelessMediaControlMenu()
        }
        .padding(.horizontal, 40)
        .frame(minHeight: 36) // Consistent height across all NPV card headers
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
                // macOS: SwiftUI-based queue list
                macOSQueueListView
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
    
    // MARK: - macOS Queue List (SwiftUI-native, no UIKit dependency)

    #if os(macOS)
    @ViewBuilder
    private var macOSQueueListView: some View {
        let queueItemsToShow = Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1))
        let capturedCurrentIndex = viewModel.currentQueueIndex

        if viewModel.showHistory {
            // History list
            List {
                ForEach(Array(viewModel.playbackHistory.enumerated()), id: \.element.id) { index, item in
                    macOSQueueRow(item: item, isAutoplay: false)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.playFromHistory(at: index) }
                        .contextMenu { historyContextMenu(for: item) }
                }
            }
            .listStyle(.plain)
            .modifier(ClearScrollContentBackgroundModifier())
        } else {
            // Queue list with drag-to-reorder
            List {
                ForEach(Array(queueItemsToShow.enumerated()), id: \.element.id) { index, item in
                    macOSQueueRow(item: item, isAutoplay: item.source == .autoplay)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.playFromQueue(at: capturedCurrentIndex + 1 + index) }
                        .contextMenu { queueContextMenu(for: item, at: capturedCurrentIndex + 1 + index) }
                }
                .onMove { source, destination in
                    guard let fromOffset = source.first else { return }
                    let absoluteFrom = capturedCurrentIndex + 1 + fromOffset
                    let absoluteTo = capturedCurrentIndex + 1 + destination
                    viewModel.moveQueueItem(from: absoluteFrom, to: absoluteTo)
                }
            }
            .listStyle(.plain)
            .modifier(ClearScrollContentBackgroundModifier())

            // Recommendations exhausted indicator
            if viewModel.recommendationsExhausted && viewModel.isAutoplayEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14))
                    Text("End of recommendations")
                        .font(.subheadline)
                }
                .foregroundColor(.secondary)
                .padding(.vertical, 12)
            }
        }
    }

    /// Single row for the macOS queue/history list
    private func macOSQueueRow(item: QueueItem, isAutoplay: Bool) -> some View {
        HStack(spacing: 12) {
            // Artwork thumbnail
            ArtworkView(track: item.track, size: .tiny, cornerRadius: 4)

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isAutoplay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundColor(.purple)
                    }
                    Text(item.track.title)
                        .font(.callout)
                        .foregroundColor(isAutoplay ? .purple : .primary)
                        .lineLimit(1)
                }
                if let artist = item.track.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(item.track.formattedDuration)
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// Context menu for queue items
    @ViewBuilder
    private func queueContextMenu(for item: QueueItem, at absoluteIndex: Int) -> some View {
        Button { viewModel.playNext(item.track) } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button { viewModel.playLast(item.track) } label: {
            Label("Play Last", systemImage: "text.append")
        }
        Divider()
        Button { presentPlaylistPicker(with: [item.track], title: "Add to Playlist") } label: {
            Label("Add to Playlist...", systemImage: "music.note.list")
        }
        if let lastPlaylistQuickTarget,
           viewModel.compatibleTrackCount([item.track], for: lastPlaylistQuickTarget) > 0 {
            Button {
                Task {
                    _ = try? await viewModel.addTracks([item.track], to: lastPlaylistQuickTarget)
                }
            } label: {
                Label("Add to \(lastPlaylistQuickTarget.title)", systemImage: "plus.circle")
            }
        }
        Divider()
        if let albumId = item.track.albumRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
                dismiss()
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if let artistId = item.track.artistRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
                dismiss()
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        }
        Divider()
        Button(role: .destructive) { viewModel.removeFromQueue(at: absoluteIndex) } label: {
            Label("Remove from Queue", systemImage: "minus.circle")
        }
    }

    /// Context menu for history items
    @ViewBuilder
    private func historyContextMenu(for item: QueueItem) -> some View {
        Button { viewModel.playNext(item.track) } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button { viewModel.playLast(item.track) } label: {
            Label("Play Last", systemImage: "text.append")
        }
        Divider()
        Button { presentPlaylistPicker(with: [item.track], title: "Add to Playlist") } label: {
            Label("Add to Playlist...", systemImage: "music.note.list")
        }
        Divider()
        if let albumId = item.track.albumRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
                dismiss()
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if let artistId = item.track.artistRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
                dismiss()
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        }
    }
    #endif

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
        .chromelessMediaControlButton()
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

/// Removes the default opaque background from List/ScrollView on macOS 13+ / iOS 16+.
/// Falls through on older OS versions where scrollContentBackground is unavailable.
private struct ClearScrollContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
