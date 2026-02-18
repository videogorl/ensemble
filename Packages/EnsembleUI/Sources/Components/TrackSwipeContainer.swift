import EnsembleCore
import SwiftUI

/// Reusable swipe container for track rows in ScrollView-based layouts.
/// UIKit-backed tables use native `UISwipeActionsConfiguration` separately.
public struct TrackSwipeContainer<Content: View>: View {
    let track: Track
    let onPlayNext: (() -> Void)?
    let onPlayLast: (() -> Void)?
    let onAddToPlaylist: (() -> Void)?
    let content: Content

    @ObservedObject private var nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var hasHorizontalDrag = false

    private let actionWidth: CGFloat = 72

    public init(
        track: Track,
        nowPlayingVM: NowPlayingViewModel,
        onPlayNext: (() -> Void)? = nil,
        onPlayLast: (() -> Void)? = nil,
        onAddToPlaylist: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.track = track
        _nowPlayingVM = ObservedObject(wrappedValue: nowPlayingVM)
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        ZStack {
            backgroundActions
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: offset)
                .contentShape(Rectangle())
                .background(Color(.systemBackground))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
        .highPriorityGesture(dragGesture)
        #else
        content
        #endif
    }

    #if os(iOS)
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
            HStack(spacing: 0) {
                ForEach(Array(leadingActions.reversed().enumerated()), id: \.offset) { _, action in
                    swipeButton(for: action)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(Array(trailingActions.enumerated()), id: \.offset) { _, action in
                    swipeButton(for: action)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func swipeButton(for action: TrackSwipeAction) -> some View {
        Button {
            execute(action)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                closeActions()
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: actionIcon(for: action))
                    .font(.system(size: 16, weight: .semibold))
                Text(actionTitle(for: action))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundColor(.white)
        }
        .frame(width: actionWidth, maxHeight: .infinity)
        .background(actionTint(for: action))
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
        switch action {
        case .playNext:
            return onPlayNext != nil
        case .playLast:
            return onPlayLast != nil
        case .addToPlaylist:
            return onAddToPlaylist != nil
        case .favoriteToggle:
            return true
        }
    }

    private func actionTitle(for action: TrackSwipeAction) -> String {
        switch action {
        case .favoriteToggle:
            return nowPlayingVM.isTrackFavorited(track) ? "Unfavorite" : "Favorite"
        default:
            return action.title
        }
    }

    private func actionIcon(for action: TrackSwipeAction) -> String {
        switch action {
        case .favoriteToggle:
            return nowPlayingVM.isTrackFavorited(track) ? "heart.slash.fill" : "heart.fill"
        default:
            return action.systemImage
        }
    }

    private func actionTint(for action: TrackSwipeAction) -> Color {
        switch action {
        case .favoriteToggle:
            return nowPlayingVM.isTrackFavorited(track) ? .gray : .pink
        default:
            return action.tint
        }
    }

    private func execute(_ action: TrackSwipeAction) {
        switch action {
        case .playNext:
            onPlayNext?()
        case .playLast:
            onPlayLast?()
        case .addToPlaylist:
            onAddToPlaylist?()
        case .favoriteToggle:
            Task {
                await nowPlayingVM.toggleTrackFavorite(track)
            }
        }
    }
    #endif
}
