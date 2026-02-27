import EnsembleCore
import SwiftUI
import Nuke
import AVKit
#if canImport(UIKit)
import UIKit
#endif

public struct NowPlayingView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    
    @State private var artworkImage: UIImage?
    @State private var currentLoadTrackID: String?
    
    // Long-press seek state
    @State private var seekTimer: Timer?
    @State private var seekWorkItem: DispatchWorkItem?
    @State private var isSeekingForward = false
    @State private var isSeekingBackward = false
    
    // Custom slider state
    @State private var isDraggingSlider = false
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartX: CGFloat = 0
    @State private var lastDragX: CGFloat = 0
    @State private var currentDragY: CGFloat = 0
    @State private var initialProgress: Double = 0
    @State private var localProgress: Double = 0
    @State private var sliderWidth: CGFloat = 0
    @State private var lastScrubRate: Double = 1.0
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient (vibrant colors from artwork)
                backgroundGradientView

                // Content with scrollable queue
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Now Playing content (full screen height)
                        if let track = viewModel.currentTrack {
                            nowPlayingContent(track: track, geometry: geometry)
                                .frame(height: geometry.size.height)
                        } else {
                            nowPlayingEmptyContent(geometry: geometry)
                                .frame(height: geometry.size.height)
                        }

                        // Queue section
                        queueSection(geometry: geometry)
                    }
                }
                .frame(width: geometry.size.width)

                // Error overlay (when playback fails)
                if case .failed(let errorMessage) = viewModel.playbackState {
                    errorOverlayView(errorMessage: errorMessage)
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .onChange(of: viewModel.currentTrack) { newTrack in
                // Clear old artwork immediately to prevent stale display during loading
                currentLoadTrackID = nil
                withAnimation(.easeInOut(duration: 0.3)) {
                    artworkImage = nil
                }
                
                if let track = newTrack {
                    loadArtworkImage(for: track)
                }
            }
            .onAppear {
                if let track = viewModel.currentTrack {
                    loadArtworkImage(for: track)
                }
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
                Task { await refreshLastPlaylistQuickTarget() }
            }
            .onChange(of: viewModel.lastPlaylistTarget?.id) { _ in
                Task { await refreshLastPlaylistQuickTarget() }
            }

        }
    }

    // Fixed background gradient
    private var backgroundGradientView: some View {
        // Animation ensures a smooth cross-fade between artwork backgrounds.
        // DO NOT REMOVE THIS - it prevents jarring swaps and flickering.
        BlurredArtworkBackground(image: artworkImage)
            .animation(.easeInOut(duration: 0.8), value: artworkImage)
    }

    // Now Playing content with new layout
    private func nowPlayingContent(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Dismiss handle
            dismissHandle
            
            // Artwork with generous padding above and below
            let artworkSize = min(geometry.size.width * 0.75, geometry.size.height * 0.35)
            ArtworkView(track: track, size: .medium, cornerRadius: 12)
                .frame(width: artworkSize, height: artworkSize)
                .clipped()
                .contrast(1.1)
                .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
                .padding(.top, 40)
                .padding(.bottom, 60)
            
            // Playback slider
            progressView(track: track)
                .padding(.horizontal, 40)
            
            // Track metadata (below slider, clickable)
            trackMetadataView(track: track)
                .padding(.horizontal, 32)
                .padding(.top, 16)
            
            // Main playback controls
            controlsView
                .padding(.top, 32)

            // Push secondary controls to bottom with spacer
            Spacer()
            
            // Secondary controls at bottom (shuffle, repeat, heart, airplay)
            secondaryControlsView
                .padding(.bottom, 20)
        }
    }

    // Empty-state version of the Now Playing layout
    private func nowPlayingEmptyContent(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            dismissHandle

            let artworkSize = min(geometry.size.width * 0.75, geometry.size.height * 0.35)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.35))
                )
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.25), radius: 15, x: 0, y: 8)
                .padding(.top, 40)
                .padding(.bottom, 60)

            VStack(spacing: 8) {
                Text("Nothing Playing")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Play music from your library to start listening")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)

            controlsView
                .opacity(0.5)
                .allowsHitTesting(false)
                .padding(.top, 32)

            Spacer()

            secondaryControlsView
                .opacity(0.5)
                .allowsHitTesting(false)
                .padding(.bottom, 20)
        }
    }
    
    // Dismiss handle
    private var dismissHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.vertical, 16)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
        }
    }
    
    // Track metadata with clickable artist/album
    private func trackMetadataView(track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artist name (clickable)
            if let artist = track.artistName {
                Button(action: {
                    handleArtistTap(track: track)
                }) {
                    MarqueeText(
                        text: artist,
                        font: .title3,
                        color: .white.opacity(0.9)
                    )
                }
            }

            // Track title
            MarqueeText(
                text: track.title,
                font: .title2,
                color: .white,
                fontWeight: .bold
            )

            // Album name (clickable)
            if let album = track.albumName {
                Button(action: {
                    handleAlbumTap(track: track)
                }) {
                    MarqueeText(
                        text: album,
                        font: .callout,
                        color: .white.opacity(0.7)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 0)
    }

    // Progress slider with time labels
    private func progressView(track: Track) -> some View {
        VStack(spacing: 8) {
            // Custom slider with variable speed scrubbing and waveform
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Waveform background
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let waveform = WaveformView(
                            progress: isDraggingSlider ? localProgress : viewModel.progress,
                            bufferedProgress: viewModel.bufferedProgress,
                            color: .white,
                            heights: viewModel.waveformHeights
                        )
                        .frame(width: geometry.size.width)
                        .opacity(0.8)

                        #if os(iOS)
                        if #available(iOS 16.0, *) {
                            waveform
                                .id(track.id) // Force view reset when track changes
                                .transition(.opacity)
                                .animation(.easeInOut, value: track.id)
                        } else {
                            // iOS 15: avoid additional identity churn in TimelineView
                            // to prevent SwiftUI IDViewList assertion recursion.
                            waveform
                        }
                        #else
                        waveform
                            .id(track.id) // Force view reset when track changes
                            .transition(.opacity)
                            .animation(.easeInOut, value: track.id)
                        #endif
                    }
                    
                    // Invisible interaction layer
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(height: 24)
                .clipped()
                .onAppear {
                    sliderWidth = geometry.size.width
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDraggingSlider {
                                isDraggingSlider = true
                                sliderWidth = geometry.size.width
                                dragStartY = value.location.y
                                dragStartX = value.location.x
                                lastDragX = value.location.x
                                initialProgress = max(0, min(1, value.location.x / sliderWidth))
                                localProgress = initialProgress
                            }
                            
                            currentDragY = value.location.y
                            
                            // Calculate scrub rate based on vertical distance
                            let verticalDistance = abs(currentDragY - dragStartY)
                            let scrubRate = getScrubRate(verticalDistance: verticalDistance)
                            
                            // Trigger haptics if scrub rate changed
                            if scrubRate != lastScrubRate {
                                #if os(iOS)
                                UISelectionFeedbackGenerator().selectionChanged()
                                #endif
                                lastScrubRate = scrubRate
                            }
                            
                            // Calculate delta from last position and apply current scrub rate
                            let deltaX = value.location.x - lastDragX
                            let progressChange = (deltaX / sliderWidth) * scrubRate
                            
                            // Update local progress incrementally
                            localProgress = max(0, min(1, localProgress + progressChange))
                            lastDragX = value.location.x
                        }
                        .onEnded { _ in
                            // Seek to final position
                            viewModel.seekToProgress(localProgress)
                            isDraggingSlider = false
                        }
                )
            }
            .frame(height: 24)

            // Time labels with scrub indicator in center
            HStack {
                Group {
                    if isDraggingSlider {
                        Text(formatTime(localProgress * viewModel.scrubberDuration))
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(viewModel.formattedCurrentTime)
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.7))

                Spacer()
                
                // Scrub speed indicator (inline with time labels)
                if isDraggingSlider {
                    scrubIndicator
                }
                
                Spacer()

                Group {
                    if isDraggingSlider {
                        Text(formatTime((1 - localProgress) * viewModel.scrubberDuration))
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(viewModel.formattedRemainingTime)
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.7))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 0)
    }
    
    // Scrub speed indicator (no background)
    private var scrubIndicator: some View {
        let verticalDistance = abs(currentDragY - dragStartY)
        let isMovingUp = currentDragY < dragStartY
        let isMaxFine = verticalDistance >= 120
        let scrubInfo = getScrubInfo()
        
        return HStack(spacing: 4) {
            Image(systemName: isMaxFine ? "minus" : (isMovingUp ? "chevron.compact.up" : "chevron.compact.down"))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            
            Text(scrubInfo.label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
        .transition(.opacity)
    }

    // Main playback controls
    private var controlsView: some View {
        HStack(spacing: 50) {
            // Previous/Rewind button with long-press
            ZStack {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
                
                // Show seek indicator during long-press
                if isSeekingBackward {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 16))
                        .offset(y: -28)
                }
            }
            .scaleEffect(isSeekingBackward ? 1.1 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if seekTimer == nil && seekWorkItem == nil {
                            let item = DispatchWorkItem {
                                if !isSeekingBackward {
                                    startSeeking(forward: false)
                                }
                            }
                            seekWorkItem = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
                        }
                    }
                    .onEnded { _ in
                        seekWorkItem?.cancel()
                        seekWorkItem = nil
                        
                        if isSeekingBackward {
                            stopSeeking()
                        } else {
                            // Short tap - execute previous action
                            viewModel.previous()
                        }
                    }
            )

            // Play/Pause
            Button(action: viewModel.togglePlayPause) {
                ZStack {
                    // Show spinner when loading or buffering
                    if viewModel.playbackState == .loading || viewModel.playbackState == .buffering {
                        // Show faded button in background
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 80))
                            .opacity(0.3)

                        // Spinner on top
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 80))
                    }
                }
            }

            // Next/Forward button with long-press
            ZStack {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
                
                // Show seek indicator during long-press
                if isSeekingForward {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 16))
                        .offset(y: -28)
                }
            }
            .scaleEffect(isSeekingForward ? 1.1 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if seekTimer == nil && seekWorkItem == nil {
                            let item = DispatchWorkItem {
                                if !isSeekingForward {
                                    startSeeking(forward: true)
                                }
                            }
                            seekWorkItem = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
                        }
                    }
                    .onEnded { _ in
                        seekWorkItem?.cancel()
                        seekWorkItem = nil
                        
                        if isSeekingForward {
                            stopSeeking()
                        } else {
                            // Short tap - execute next action
                            viewModel.next()
                        }
                    }
            )
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 5)
    }

    // Secondary controls: shuffle, repeat, heart, airplay
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

            // Heart/Rating button (three-state)
            Button(action: viewModel.toggleRating) {
                Image(systemName: viewModel.currentRating.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.currentRating == .none ? .white.opacity(0.7) : .accentColor)
            }
            
            // AirPlay button
            AirPlayButton()
                .frame(width: 24, height: 24)

            // More actions
            Menu {
                if let lastPlaylistQuickTarget {
                    if let currentTrack = viewModel.currentTrack,
                       viewModel.compatibleTrackCount([currentTrack], for: lastPlaylistQuickTarget) > 0 {
                        Button {
                            Task {
                                _ = try? await viewModel.addTracks([currentTrack], to: lastPlaylistQuickTarget)
                            }
                        } label: {
                            Label("Add to \(lastPlaylistQuickTarget.title)", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                Button {
                    guard let currentTrack = viewModel.currentTrack else { return }
                    presentPlaylistPicker(with: [currentTrack], title: "Add to Playlist")
                } label: {
                    Label("Add to Playlist...", systemImage: "text.badge.plus")
                }

                Button {
                    let snapshot = viewModel.queueSnapshotForPlaylistSave()
                    presentPlaylistPicker(with: snapshot, title: "Save Current Queue")
                } label: {
                    Label("Save Current Queue", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 0)
    }

    // Queue section that follows Now Playing in the ScrollView
    private func queueSection(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Queue header with autoplay toggle
            HStack {
                Text(viewModel.showHistory ? "History" : "Queue")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                
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

                    // Autoplay toggle
                    Button(action: viewModel.toggleAutoplay) {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isAutoplayEnabled ? "sparkles" : "sparkles.slash")
                                .font(.system(size: 14))
                            Text("Autoplay")
                                .font(.subheadline)
                        }
                        .foregroundColor(viewModel.isAutoplayEnabled ? .purple : .secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            
            // Queue table view
            if !viewModel.queue.isEmpty || !viewModel.playbackHistory.isEmpty {
                #if canImport(UIKit)
                let queueItemsToShow = Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1))
                
                // Capture currentQueueIndex at display time to avoid race conditions
                let capturedCurrentIndex = viewModel.currentQueueIndex
                
                QueueTableView(
                    queueItems: queueItemsToShow,
                    history: viewModel.playbackHistory,
                    showHistory: viewModel.showHistory,
                    currentQueueIndex: -1,
                    onItemTap: { item, absoluteIndex in
                        // Use captured index to ensure consistent calculations
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
                        // Use captured index for consistency
                        viewModel.removeFromQueue(at: capturedCurrentIndex + 1 + absoluteIndex)
                    },
                    onMoveItem: { itemId, sourceIndex, destinationIndex in
                        // destinationIndex from QueueTableView is relative to the *visible* queue (upcoming items)
                        // PlaybackService expects absolute indices into the *master* queue
                        // So we must add capturedCurrentIndex + 1
                        let offset = capturedCurrentIndex + 1
                        viewModel.moveQueueItem(
                            byId: itemId,
                            from: sourceIndex + offset,
                            to: destinationIndex + offset
                        )
                    }
                )
                .padding(.bottom, 40)
                #else
                Text("Queue view not available on macOS")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 40)
                #endif
                
                // Show "End of recommendations" message when autoplay can't find more tracks
                if viewModel.recommendationsExhausted && viewModel.isAutoplayEnabled {
                    VStack(spacing: 8) {
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

                Button {
                    let snapshot = viewModel.queueSnapshotForPlaylistSave()
                    presentPlaylistPicker(with: snapshot, title: "Save Current Queue")
                } label: {
                    Label("Save Current Queue", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            } else {
                Text("Queue is empty")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 50)
        #if canImport(UIKit)
        .background(Color(.systemBackground))
        .cornerRadius(24, corners: [.topLeft, .topRight])
        #else
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(24)
        #endif
    }
    
    // Helper: Load artwork image for blurred background
    private func loadArtworkImage(for track: Track) {
        let trackID = track.id
        currentLoadTrackID = trackID
        
        Task {
            // Get artwork URL
            if let artworkURL = await deps.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600 // Use slightly larger size for background
            ) {
                // Check Nuke cache first for instant display
                let request = ImageRequest(url: artworkURL)
                
                // Try synchronous cache lookup first
                if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                    await MainActor.run {
                        if self.currentLoadTrackID == trackID {
                            self.artworkImage = cachedImage.image
                        }
                    }
                    return
                }
                
                // Load asynchronously if not cached
                if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                    await MainActor.run {
                        // Only update if this is still the current track
                        if self.currentLoadTrackID == trackID {
                            // Using a smooth cross-fade transition.
                            // DO NOT REMOVE THIS - it ensures beautiful track transitions.
                            withAnimation(.easeInOut(duration: 0.5)) {
                                self.artworkImage = uiImage
                            }
                        }
                    }
                }
            } else {
                // No artwork URL available - clear previous artwork
                await MainActor.run {
                    if self.currentLoadTrackID == trackID {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.artworkImage = nil
                        }
                    }
                }
            }
        }
    }
    
    // Helper: Navigate to artist
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
            dismiss()
        }
    }
    
    // Helper: Navigate to album
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
            dismiss()
        }
    }

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
    
    // Helper: Start rapid seeking
    private func startSeeking(forward: Bool) {
        // Set seeking state
        if forward {
            isSeekingForward = true
        } else {
            isSeekingBackward = true
        }
        
        // Create timer that seeks every 0.1 seconds
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak viewModel] _ in
            Task { @MainActor in
                guard let viewModel = viewModel else { return }
                let currentTime = viewModel.currentTime
                let seekAmount: TimeInterval = forward ? 2.0 : -2.0
                let newTime = max(0, min(currentTime + seekAmount, viewModel.scrubberDuration))
                viewModel.seek(to: newTime)
            }
        }
    }
    
    // Helper: Stop rapid seeking
    private func stopSeeking() {
        seekTimer?.invalidate()
        seekTimer = nil
        isSeekingForward = false
        isSeekingBackward = false
    }
    
    // Helper: Get scrub rate based on vertical distance
    private func getScrubRate(verticalDistance: CGFloat) -> Double {
        switch verticalDistance {
        case 0..<40:
            return 1.0      // Hi-Speed Scrubbing
        case 40..<80:
            return 0.5      // Half-Speed Scrubbing
        case 80..<120:
            return 0.25     // Quarter-Speed Scrubbing
        default:
            return 0.1      // Fine Scrubbing
        }
    }
    
    // Helper: Get scrub info for display
    private func getScrubInfo() -> (label: String, rate: Double) {
        let verticalDistance = abs(currentDragY - dragStartY)
        switch verticalDistance {
        case 0..<40:
            return ("Hi-Speed Scrubbing", 1.0)
        case 40..<80:
            return ("Half-Speed Scrubbing", 0.5)
        case 80..<120:
            return ("Quarter-Speed Scrubbing", 0.25)
        default:
            return ("Fine Scrubbing", 0.1)
        }
    }
    
    // Helper: Format time for display
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Error overlay when playback fails
    private func errorOverlayView(errorMessage: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Playback Error")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Check your connection and try again")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task {
                    await viewModel.retryCurrentTrack()
                }
            } label: {
                Text("Retry")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
        }
        .padding(40)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.3), radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }
}

#if canImport(UIKit)
// Helper for corner radius on specific corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
#endif
