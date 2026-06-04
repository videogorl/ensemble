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

struct RootSidebarChromeRegistration: Equatable {
    let frame: CGRect?

    static let hidden = RootSidebarChromeRegistration(frame: nil)
}

struct RootSidebarChromeRegistrationPreferenceKey: PreferenceKey {
    static var defaultValue: RootSidebarChromeRegistration = .hidden

    static func reduce(value: inout RootSidebarChromeRegistration, nextValue: () -> RootSidebarChromeRegistration) {
        let next = nextValue()
        if next.frame != nil {
            value = next
        }
    }
}

struct RootSidebarChromeRegistrationView: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: RootSidebarChromeRegistrationPreferenceKey.self,
                value: RootSidebarChromeRegistration(
                    frame: proxy.frame(in: .named(RootChromeCoordinateSpace.name))
                )
            )
        }
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
    static func rootFallback(in proxy: GeometryProxy) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)

        guard rootBounds.width > 0,
              rootBounds.height > 0 else {
            return .hidden
        }

        return RootChromeLayout(
            frame: rootBounds,
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                safeAreaBottom: proxy.safeAreaInsets.bottom
            ),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )
    }

    static func resolve(
        from registration: RootChromeRegistration,
        sidebarRegistration: RootSidebarChromeRegistration,
        in proxy: GeometryProxy
    ) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)
        let resolvedLayout = resolve(from: registration, in: proxy)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return resolvePadLayout(
                from: resolvedLayout,
                rootFallback: rootFallback(in: proxy),
                sidebarFrame: sidebarRegistration.frame,
                rootBounds: rootBounds
            )
        }
        #endif

        let layout = resolvedLayout
        guard layout.showsMiniPlayer,
              layout.hasRenderableFrame,
              let registeredSidebarFrame = sidebarRegistration.frame else {
            return layout
        }

        let sidebarFrame = registeredSidebarFrame.intersection(rootBounds)

        guard sidebarFrame.width >= 80,
              sidebarFrame.height > 0 else {
            return layout
        }

        guard sidebarFrame.minX <= rootBounds.minX + 2,
              abs(sidebarFrame.maxX - layout.frame.minX) <= 2 else {
            return layout
        }

        let detailMinX = max(rootBounds.minX, min(sidebarFrame.maxX, rootBounds.maxX))
        let detailWidth = rootBounds.maxX - detailMinX
        guard detailWidth >= min(320, rootBounds.width * 0.5) else {
            return layout
        }

        return RootChromeLayout(
            frame: CGRect(
                x: detailMinX,
                y: rootBounds.minY,
                width: detailWidth,
                height: rootBounds.height
            ),
            bottomPadding: layout.bottomPadding,
            horizontalOffset: 0,
            showsMiniPlayer: layout.showsMiniPlayer
        )
    }

    static func resolvePadLayout(
        from resolvedLayout: RootChromeLayout,
        rootFallback: RootChromeLayout,
        sidebarFrame registeredSidebarFrame: CGRect?,
        rootBounds: CGRect
    ) -> RootChromeLayout {
        guard resolvedLayout.showsMiniPlayer,
              resolvedLayout.hasRenderableFrame else {
            return resolvedLayout
        }

        let layout = anchorMiniPlayerVertically(resolvedLayout, to: rootBounds)

        guard let registeredSidebarFrame else {
            return rootFallback
        }

        let sidebarFrame = registeredSidebarFrame.intersection(rootBounds)

        guard sidebarFrame.width >= 80,
              sidebarFrame.height > 0 else {
            return rootFallback
        }

        guard sidebarFrame.minX <= rootBounds.minX + 2,
              abs(sidebarFrame.maxX - layout.frame.minX) <= 2 else {
            return rootFallback
        }

        let detailMinX = max(rootBounds.minX, min(sidebarFrame.maxX, rootBounds.maxX))
        let detailWidth = rootBounds.maxX - detailMinX
        guard detailWidth >= min(320, rootBounds.width * 0.5) else {
            return rootFallback
        }

        return RootChromeLayout(
            frame: CGRect(
                x: detailMinX,
                y: rootBounds.minY,
                width: detailWidth,
                height: rootBounds.height
            ),
            bottomPadding: layout.bottomPadding,
            horizontalOffset: 0,
            showsMiniPlayer: layout.showsMiniPlayer
        )
    }

    static func anchorMiniPlayerVertically(
        _ layout: RootChromeLayout,
        to rootBounds: CGRect
    ) -> RootChromeLayout {
        guard layout.showsMiniPlayer,
              layout.hasRenderableFrame,
              rootBounds.width > 0,
              rootBounds.height > 0 else {
            return layout
        }

        return RootChromeLayout(
            frame: CGRect(
                x: layout.frame.minX,
                y: rootBounds.minY,
                width: layout.frame.width,
                height: rootBounds.height
            ),
            bottomPadding: layout.bottomPadding,
            horizontalOffset: layout.horizontalOffset,
            showsMiniPlayer: layout.showsMiniPlayer
        )
    }

    static func resolve(
        from registration: RootChromeRegistration,
        in proxy: GeometryProxy
    ) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)

        guard rootBounds.width > 0,
              rootBounds.height > 0 else {
            return .hidden
        }

        guard registration.bounds != nil || registration.resolvedFrame != nil else {
            return rootFallback(in: proxy)
        }

        let registeredFrame: CGRect
        if let resolvedFrame = registration.resolvedFrame {
            registeredFrame = resolvedFrame
        } else if let bounds = registration.bounds {
            registeredFrame = proxy[bounds]
        } else {
            registeredFrame = rootBounds
        }

        let visibleFrame = registeredFrame.intersection(rootBounds)

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
}
