import SwiftUI
#if os(iOS)
import UIKit
#endif

enum RootChromeCoordinateSpace {
    static let name = "RootChromeCoordinateSpace"
}

private struct SoftwareKeyboardVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSoftwareKeyboardVisible: Bool {
        get { self[SoftwareKeyboardVisibleKey.self] }
        set { self[SoftwareKeyboardVisibleKey.self] = newValue }
    }
}

struct RootChromeRegistration {
    let bounds: Anchor<CGRect>?
    let resolvedFrame: CGRect?
    let bottomPadding: CGFloat
    let contentLeadingInset: CGFloat
    let centersInRootHorizontalSpace: Bool
    let showsMiniPlayer: Bool
    let priority: Int

    static let hidden = RootChromeRegistration(
        bounds: nil,
        resolvedFrame: nil,
        bottomPadding: 0,
        contentLeadingInset: 0,
        centersInRootHorizontalSpace: false,
        showsMiniPlayer: false,
        priority: .min
    )
}

struct RootChromeLayout: Equatable {
    let frame: CGRect
    let bottomPadding: CGFloat
    let horizontalOffset: CGFloat
    let showsMiniPlayer: Bool

    static let hidden = RootChromeLayout(
        frame: .zero,
        bottomPadding: 0,
        horizontalOffset: 0,
        showsMiniPlayer: false
    )

    var hasRenderableFrame: Bool {
        frame.width > 0 && frame.height > 0
    }

    var horizontalAnchor: CGFloat {
        frame.midX + horizontalOffset
    }
}

struct RootChromeRegistrationPreferenceKey: PreferenceKey {
    static var defaultValue: RootChromeRegistration = .hidden

    static func reduce(value: inout RootChromeRegistration, nextValue: () -> RootChromeRegistration) {
        let next = nextValue()
        if next.priority >= value.priority {
            value = next
        }
    }
}

struct RootSidebarChromeRegistrationView: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RootSidebarChromeFramePreferenceKey.self,
                value: proxy.frame(in: .named(RootChromeCoordinateSpace.name))
            )
        }
    }
}

struct RootSidebarChromeFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct RootChromeFrameRegistrationView: View {
    let bottomPadding: CGFloat
    var contentLeadingInset: CGFloat = 0
    var centersInRootHorizontalSpace = false
    let showsMiniPlayer: Bool
    let priority: Int

    var body: some View {
        Color.clear.anchorPreference(
            key: RootChromeRegistrationPreferenceKey.self,
            value: .bounds
        ) { bounds in
            RootChromeRegistration(
                bounds: bounds,
                resolvedFrame: nil,
                bottomPadding: bottomPadding,
                contentLeadingInset: contentLeadingInset,
                centersInRootHorizontalSpace: centersInRootHorizontalSpace,
                showsMiniPlayer: showsMiniPlayer,
                priority: priority
            )
        }
    }
}

struct RootChromeResolvedFrameRegistrationView: View {
    let frame: CGRect
    let bottomPadding: CGFloat
    var contentLeadingInset: CGFloat = 0
    var centersInRootHorizontalSpace = false
    let showsMiniPlayer: Bool
    let priority: Int

    var body: some View {
        Color.clear.preference(
            key: RootChromeRegistrationPreferenceKey.self,
            value: RootChromeRegistration(
                bounds: nil,
                resolvedFrame: frame,
                bottomPadding: bottomPadding,
                contentLeadingInset: contentLeadingInset,
                centersInRootHorizontalSpace: centersInRootHorizontalSpace,
                showsMiniPlayer: showsMiniPlayer,
                priority: priority
            )
        )
    }
}

enum RootChromeLayoutResolver {
    static func resolve(
        from registration: RootChromeRegistration,
        sidebarFrame: CGRect? = nil,
        in proxy: GeometryProxy
    ) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)

        guard rootBounds.width > 0,
              rootBounds.height > 0 else {
            return .hidden
        }

        guard registration.bounds != nil || registration.resolvedFrame != nil else {
            return RootChromeLayout(
                frame: rootBounds,
                bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                    safeAreaBottom: proxy.safeAreaInsets.bottom
                ),
                horizontalOffset: 0,
                showsMiniPlayer: true
            )
        }

        let registeredFrame: CGRect
        if let resolvedFrame = registration.resolvedFrame {
            registeredFrame = resolvedFrame
        } else if let bounds = registration.bounds {
            registeredFrame = proxy[bounds]
        } else {
            registeredFrame = rootBounds
        }

        let stableRegisteredFrame = frameForVisibleSidebarIfNeeded(
            registeredFrame,
            sidebarFrame: sidebarFrame,
            rootBounds: rootBounds
        )
        let visibleFrame = stableRegisteredFrame.intersection(rootBounds)

        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .hidden
        }

        return RootChromeLayout(
            frame: visibleFrame,
            bottomPadding: registration.bottomPadding,
            horizontalOffset: horizontalOffset(
                for: visibleFrame,
                rootBounds: rootBounds,
                contentLeadingInset: registration.contentLeadingInset,
                centersInRootHorizontalSpace: registration.centersInRootHorizontalSpace
            ),
            showsMiniPlayer: registration.showsMiniPlayer
        )
    }

    private static func horizontalOffset(
        for visibleFrame: CGRect,
        rootBounds: CGRect,
        contentLeadingInset: CGFloat,
        centersInRootHorizontalSpace: Bool
    ) -> CGFloat {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return 0
        }

        if centersInRootHorizontalSpace {
            return rootBounds.midX - visibleFrame.midX
        }

        guard visibleFrame.minX <= 1 else {
            return 0
        }

        let missingLeadingOffset = rootBounds.width - visibleFrame.width
        if missingLeadingOffset > 1 {
            return missingLeadingOffset
        }

        guard contentLeadingInset > 0 else {
            return 0
        }

        return contentLeadingInset / 2
        #else
        return 0
        #endif
    }

    private static func frameForVisibleSidebarIfNeeded(
        _ registeredFrame: CGRect,
        sidebarFrame: CGRect?,
        rootBounds: CGRect
    ) -> CGRect {
        guard let visibleSidebarFrame = visibleSidebarFrame(
            from: sidebarFrame,
            rootBounds: rootBounds
        ) else {
            return registeredFrame
        }

        let detailMinX = min(max(visibleSidebarFrame.maxX, rootBounds.minX), rootBounds.maxX)
        let detailWidth = max(rootBounds.maxX - detailMinX, 0)
        guard detailWidth > 0 else {
            return registeredFrame
        }

        return CGRect(
            x: detailMinX,
            y: registeredFrame.minY,
            width: detailWidth,
            height: registeredFrame.height
        )
    }

    private static func visibleSidebarFrame(
        from sidebarFrame: CGRect?,
        rootBounds: CGRect
    ) -> CGRect? {
        guard let sidebarFrame else {
            return nil
        }

        let visibleFrame = sidebarFrame.intersection(rootBounds)
        guard visibleFrame.width > 1,
              visibleFrame.height > 1,
              visibleFrame.maxX < rootBounds.maxX - 1 else {
            return nil
        }

        return visibleFrame
    }
}
