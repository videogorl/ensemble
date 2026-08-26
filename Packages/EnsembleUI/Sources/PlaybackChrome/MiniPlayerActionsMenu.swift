import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct MiniPlayerActionsMenuButton: View {
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject var ratingProjection: NowPlayingRatingProjection
    let viewModel: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showingActionsPopover = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?

    var body: some View {
        actionsButton
            .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: viewModel)
    }

    @ViewBuilder
    private var actionsButton: some View {
        #if os(iOS)
            Button {
                showingActionsPopover = playbackProjection.currentTrack != nil
            } label: {
                Image(systemName: EnsembleDesign.Icon.trackActions)
                    .font(EnsembleDesign.Typography.overflowIcon)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .frame(
                        width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
                        height: EnsembleScaffold.MiniPlayer.actionButtonDimension
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playbackProjection.currentTrack == nil)
            .accessibilityLabel("Track Actions")
            .popover(isPresented: $showingActionsPopover, arrowEdge: .bottom) {
                MiniPlayerActionsPopoverContent(
                    sections: menuSections,
                    state: menuState,
                    handlers: menuHandlers,
                    onAction: { showingActionsPopover = false }
                )
            }
        #elseif os(macOS)
            NativeMiniPlayerActionsMenuButton(
                isEnabled: playbackProjection.currentTrack != nil,
                sections: menuSections,
                state: menuState,
                handlers: menuHandlers
            )
            .frame(
                width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
                height: EnsembleScaffold.MiniPlayer.actionButtonDimension
            )
            .accessibilityLabel("Track Actions")
        #endif
    }

    private var currentTrackRecentPlaylistTitle: String? {
        guard let track = playbackProjection.currentTrack else { return nil }
        return PlaylistActionPresentationHost.recentPlaylistTitle(
            for: [track],
            nowPlayingVM: viewModel
        )
    }

    private var menuSections: [MediaMenuSection] {
        guard let track = playbackProjection.currentTrack else { return [] }
        return MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: MediaMenuAvailability(
                hasRecentPlaylist: currentTrackRecentPlaylistTitle != nil,
                canAddToLibrary: viewModel.canAddTrackToLibrary(track),
                canAddToRecentPlaylist: currentTrackRecentPlaylistTitle != nil,
                canGoToAlbum: track.albumRatingKey != nil,
                canGoToArtist: track.artistRatingKey != nil,
                canShareLink: true,
                canShareAudioFile: track.sourceCapabilities.supportsAudioFileSharing,
                canFavorite: true,
                canDownload: false,
                canPin: false,
                canEditMetadata: false,
                canDelete: false,
                canRename: false,
                canEditPlaylist: false,
                canRemoveFromQueue: false,
                itemActions: [
                    .favorite: track.actionAvailability(
                        for: .favorite,
                        isFavorited: ratingProjection.isTrackFavorited(track)
                    )
                ]
            )
        )
    }

    private var menuState: MediaMenuState {
        guard let track = playbackProjection.currentTrack else {
            return MediaMenuState(
                recentPlaylistTitle: nil,
                isShuffleEnabled: playbackProjection.isShuffleEnabled,
                repeatMode: playbackProjection.repeatMode
            )
        }
        return MediaMenuState(
            recentPlaylistTitle: currentTrackRecentPlaylistTitle,
            isFavorited: ratingProjection.isTrackFavorited(track),
            isShuffleEnabled: playbackProjection.isShuffleEnabled,
            repeatMode: playbackProjection.repeatMode
        )
    }

    private var menuHandlers: MediaMenuHandlers {
        MediaMenuHandlers(
            toggleShuffle: toggleShuffle,
            repeatAll: repeatAll,
            repeatOne: repeatOne,
            playNext: playNext,
            playLast: playLast,
            addToLibrary: addToLibrary,
            addToRecentPlaylist: addToRecentPlaylist,
            addToPlaylist: requestPlaylistPicker,
            goToAlbum: goToAlbum,
            goToArtist: goToArtist,
            favorite: toggleFavorite,
            shareEnsembleLink: shareEnsembleLink,
            shareLink: shareTrackLink,
            shareAudioFile: shareTrackFile
        )
    }

    private func playNext() {
        guard let track = playbackProjection.currentTrack else { return }
        viewModel.playNext(track)
    }

    private func playLast() {
        guard let track = playbackProjection.currentTrack else { return }
        viewModel.playLast(track)
    }

    private func addToLibrary() {
        guard let track = playbackProjection.currentTrack else { return }
        Task { await viewModel.addTrackToLibrary(track) }
    }

    private func toggleFavorite() {
        guard let track = playbackProjection.currentTrack else { return }
        Task { await viewModel.toggleTrackFavorite(track) }
    }

    private func addToRecentPlaylist() {
        guard let track = playbackProjection.currentTrack else { return }
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: viewModel)
    }

    private func requestPlaylistPicker() {
        guard let track = playbackProjection.currentTrack else { return }
        playlistActionRequest = PlaylistActionPresentationHost.request(for: [track])
    }

    private func toggleShuffle() {
        viewModel.toggleShuffle()
    }

    private func repeatAll() {
        viewModel.setRepeatMode(.all)
    }

    private func repeatOne() {
        viewModel.setRepeatMode(.one)
    }

    private func goToAlbum() {
        guard let track = playbackProjection.currentTrack,
              let albumId = track.albumRatingKey else { return }
        navigationCoordinator.navigateFromMenu(
            to: .album(id: albumId, sourceKey: track.sourceCompositeKey)
        )
    }

    private func goToArtist() {
        guard let track = playbackProjection.currentTrack,
              let artistId = track.artistRatingKey else { return }
        navigationCoordinator.navigateFromMenu(
            to: .artist(id: artistId, sourceKey: track.sourceCompositeKey)
        )
    }

    private func shareTrackLink() {
        guard let track = playbackProjection.currentTrack else { return }
        ShareActions.shareTrackLink(track, deps: deps)
    }

    private func shareEnsembleLink() {
        guard let track = playbackProjection.currentTrack else { return }
        ShareActions.shareEnsembleLink(track, deps: deps)
    }

    private func shareTrackFile() {
        guard let track = playbackProjection.currentTrack else { return }
        ShareActions.shareTrackFile(track, deps: deps)
    }
}

#if os(iOS)
    private struct MiniPlayerActionsPopoverContent: View {
        let sections: [MediaMenuSection]
        let state: MediaMenuState
        let handlers: MediaMenuHandlers
        let onAction: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                ForEach(renderableSections.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, EnsembleScaffold.MiniPlayer.popoverDividerVerticalPadding)
                    }

                    ForEach(renderableSections[index].actions, id: \.id) { descriptor in
                        if let handler = handlers.handler(for: descriptor.id),
                           let labelKind = descriptor.labelKind(state: state)
                        {
                            Button(role: descriptor.role == .destructive ? .destructive : nil) {
                                onAction()
                                handler()
                            } label: {
                                MediaActionLabel(kind: labelKind)
                                    .font(EnsembleDesign.Typography.popoverAction)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, EnsembleDesign.Spacing.popoverActionHorizontal)
                                    .padding(.vertical, EnsembleDesign.Spacing.popoverActionVertical)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                            .disabled(!descriptor.availability.isAvailable)
                            .accessibilityHint(descriptor.availability.reason ?? "")
                        }
                    }
                }
            }
            .padding(.vertical, EnsembleDesign.Spacing.sm)
            .frame(width: EnsembleScaffold.MiniPlayer.popoverWidth, alignment: .leading)
            .ensembleMaterial(
                EnsembleScaffold.MiniPlayer.popoverMaterialRole,
                cornerRadius: EnsembleScaffold.MiniPlayer.popoverCornerRadius
            )
        }

        private var renderableSections: [MediaMenuSection] {
            MediaMenuCatalog.renderableSections(sections, state: state, handlers: handlers)
        }
    }

#elseif os(macOS)
    private struct NativeMiniPlayerActionsMenuButton: NSViewRepresentable {
        let isEnabled: Bool
        let sections: [MediaMenuSection]
        let state: MediaMenuState
        let handlers: MediaMenuHandlers

        func makeNSView(context: Context) -> NSButton {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: EnsembleDesign.Icon.trackActions, accessibilityDescription: "Track Actions")
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryChange)
            button.contentTintColor = .secondaryLabelColor
            button.target = context.coordinator
            button.action = #selector(Coordinator.showMenu(_:))
            button.setAccessibilityLabel("Track Actions")
            return button
        }

        func updateNSView(_ nsView: NSButton, context: Context) {
            context.coordinator.parent = self
            nsView.isEnabled = isEnabled
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        final class Coordinator: NSObject {
            var parent: NativeMiniPlayerActionsMenuButton

            init(parent: NativeMiniPlayerActionsMenuButton) {
                self.parent = parent
            }

            @objc func showMenu(_ sender: NSButton) {
                guard let menu = AppKitMediaMenuRenderer.contextMenu(
                    sections: parent.sections,
                    state: parent.state,
                    handlers: parent.handlers
                ) else { return }
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + EnsembleScaffold.MiniPlayer.macMenuYOffset),
                    in: sender
                )
            }
        }
    }
#endif
