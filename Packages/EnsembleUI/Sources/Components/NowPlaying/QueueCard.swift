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
    
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?
    
    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            // Scrollable queue list with fade masks
            ScrollView(showsIndicators: false) {
                queueListView
            }
            .mask(
                VStack(spacing: 0) {
                    // Top fade (more gradual)
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
                    
                    // Bottom fade (more gradual)
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
                .foregroundColor(.white)
            
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
                        .foregroundColor(.white.opacity(0.7))
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
                        .foregroundColor(.white.opacity(0.3))
                    
                    Text("Queue is empty")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.6))
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
                    .foregroundColor(viewModel.isShuffleEnabled ? .accentColor : .white.opacity(0.7))
            }
            
            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: viewModel.repeatMode.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.repeatMode.isActive ? .accentColor : .white.opacity(0.7))
            }
            
            // Autoplay (using Settings icon, not sparkles)
            Button(action: viewModel.toggleAutoplay) {
                ZStack {
                    // Use same icon as in SettingsView (not sparkles)
                    Image(systemName: autoplayIcon)
                        .font(.title3)
                        .foregroundColor(autoplayColor)
                    
                    // Cross-through indicator when disabled due to network
                    if isAutoplayDisabledDueToNetwork {
                        Image(systemName: "slash.circle")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.8))
                            .offset(x: 8, y: -8)
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 0)
    }
    
    private var autoplayIcon: String {
        viewModel.isAutoplayEnabled ? "infinity" : "infinity"
    }
    
    private var autoplayColor: Color {
        if isAutoplayDisabledDueToNetwork {
            return .white.opacity(0.4)
        }
        return viewModel.isAutoplayEnabled ? .accentColor : .white.opacity(0.7)
    }
    
    private var isAutoplayDisabledDueToNetwork: Bool {
        // Check if autoplay is functionally disabled due to network state
        !deps.networkMonitor.isConnected && viewModel.isAutoplayEnabled
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
