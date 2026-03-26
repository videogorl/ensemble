import EnsembleCore
import SwiftUI

// MARK: - Generic Swipe Helpers

public extension View {
    /// Standard trailing swipe actions container used across list rows.
    @ViewBuilder
    func standardTrailingSwipeActions<Actions: View>(
        allowsFullSwipe: Bool = false,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        #if os(iOS) || os(macOS)
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
            actions()
        }
        #else
        self
        #endif
    }

    /// Standard trailing destructive swipe action used across list rows.
    @ViewBuilder
    func standardDeleteSwipeAction(
        allowsFullSwipe: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        standardTrailingSwipeActions(allowsFullSwipe: allowsFullSwipe) {
            Button(role: .destructive, action: action) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Track Swipe Actions (Native List .swipeActions for macOS trackpad)

#if os(iOS) || os(macOS)
extension View {
    /// Applies the user's configured track swipe layout as native `.swipeActions`
    /// on a `List` row. On macOS this enables two-finger trackpad swipe to reveal actions.
    ///
    /// - Parameters:
    ///   - track: The track this row represents.
    ///   - nowPlayingVM: View model for favorite state and playback actions.
    ///   - onPlayNext: Callback when "Play Next" is triggered.
    ///   - onPlayLast: Callback when "Play Last" is triggered.
    ///   - onAddToPlaylist: Callback when "Add to Playlist" is triggered.
    func trackSwipeActions(
        track: Track,
        nowPlayingVM: NowPlayingViewModel,
        onPlayNext: (() -> Void)? = nil,
        onPlayLast: (() -> Void)? = nil,
        onAddToPlaylist: (() -> Void)? = nil
    ) -> some View {
        let layout = DependencyContainer.shared.settingsManager.trackSwipeLayout
        let toastCenter = DependencyContainer.shared.toastCenter

        // Resolve supported actions for each edge
        let leadingActions = layout.leading.compactMap { action -> TrackSwipeAction? in
            guard let action else { return nil }
            return isActionSupported(action, onPlayNext: onPlayNext, onPlayLast: onPlayLast, onAddToPlaylist: onAddToPlaylist) ? action : nil
        }
        let trailingActions = layout.trailing.compactMap { action -> TrackSwipeAction? in
            guard let action else { return nil }
            return isActionSupported(action, onPlayNext: onPlayNext, onPlayLast: onPlayLast, onAddToPlaylist: onAddToPlaylist) ? action : nil
        }

        return self
            .swipeActions(edge: .leading, allowsFullSwipe: !leadingActions.isEmpty) {
                ForEach(leadingActions, id: \.self) { action in
                    swipeActionButton(
                        for: action,
                        track: track,
                        nowPlayingVM: nowPlayingVM,
                        toastCenter: toastCenter,
                        onPlayNext: onPlayNext,
                        onPlayLast: onPlayLast,
                        onAddToPlaylist: onAddToPlaylist
                    )
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: !trailingActions.isEmpty) {
                ForEach(trailingActions, id: \.self) { action in
                    swipeActionButton(
                        for: action,
                        track: track,
                        nowPlayingVM: nowPlayingVM,
                        toastCenter: toastCenter,
                        onPlayNext: onPlayNext,
                        onPlayLast: onPlayLast,
                        onAddToPlaylist: onAddToPlaylist
                    )
                }
            }
    }

    // MARK: - Private Helpers

    /// Builds a single swipe action button for the given action type.
    @ViewBuilder
    private func swipeActionButton(
        for action: TrackSwipeAction,
        track: Track,
        nowPlayingVM: NowPlayingViewModel,
        toastCenter: ToastCenter,
        onPlayNext: (() -> Void)?,
        onPlayLast: (() -> Void)?,
        onAddToPlaylist: (() -> Void)?
    ) -> some View {
        switch action {
        case .playNext:
            Button {
                onPlayNext?()
                toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "text.insert",
                        title: "Play Next",
                        message: "Added \(track.title).",
                        dedupeKey: "swipe-play-next-\(track.id)"
                    )
                )
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(.blue)

        case .playLast:
            Button {
                onPlayLast?()
                toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "text.append",
                        title: "Play Last",
                        message: "Queued \(track.title) for later.",
                        dedupeKey: "swipe-play-last-\(track.id)"
                    )
                )
            } label: {
                Label("Play Last", systemImage: "text.append")
            }
            .tint(.indigo)

        case .addToPlaylist:
            Button {
                onAddToPlaylist?()
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .tint(.orange)

        case .favoriteToggle:
            let isFavorited = nowPlayingVM.isTrackFavorited(track)
            Button {
                // Show loading toast
                toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: isFavorited ? "heart.slash.fill" : "heart.fill",
                        title: isFavorited ? "Removing from Favorites..." : "Adding to Favorites...",
                        message: track.title,
                        duration: 1.0,
                        dedupeKey: "favorite-toggle-loading-\(track.id)",
                        showsActivityIndicator: true
                    )
                )
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            } label: {
                Label(
                    isFavorited ? "Unfavorite" : "Favorite",
                    systemImage: isFavorited ? "heart.slash.fill" : "heart.fill"
                )
            }
            .tint(isFavorited ? .gray : .pink)
        }
    }

    /// Whether the given action has a corresponding callback available.
    private func isActionSupported(
        _ action: TrackSwipeAction,
        onPlayNext: (() -> Void)?,
        onPlayLast: (() -> Void)?,
        onAddToPlaylist: (() -> Void)?
    ) -> Bool {
        switch action {
        case .playNext: return onPlayNext != nil
        case .playLast: return onPlayLast != nil
        case .addToPlaylist: return onAddToPlaylist != nil
        case .favoriteToggle: return true
        }
    }
}
#endif

// MARK: - ClearScrollContentBackgroundModifier

/// Removes the default opaque background from List/ScrollView on macOS 13+ / iOS 16+.
/// Falls through on older OS versions where scrollContentBackground is unavailable.
struct ClearScrollContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
