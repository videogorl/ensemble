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
    let fallbackWidth: CGFloat?
    let isVisible: Bool
    let isPresent: Bool
    let priority: Int

    static let inferredPriority = 10
    static let measuredPriority = 100

    static let absent = RootSidebarChromeRegistration(
        frame: nil,
        fallbackWidth: nil,
        isVisible: false,
        isPresent: false,
        priority: .min
    )

    static let hidden = RootSidebarChromeRegistration(
        frame: nil,
        fallbackWidth: nil,
        isVisible: false,
        isPresent: true,
        priority: .min
    )

    static func visible(
        frame: CGRect? = nil,
        fallbackWidth: CGFloat? = nil,
        priority: Int = measuredPriority
    ) -> RootSidebarChromeRegistration {
        RootSidebarChromeRegistration(
            frame: frame,
            fallbackWidth: fallbackWidth,
            isVisible: true,
            isPresent: true,
            priority: priority
        )
    }

    static func stabilized(
        current: RootSidebarChromeRegistration,
        next: RootSidebarChromeRegistration,
        rootSizeChanged: Bool
    ) -> RootSidebarChromeRegistration {
        guard next.isPresent else {
            return current
        }

        guard next.isVisible else {
            return .hidden
        }

        guard current.isVisible,
              !rootSizeChanged else {
            return next
        }

        if next.priority > current.priority {
            return next
        }

        if current.frame == nil,
           next.frame != nil,
           next.priority == current.priority {
            return next
        }

        return current
    }
}

struct RootSidebarChromeRegistrationPreferenceKey: PreferenceKey {
    static var defaultValue: RootSidebarChromeRegistration = .absent

    static func reduce(value: inout RootSidebarChromeRegistration, nextValue: () -> RootSidebarChromeRegistration) {
        let next = nextValue()
        guard next.isPresent else {
            return
        }

        guard next.isVisible else {
            if !value.isVisible {
                value = next
            }
            return
        }

        if !value.isVisible || next.priority > value.priority {
            value = next
        }
    }
}

struct RootSidebarChromeRegistrationView: View {
    var isVisible = true
    var resolvedFrame: CGRect?
    var fallbackWidth: CGFloat?
    var usesGeometry = true
    var priority = RootSidebarChromeRegistration.measuredPriority

    var body: some View {
        if let resolvedFrame {
            Color.clear.preference(
                key: RootSidebarChromeRegistrationPreferenceKey.self,
                value: isVisible
                    ? .visible(frame: resolvedFrame, fallbackWidth: fallbackWidth, priority: priority)
                    : .hidden
            )
        } else if isVisible && usesGeometry {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RootSidebarChromeRegistrationPreferenceKey.self,
                    value: .visible(
                        frame: proxy.frame(in: .named(RootChromeCoordinateSpace.name)),
                        fallbackWidth: fallbackWidth,
                        priority: priority
                    )
                )
            }
        } else {
            Color.clear.preference(
                key: RootSidebarChromeRegistrationPreferenceKey.self,
                value: isVisible
                    ? .visible(fallbackWidth: fallbackWidth, priority: priority)
                    : .hidden
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
    static let defaultPadSidebarWidth: CGFloat = 260

    static func rootFallback(in proxy: GeometryProxy) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)

        guard rootBounds.width > 0,
              rootBounds.height > 0 else {
            return .hidden
        }

        return RootChromeLayout(
            frame: rootBounds,
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(),
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
                sidebarRegistration: sidebarRegistration,
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
        sidebarRegistration: RootSidebarChromeRegistration,
        rootBounds: CGRect
    ) -> RootChromeLayout {
        guard rootFallback.showsMiniPlayer,
              rootFallback.hasRenderableFrame else {
            return resolvedLayout
        }

        guard resolvedLayout.showsMiniPlayer || !resolvedLayout.hasRenderableFrame else {
            return resolvedLayout
        }

        let contentFrame: CGRect?
        if sidebarRegistration.isVisible {
            contentFrame = sidebarRegistration.frame.flatMap {
                padContentFrame(rootBounds: rootBounds, sidebarFrame: $0)
            } ?? sidebarRegistration.fallbackWidth.flatMap {
                padContentFrame(rootBounds: rootBounds, sidebarWidth: $0)
            }
        } else if sidebarRegistration.isPresent {
            contentFrame = nil
        } else {
            contentFrame = padContentFrame(
                rootBounds: rootBounds,
                detailFrame: resolvedLayout.frame
            )
        }

        guard let contentFrame else { return rootFallback }

        return RootChromeLayout(
            frame: contentFrame,
            bottomPadding: rootFallback.bottomPadding,
            horizontalOffset: 0,
            showsMiniPlayer: rootFallback.showsMiniPlayer
        )
    }

    private static func padContentFrame(rootBounds: CGRect, sidebarWidth: CGFloat) -> CGRect? {
        guard sidebarWidth >= 80 else { return nil }

        return padContentFrame(
            rootBounds: rootBounds,
            sidebarFrame: CGRect(
                x: rootBounds.minX,
                y: rootBounds.minY,
                width: min(sidebarWidth, rootBounds.width),
                height: rootBounds.height
            )
        )
    }

    private static func padContentFrame(rootBounds: CGRect, detailFrame: CGRect) -> CGRect? {
        let visibleDetailFrame = detailFrame.intersection(rootBounds)
        guard visibleDetailFrame.width > 0,
              visibleDetailFrame.height > 0,
              visibleDetailFrame.minX > rootBounds.minX + 80 else {
            return nil
        }

        let contentMinX = max(rootBounds.minX, min(visibleDetailFrame.minX, rootBounds.maxX))
        let contentWidth = rootBounds.maxX - contentMinX
        guard contentWidth >= min(320, rootBounds.width * 0.5) else {
            return nil
        }

        return CGRect(
            x: contentMinX,
            y: rootBounds.minY,
            width: contentWidth,
            height: rootBounds.height
        )
    }

    private static func padContentFrame(rootBounds: CGRect, sidebarFrame registeredSidebarFrame: CGRect) -> CGRect? {
        let sidebarFrame = registeredSidebarFrame.intersection(rootBounds)

        guard sidebarFrame.width >= 80,
              sidebarFrame.height > 0,
              sidebarFrame.minX <= rootBounds.minX + 2 else {
            return nil
        }

        let contentMinX = max(rootBounds.minX, min(sidebarFrame.maxX, rootBounds.maxX))
        let contentWidth = rootBounds.maxX - contentMinX
        guard contentWidth >= min(320, rootBounds.width * 0.5) else {
            return nil
        }

        return CGRect(
            x: contentMinX,
            y: rootBounds.minY,
            width: contentWidth,
            height: rootBounds.height
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
