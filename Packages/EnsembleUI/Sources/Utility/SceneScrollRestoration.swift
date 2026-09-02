import SwiftUI

enum SceneScrollRestorationID: String {
    case feed = "HomeView.scrollOffset"
    case artists = "ArtistsView.scrollOffset"
    case albums = "AlbumsView.scrollOffset"
    case playlists = "PlaylistsView.scrollOffset"
    case genres = "GenresView.scrollOffset"
    case searchExplore = "SearchView.exploreScrollOffset"
    case searchResults = "SearchView.resultsScrollOffset"
    case songs = "SongsView.scrollOffset"
}

enum SceneScrollRestoration {
    static func clampedOffset(_ requestedOffset: CGFloat, maximumOffset: CGFloat) -> CGFloat {
        min(max(requestedOffset, 0), max(maximumOffset, 0))
    }
}

private struct SceneScrollMetrics: Equatable {
    let offset: CGFloat
    let maximumOffset: CGFloat
}

private final class SceneScrollOffsetCache {
    var value: CGFloat = 0
}

@available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct SceneScrollRestorationModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage private var storedScrollOffset: Double
    @State private var scrollPosition = ScrollPosition()
    @State private var isRestoring = true
    @State private var liveOffset = SceneScrollOffsetCache()
    let restoresNativeScrollView: Bool

    init(id: SceneScrollRestorationID, restoresNativeScrollView: Bool = false) {
        _storedScrollOffset = SceneStorage(wrappedValue: 0, id.rawValue)
        self.restoresNativeScrollView = restoresNativeScrollView
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: SceneScrollMetrics.self) { geometry in
                SceneScrollMetrics(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    maximumOffset: max(
                        geometry.contentSize.height - geometry.containerSize.height
                            + geometry.contentInsets.top + geometry.contentInsets.bottom,
                        0
                    )
                )
            } action: { _, metrics in
                liveOffset.value = metrics.offset
                if isRestoring {
                    let requestedOffset = CGFloat(storedScrollOffset)
                    guard requestedOffset == 0 || metrics.maximumOffset > 0 else { return }
                    let targetOffset = SceneScrollRestoration.clampedOffset(
                        requestedOffset,
                        maximumOffset: metrics.maximumOffset
                    )
                    if abs(metrics.offset - targetOffset) > 1 {
                        scrollPosition.scrollTo(y: targetOffset)
                    } else {
                        isRestoring = false
                    }
                    return
                }
            }
            .onScrollPhaseChange { _, phase, context in
                guard !isRestoring, phase == .idle, scenePhase == .active else { return }
                let offset = Double(
                    context.geometry.contentOffset.y + context.geometry.contentInsets.top
                )
                guard abs(storedScrollOffset - offset) > 1 else { return }
                storedScrollOffset = offset
            }
            .onChange(of: scenePhase) { phase in
                guard !isRestoring, phase != .active else { return }
                let offset = Double(liveOffset.value)
                guard abs(storedScrollOffset - offset) > 1 else { return }
                storedScrollOffset = offset
            }
            .overlay {
                #if os(iOS)
                if restoresNativeScrollView {
                    NativeSceneScrollRestorationProbe(offset: CGFloat(storedScrollOffset))
                        .allowsHitTesting(false)
                }
                #endif
            }
    }
}

#if os(iOS)
@available(iOS 18.0, *)
private struct NativeSceneScrollRestorationProbe: UIViewRepresentable {
    let offset: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.requestedOffset = offset
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.requestedOffset = offset
        uiView.setNeedsLayout()
    }

    final class ProbeView: UIView {
        var requestedOffset: CGFloat = 0
        private var didRestore = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            restoreIfNeeded()
        }

        private func restoreIfNeeded() {
            guard !didRestore, let window else { return }
            guard requestedOffset > 0 else {
                didRestore = true
                return
            }

            let point = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
            var candidate = window.hitTest(point, with: nil)
            while let view = candidate, !(view is UIScrollView) {
                candidate = view.superview
            }
            guard let scrollView = candidate as? UIScrollView else { return }

            scrollView.layoutIfNeeded()
            let maximumOffset = max(
                scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom,
                0
            )
            guard maximumOffset > 0 else { return }

            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: SceneScrollRestoration.clampedOffset(
                        requestedOffset,
                        maximumOffset: maximumOffset
                    ) - scrollView.adjustedContentInset.top
                ),
                animated: false
            )
            didRestore = true
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func restoringSceneScrollPosition(_ id: SceneScrollRestorationID) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
            modifier(SceneScrollRestorationModifier(id: id))
        } else {
            self
        }
    }

    @ViewBuilder
    func restoringSceneListPosition(_ id: SceneScrollRestorationID) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
            modifier(SceneScrollRestorationModifier(id: id, restoresNativeScrollView: true))
        } else {
            self
        }
    }
}
