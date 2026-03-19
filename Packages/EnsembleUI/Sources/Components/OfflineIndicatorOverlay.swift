import EnsembleCore
import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - Device Style Classification

/// Determines which indicator style to use based on the device's hardware
private enum DeviceStyle {
    case dynamicIsland  // iPhone 14 Pro and later
    case notch          // iPhone X through iPhone 14
    case classic        // iPhone SE, iPhone 8 and older

    #if os(iOS)
    init(topInset: CGFloat) {
        if topInset >= 59 {
            self = .dynamicIsland
        } else if topInset >= 44 {
            self = .notch
        } else {
            self = .classic
        }
    }
    #endif
}

// MARK: - UIScreen Extensions (Private API with Fallbacks)

#if os(iOS)
extension UIScreen {
    /// Display corner radius via private `_displayCornerRadius` property.
    /// Falls back to 47pt (iPhone 12 series default) if unavailable.
    var displayCornerRadius: CGFloat {
        let key = ["Radius", "Corner", "display", "_"].reversed().joined()
        return (value(forKey: key) as? CGFloat) ?? 47
    }

    /// Sensor exclusion area (notch/Dynamic Island cutout) via private `_exclusionArea` method.
    /// Returns nil if the API is unavailable.
    var exclusionRect: CGRect? {
        let selectorName = ["Area", "exclusion", "_"].reversed().joined()
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector) else { return nil }

        // The method returns a CGRect directly
        typealias ExclusionMethod = @convention(c) (AnyObject, Selector) -> CGRect
        let method = unsafeBitCast(self.method(for: selector), to: ExclusionMethod.self)
        let rect = method(self, selector)

        // Validate: zero rect means no cutout
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
#endif

// MARK: - Offline Indicator Overlay

/// Device-aware offline connectivity indicator that uses hardware features
/// (Dynamic Island, notch, status bar area) to show connectivity status
/// without consuming layout space. Renders as an overlay in the safe area.
public struct OfflineIndicatorOverlay: View {
    let networkState: NetworkState
    let topInset: CGFloat

    public init(networkState: NetworkState, topInset: CGFloat) {
        self.networkState = networkState
        self.topInset = topInset
    }

    public var body: some View {
        #if os(iOS)
        if shouldShow {
            indicatorView
                .allowsHitTesting(false)
                .ignoresSafeArea(.all, edges: .top)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: shouldShow)
                .animation(.easeInOut(duration: 0.3), value: indicatorColor)
        }
        #endif
    }

    private var shouldShow: Bool {
        // Hide in landscape (top inset drops to 0 when notch/DI is on the side)
        guard topInset > 0 else { return false }
        return isOfflineOrLimited
    }

    private var isOfflineOrLimited: Bool {
        switch networkState {
        case .offline, .limited:
            return true
        case .online, .unknown:
            return false
        }
    }

    private var indicatorColor: Color {
        switch networkState {
        case .offline:
            return Color.orange
        case .limited:
            return Color.yellow
        case .online, .unknown:
            return Color.clear
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var indicatorView: some View {
        let style = DeviceStyle(topInset: topInset)
        switch style {
        case .dynamicIsland:
            DynamicIslandIndicator(color: indicatorColor)
        case .notch:
            NotchIndicator(color: indicatorColor)
        case .classic:
            ClassicStatusBarIndicator(color: indicatorColor, height: topInset)
        }
    }
    #endif
}

// MARK: - Dynamic Island Indicator

#if os(iOS)
/// Draws a capsule stroke around the Dynamic Island cutout
private struct DynamicIslandIndicator: View {
    let color: Color

    /// Known DI pill dimensions (points) by screen width, covering all Dynamic Island iPhones.
    /// When `_exclusionArea` returns unreliable values we fall back to these.
    private static func defaultDIDimensions(screenWidth: CGFloat) -> (width: CGFloat, height: CGFloat, y: CGFloat) {
        switch screenWidth {
        case ...375:
            // iPhone 16e (compact DI)
            return (width: 120, height: 35, y: 11)
        case 376...393:
            // iPhone 14 Pro / 15 / 16 series (6.1")
            return (width: 126, height: 37, y: 11)
        default:
            // iPhone 14 Pro Max / 15 Plus / 16 Plus/Pro Max (6.7")
            return (width: 126, height: 37, y: 11)
        }
    }

    var body: some View {
        let screen = UIScreen.main
        let defaults = Self.defaultDIDimensions(screenWidth: screen.bounds.width)
        let cutout = screen.exclusionRect

        // Use exclusion rect only when its dimensions are plausible (> 50pt wide),
        // otherwise fall back to device-specific defaults. `_exclusionArea` can return
        // very small rects on some OS versions (sensor area, not the visible pill).
        let diWidth: CGFloat = (cutout.map { $0.width > 50 ? $0.width : nil } ?? nil) ?? defaults.width
        let diHeight: CGFloat = (cutout.map { $0.height > 20 ? $0.height : nil } ?? nil) ?? defaults.height
        let diY: CGFloat = (cutout.map { $0.minY > 0 ? $0.minY : nil } ?? nil) ?? defaults.y

        Capsule()
            .stroke(color, lineWidth: 1.5)
            .frame(width: diWidth + 4, height: diHeight + 4)
            .offset(y: diY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.all, edges: .top)
    }
}
#endif

// MARK: - Notch Indicator

#if os(iOS)
/// Draws a stroke path that traces the screen corners and notch cutout
private struct NotchIndicator: View {
    let color: Color

    var body: some View {
        GeometryReader { _ in
            let screen = UIScreen.main
            let cornerRadius = screen.displayCornerRadius
            let notchRect = adjustedNotchRect(screen: screen)

            NotchOutlinePath(
                screenWidth: screen.bounds.width,
                cornerRadius: cornerRadius,
                notchRect: notchRect
            )
            .stroke(color, lineWidth: 1.5)
        }
        .ignoresSafeArea(.all, edges: .top)
    }

    /// Adjust the raw exclusion rect to approximate the visible notch dimensions.
    /// The sensor exclusion zone is wider than the visual cutout.
    private func adjustedNotchRect(screen: UIScreen) -> CGRect {
        guard let raw = screen.exclusionRect else {
            // Fallback: estimate notch from screen width
            let width: CGFloat = screen.bounds.width * 0.55
            let height: CGFloat = 34
            return CGRect(
                x: (screen.bounds.width - width) / 2,
                y: 0,
                width: width,
                height: height
            )
        }

        // Scale factors based on device generation
        let widthScale: CGFloat
        let heightFactor: CGFloat
        if screen.bounds.width <= 375 {
            // iPhone X/XS/11 Pro (375pt wide)
            widthScale = 0.95
            heightFactor = 1.0
        } else {
            // iPhone 12/13/14 series
            widthScale = 0.75
            heightFactor = 0.75
        }

        let adjustedWidth = raw.width * widthScale
        let adjustedHeight = raw.height * heightFactor
        return CGRect(
            x: (screen.bounds.width - adjustedWidth) / 2,
            y: 0,
            width: adjustedWidth,
            height: adjustedHeight
        )
    }
}

/// Custom Shape that traces the top edge of the screen, curving into the notch
private struct NotchOutlinePath: Shape {
    let screenWidth: CGFloat
    let cornerRadius: CGFloat
    let notchRect: CGRect

    // Corner radius where the top edge curves down into the notch
    private let notchOuterRadius: CGFloat = 20
    // Corner radius at the bottom corners of the notch (inner corners)
    private let notchInnerRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let notchLeft = notchRect.minX
        let notchRight = notchRect.maxX
        let notchBottom = notchRect.height

        // Start at the top of the left screen corner arc
        path.move(to: CGPoint(x: 0, y: cornerRadius))

        // Left screen corner arc (top-left)
        path.addArc(
            center: CGPoint(x: cornerRadius, y: cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        // Top edge to notch left
        path.addLine(to: CGPoint(x: notchLeft - notchOuterRadius, y: 0))

        // Curve down into notch (left outer corner)
        path.addArc(
            center: CGPoint(x: notchLeft - notchOuterRadius, y: notchOuterRadius),
            radius: notchOuterRadius,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Down the left side of the notch
        path.addLine(to: CGPoint(x: notchLeft, y: notchBottom - notchInnerRadius))

        // Inner left corner of notch bottom
        path.addArc(
            center: CGPoint(x: notchLeft + notchInnerRadius, y: notchBottom - notchInnerRadius),
            radius: notchInnerRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Across the bottom of the notch
        path.addLine(to: CGPoint(x: notchRight - notchInnerRadius, y: notchBottom))

        // Inner right corner of notch bottom
        path.addArc(
            center: CGPoint(x: notchRight - notchInnerRadius, y: notchBottom - notchInnerRadius),
            radius: notchInnerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Up the right side of the notch
        path.addLine(to: CGPoint(x: notchRight, y: notchOuterRadius))

        // Curve back up to the top edge (right outer corner)
        path.addArc(
            center: CGPoint(x: notchRight + notchOuterRadius, y: notchOuterRadius),
            radius: notchOuterRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        // Top edge to right screen corner
        path.addLine(to: CGPoint(x: screenWidth - cornerRadius, y: 0))

        // Right screen corner arc (top-right)
        path.addArc(
            center: CGPoint(x: screenWidth - cornerRadius, y: cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(270),
            endAngle: .degrees(360),
            clockwise: false
        )

        return path
    }
}
#endif

// MARK: - Classic Status Bar Indicator

#if os(iOS)
/// Solid orange fill of the status bar area for devices without a notch
private struct ClassicStatusBarIndicator: View {
    let color: Color
    let height: CGFloat

    var body: some View {
        color
            .frame(height: max(height, 20))
            .frame(maxWidth: .infinity)
    }
}
#endif
