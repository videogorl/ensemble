import SwiftUI

enum RootSceneScrollID: String {
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

/// Transient UI state that survives root-screen remounts, but not a cold launch.
@MainActor
final class RootSceneScrollState: ObservableObject {
    fileprivate var offsets: [RootSceneScrollID: Double] = [:]
    private var trackPositions: [RootSceneScrollID: (trackID: String, offset: CGFloat)] = [:]

    func trackPosition(_ id: RootSceneScrollID) -> Binding<(trackID: String, offset: CGFloat)?> {
        Binding(
            get: { self.trackPositions[id] },
            set: { self.trackPositions[id] = $0 }
        )
    }
}

private struct RootSceneScrollStateKey: EnvironmentKey {
    static let defaultValue: RootSceneScrollState? = nil
}

extension EnvironmentValues {
    var rootSceneScrollState: RootSceneScrollState? {
        get { self[RootSceneScrollStateKey.self] }
        set { self[RootSceneScrollStateKey.self] = newValue }
    }
}

private final class LiveScrollOffset {
    var value: CGFloat

    init(value: CGFloat) {
        self.value = value
    }
}

@available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct RootSceneScrollRestorationHost<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrollPosition: ScrollPosition
    @State private var liveOffset: LiveScrollOffset
    let content: Content
    let id: RootSceneScrollID
    let state: RootSceneScrollState

    init(content: Content, id: RootSceneScrollID, state: RootSceneScrollState) {
        self.content = content
        self.id = id
        self.state = state
        let offset = CGFloat(state.offsets[id, default: 0])
        _scrollPosition = State(initialValue: ScrollPosition(y: offset))
        _liveOffset = State(initialValue: LiveScrollOffset(value: offset))
    }

    var body: some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                liveOffset.value = offset
            }
            .onScrollPhaseChange { _, phase, context in
                guard phase == .idle, scenePhase == .active else { return }
                save(context.geometry.contentOffset.y + context.geometry.contentInsets.top)
            }
            .onChange(of: scenePhase) { phase in
                guard phase != .active else { return }
                save(liveOffset.value)
            }
    }

    private func save(_ offset: CGFloat) {
        let offset = Double(offset)
        guard abs(state.offsets[id, default: 0] - offset) > 1 else { return }
        state.offsets[id] = offset
    }
}

private struct RootSceneScrollRestorationModifier: ViewModifier {
    @Environment(\.rootSceneScrollState) private var state
    let id: RootSceneScrollID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *),
           let state {
            RootSceneScrollRestorationHost(content: content, id: id, state: state)
        } else {
            content
        }
    }
}

extension View {
    func restoringRootSceneScrollPosition(_ id: RootSceneScrollID) -> some View {
        modifier(RootSceneScrollRestorationModifier(id: id))
    }
}
