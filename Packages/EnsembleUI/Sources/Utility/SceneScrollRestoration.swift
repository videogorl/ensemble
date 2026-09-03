import SwiftUI

enum SceneScrollRestorationID: String {
    case feed
    case artists
    case albums
    case playlists
    case genres
    case searchExplore
    case searchResults
    case hidden
    case songs
    case favorites
    case downloads
    case profile
    case more
}

enum SceneScrollRestoration {
    @MainActor static var offsets: [SceneScrollRestorationID: Double] = [:]
    @MainActor static var trackPositions: [SceneScrollRestorationID: (trackID: String, offset: CGFloat)] = [:]

    @MainActor
    static func trackPosition(_ id: SceneScrollRestorationID) -> Binding<(trackID: String, offset: CGFloat)?> {
        Binding(
            get: { trackPositions[id] },
            set: { trackPositions[id] = $0 }
        )
    }
}

private final class SceneScrollOffsetCache {
    var value: CGFloat

    init(value: CGFloat) {
        self.value = value
    }
}

@available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct SceneScrollRestorationModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrollPosition: ScrollPosition
    @State private var liveOffset: SceneScrollOffsetCache
    let id: SceneScrollRestorationID

    private var storedScrollOffset: Double {
        get { SceneScrollRestoration.offsets[id, default: 0] }
        nonmutating set { SceneScrollRestoration.offsets[id] = newValue }
    }

    init(id: SceneScrollRestorationID) {
        self.id = id
        let storedOffset = CGFloat(SceneScrollRestoration.offsets[id, default: 0])
        _scrollPosition = State(initialValue: ScrollPosition(y: storedOffset))
        _liveOffset = State(initialValue: SceneScrollOffsetCache(value: storedOffset))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                liveOffset.value = offset
            }
            .onScrollPhaseChange { _, phase, context in
                guard phase == .idle, scenePhase == .active else { return }
                let offset = Double(
                    context.geometry.contentOffset.y + context.geometry.contentInsets.top
                )
                guard abs(storedScrollOffset - offset) > 1 else { return }
                storedScrollOffset = offset
            }
            .onChange(of: scenePhase) { phase in
                guard phase != .active else { return }
                let offset = Double(liveOffset.value)
                guard abs(storedScrollOffset - offset) > 1 else { return }
                storedScrollOffset = offset
            }
    }
}

extension View {
    @ViewBuilder
    func restoringSceneScrollPosition(_ id: SceneScrollRestorationID) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
            modifier(SceneScrollRestorationModifier(id: id))
        } else {
            self
        }
    }
}
