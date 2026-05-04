import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

private var supportsCustomTrackSwipeGestures: Bool {
    #if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

/// Reusable swipe container for track rows in ScrollView-based layouts.
/// UIKit-backed tables use native `UISwipeActionsConfiguration` separately.
public struct TrackSwipeContainer<Content: View>: View {
    let track: Track
    let onPlayNext: (() -> Void)?
    let onPlayLast: (() -> Void)?
    let onAddToPlaylist: (() -> Void)?
    let content: Content

    private let nowPlayingVM: NowPlayingViewModel
    private let settingsManager = DependencyContainer.shared.settingsManager
    private let toastCenter = DependencyContainer.shared.toastCenter

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var hasHorizontalDrag = false

    private let actionWidth = EnsembleScaffold.TrackSwipe.actionWidth

    public init(
        track: Track,
        nowPlayingVM: NowPlayingViewModel,
        onPlayNext: (() -> Void)? = nil,
        onPlayLast: (() -> Void)? = nil,
        onAddToPlaylist: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.track = track
        self.nowPlayingVM = nowPlayingVM
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.content = content()
    }

    public var body: some View {
        #if os(iOS) || os(macOS)
        if supportsCustomTrackSwipeGestures {
            ZStack {
                backgroundActions
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(trackRowBackgroundColor)
                    .contentShape(Rectangle())
                    .offset(x: offset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .clipped()
            .highPriorityGesture(dragGesture)
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(iOS) || os(macOS)
    private var trackRowBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }

    private var leadingActions: [TrackSwipeAction] {
        settingsManager.trackSwipeLayout.leading.compactMap { action in
            guard let action else { return nil }
            return isActionSupported(action) ? action : nil
        }
    }

    private var trailingActions: [TrackSwipeAction] {
        settingsManager.trackSwipeLayout.trailing.compactMap { action in
            guard let action else { return nil }
            return isActionSupported(action) ? action : nil
        }
    }

    private var resolvedSwipeActions: TrackRowInteractionModel.ResolvedActions {
        TrackRowInteractionModel(
            onPlayNext: onPlayNext.map { callback in { _ in callback() } },
            onPlayLast: onPlayLast.map { callback in { _ in callback() } },
            onAddToPlaylist: onAddToPlaylist.map { callback in { _ in callback() } },
            onToggleFavorite: { track in
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            },
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            }
        )
        .resolve(for: track)
    }

    private var maxLeadingOffset: CGFloat {
        CGFloat(leadingActions.count) * actionWidth
    }

    private var maxTrailingOffset: CGFloat {
        CGFloat(trailingActions.count) * actionWidth
    }

    private var fullSwipeThreshold: CGFloat {
        actionWidth * 1.35
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard isHorizontal else { return }

                if !hasHorizontalDrag {
                    hasHorizontalDrag = true
                    dragStartOffset = offset
                }

                let rawOffset = dragStartOffset + value.translation.width
                let clampedLeading = maxLeadingOffset + actionWidth * 0.45
                let clampedTrailing = maxTrailingOffset + actionWidth * 0.45
                offset = min(max(rawOffset, -clampedTrailing), clampedLeading)
            }
            .onEnded { value in
                defer { hasHorizontalDrag = false }

                let predicted = dragStartOffset + value.predictedEndTranslation.width

                if predicted >= fullSwipeThreshold, let first = leadingActions.first {
                    execute(first)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                        closeActions()
                    }
                    return
                }

                if predicted <= -fullSwipeThreshold, let first = trailingActions.first {
                    execute(first)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                        closeActions()
                    }
                    return
                }

                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                    snapToNearestEdge()
                }
            }
    }

    @ViewBuilder
    private var backgroundActions: some View {
        ZStack {
            HStack(spacing: EnsembleDesign.Spacing.none) {
                ForEach(Array(leadingActions.enumerated()), id: \.offset) { _, action in
                    swipeButton(for: action)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            HStack(spacing: EnsembleDesign.Spacing.none) {
                ForEach(Array(trailingActions.reversed().enumerated()), id: \.offset) { _, action in
                    swipeButton(for: action)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: EnsembleScaffold.TrackSwipe.actionCornerRadius, style: .continuous))
    }

    private func swipeButton(for action: TrackSwipeAction) -> some View {
        Button {
            execute(action)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                closeActions()
            }
        } label: {
            VStack(spacing: EnsembleScaffold.TrackSwipe.actionLabelSpacing) {
                Image(systemName: TrackActionPresentation.systemImage(for: action, resolvedActions: resolvedSwipeActions))
                    .font(EnsembleScaffold.TrackSwipe.actionIconFont)
                Text(TrackActionPresentation.title(for: action, resolvedActions: resolvedSwipeActions))
                    .font(EnsembleScaffold.TrackSwipe.actionTextFont)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundColor(EnsembleDesign.Color.onAccent)
        }
        .frame(width: actionWidth)
        .frame(maxHeight: .infinity)
        .background(TrackActionPresentation.tint(for: action, resolvedActions: resolvedSwipeActions))
        .contentShape(Rectangle())
    }

    private func snapToNearestEdge() {
        if offset > actionWidth / 2, !leadingActions.isEmpty {
            offset = maxLeadingOffset
            dragStartOffset = offset
            return
        }
        if offset < -actionWidth / 2, !trailingActions.isEmpty {
            offset = -maxTrailingOffset
            dragStartOffset = offset
            return
        }
        closeActions()
    }

    private func closeActions() {
        offset = 0
        dragStartOffset = 0
    }

    private func isActionSupported(_ action: TrackSwipeAction) -> Bool {
        TrackActionPresentation.isSupported(action, resolvedActions: resolvedSwipeActions)
    }

    private func execute(_ action: TrackSwipeAction) {
        switch action {
        case .playNext, .playLast, .addToPlaylist:
            TrackActionPresentation.execute(action, track: track, resolvedActions: resolvedSwipeActions)
            showSwipeConfirmation(for: action, track: track)
        case .favoriteToggle:
            let willFavorite = !nowPlayingVM.isTrackFavorited(track)
            showFavoriteLoadingToast(for: track, willFavorite: willFavorite)
            TrackActionPresentation.execute(action, track: track, resolvedActions: resolvedSwipeActions)
        }
    }

    private func showSwipeConfirmation(for action: TrackSwipeAction, track: Track) {
        if let toast = TrackActionPresentation.confirmationToast(
            for: action,
            track: track,
            dedupeNamespace: "swipe"
        ) {
            toastCenter.show(toast)
        }
    }

    private func showFavoriteLoadingToast(for track: Track, willFavorite: Bool) {
        toastCenter.show(
            TrackActionPresentation.favoriteLoadingToast(
                for: track,
                willFavorite: willFavorite,
                dedupeNamespace: "swipe"
            )
        )
    }
    #endif
}
