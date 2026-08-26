import EnsembleCore
import EnsembleDesignTokens
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension EnsembleDesign {
    enum Performance {
        /// Legacy and 2 GB-class devices need simpler compositing during dense
        /// scroll/navigation/Now Playing transitions.
        public static var prefersReducedVisualEffects: Bool {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return os.majorVersion <= 15 || ProcessInfo.processInfo.physicalMemory <= 2_500_000_000
        }
    }

    enum Typography {
        public static let screenTitle: Font = .largeTitle.weight(.bold)
        public static let sectionTitle: Font = .title2.weight(.bold)
        public static let detailSubtitle: Font = .title3
        public static let cardTitle: Font = .subheadline.weight(.medium)
        public static let cardSubtitle: Font = .caption
        public static let cardMetadata: Font = .caption2
        public static let chipLabel: Font = .subheadline
        public static let rowPrimary: Font = .body
        public static let rowSecondary: Font = .caption
        public static let toastTitle: Font = .subheadline.weight(.semibold)
        public static let toastMessage: Font = .caption
        public static let toastAction: Font = .caption.weight(.semibold)
        public static let profileName: Font = .title2.bold()
        public static let profilePlaceholderName: Font = .title2
        public static let stateTitle: Font = .title2.weight(.semibold)
        public static let stateMessage: Font = .subheadline
        public static let actionLabel: Font = .headline
        public static let actionIcon: Font = .headline
        public static let toolbarTitle: Font = .headline
        public static let browseSectionHeader: Font = .headline
        public static let popoverAction: Font = .body
        public static let overflowIcon: Font = .system(size: 11, weight: .semibold)
        public static let emptyStateIcon: Font = .system(size: 60)
        public static let mediaPlaceholderIcon: Font = .system(size: 40)
        public static let miniPlayerTitle: Font = .subheadline.weight(.bold)
        public static let miniPlayerSubtitle: Font = .caption
        public static let utilityIcon: Font = .title2
        public static let statusBadgeIcon: Font = .caption2
    }

    enum Breakpoint {
        public static let compactControlMinimumWidth: CGFloat = 430
        public static let detailWideHeader: CGFloat = 620
        public static let browseSplitMinimumWidth: CGFloat = 760
        public static let nowPlayingSinglePanelWidth: CGFloat = 860
        public static let auxiliaryWindowMaxWidth: CGFloat = 420
    }

    enum Effect {
        public static let shadowColor = SwiftUI.Color.black.opacity(0.15)
        public static let shadowRadius: CGFloat = 6
        public static let shadowX: CGFloat = 0
        public static let shadowY: CGFloat = 2

        public static let cardShadowColor = shadowColor
        public static let cardShadowRadius = shadowRadius
        public static let cardShadowY = shadowY
        public static let elevatedShadowColor = shadowColor
        public static let elevatedShadowRadius = shadowRadius
        public static let elevatedShadowY = shadowY
    }

    enum Animation {
        public static let quickDuration = 0.25
        public static let standardDuration = 0.3
    }

    enum Material {
        public enum FloatingGlass {
            public static let fallbackMaterial = SwiftUI.Material.ultraThinMaterial
            public static let tintOpacity: Double = 0
            public static let strokeOpacity: Double = 0.10
            public static let shadowRadius = EnsembleDesign.Effect.shadowRadius
            public static let shadowY = EnsembleDesign.Effect.shadowY
            public static let shadowColor = EnsembleDesign.Effect.shadowColor

            #if canImport(UIKit)
            public static let chromeBlurStyle = UIBlurEffect.Style.systemUltraThinMaterial
            public static let chromeBackgroundAlpha: CGFloat = 0.85
            #endif
        }

        public enum Role {
            case miniPlayer
            case toolbarPill
            case floatingControl
            case sheet
            case detailSurface
            case sidebar
            case popover
            case selection

            var fallbackMaterial: SwiftUI.Material {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.fallbackMaterial
                case .sheet:
                    return .regularMaterial
                case .detailSurface, .sidebar, .selection:
                    return .thinMaterial
                }
            }

            var tintOpacity: Double {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.tintOpacity
                case .sheet, .detailSurface, .sidebar:
                    return 0.02
                case .selection:
                    return 0.12
                }
            }

            var strokeOpacity: Double {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.strokeOpacity
                case .sheet, .detailSurface, .sidebar:
                    return 0.06
                case .selection:
                    return 0
                }
            }

            var shadowRadius: CGFloat {
                switch self {
                case .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.shadowRadius
                case .miniPlayer:
                    return EnsembleDesign.Material.FloatingGlass.shadowRadius
                case .sheet, .detailSurface, .sidebar, .selection:
                    return 0
                }
            }

            var shadowY: CGFloat {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.shadowY
                case .sheet, .detailSurface, .sidebar, .selection:
                    return 0
                }
            }

            var shadowColor: SwiftUI.Color {
                EnsembleDesign.Material.FloatingGlass.shadowColor
            }

            var fallbackBackgroundColor: SwiftUI.Color {
                switch self {
                case .sheet:
                    return EnsembleDesign.Color.windowSurface
                case .detailSurface, .sidebar:
                    return EnsembleDesign.Color.groupedSurface
                case .selection:
                    return EnsembleDesign.Color.accentSelection
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return SwiftUI.Color.clear
                }
            }

            #if canImport(UIKit)
            var chromeBlurStyle: UIBlurEffect.Style {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return EnsembleDesign.Material.FloatingGlass.chromeBlurStyle
                case .sheet, .detailSurface, .sidebar, .selection:
                    return .systemChromeMaterial
                }
            }

            func chromeBackgroundAlpha(auroraEnabled: Bool) -> CGFloat {
                switch self {
                case .sidebar:
                    return auroraEnabled ? 0.3 : 0.85
                case .miniPlayer, .toolbarPill, .floatingControl, .sheet, .detailSurface, .popover, .selection:
                    return EnsembleDesign.Material.FloatingGlass.chromeBackgroundAlpha
                }
            }
            #endif

            var prefersLiquidGlass: Bool {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl, .popover:
                    return true
                case .sheet, .detailSurface, .sidebar, .selection:
                    return false
                }
            }
        }
    }
}

public extension EnsembleDesign.Color {
    static var groupedSurface: SwiftUI.Color {
        #if os(iOS)
        SwiftUI.Color(UIColor.secondarySystemGroupedBackground)
        #else
        SwiftUI.Color(NSColor.controlBackgroundColor)
        #endif
    }

    static var windowSurface: SwiftUI.Color {
        #if os(iOS)
        SwiftUI.Color(uiColor: .systemBackground)
        #else
        SwiftUI.Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

public extension EnsembleDesign.Icon {
    static var smartMix: String {
        smartMixIconName(modernSymbolSetAvailable: isModernSmartMixSymbolAvailable)
    }

    static var chords: String {
        chordIconName(modernSymbolSetAvailable: isModernChordSymbolAvailable)
    }
}

extension EnsembleDesign.Icon {
    static func chordIconName(modernSymbolSetAvailable: Bool) -> String {
        modernSymbolSetAvailable ? "apple.classical.pages" : "music.note.list"
    }

    static func smartMixIconName(modernSymbolSetAvailable: Bool) -> String {
        modernSymbolSetAvailable ? "circle.dotted.and.circle" : "sparkles"
    }

    private static var isModernChordSymbolAvailable: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) { return true }
        return false
        #elseif os(macOS)
        if #available(macOS 13.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    private static var isModernSmartMixSymbolAvailable: Bool {
        #if canImport(UIKit)
        return UIImage(systemName: "circle.dotted.and.circle") != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: "circle.dotted.and.circle", accessibilityDescription: nil) != nil
        #else
        return false
        #endif
    }
}

public extension TabItem {
    var designSystemImage: String {
        switch self {
        case .home:
            return EnsembleDesign.Icon.home
        case .songs:
            return EnsembleDesign.Icon.musicNote
        case .artists:
            return EnsembleDesign.Icon.artist
        case .albums:
            return EnsembleDesign.Icon.album
        case .genres:
            return EnsembleDesign.Icon.genreEmpty
        case .playlists:
            return EnsembleDesign.Icon.playlist
        case .favorites:
            return EnsembleDesign.Icon.favorite
        case .search:
            return EnsembleDesign.Icon.search
        case .downloads:
            return EnsembleDesign.Icon.download
        case .settings:
            return EnsembleDesign.Icon.settings
        }
    }
}

/// Primary filled button style for scaffold-level actions such as empty states.
public struct EnsemblePrimaryActionButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EnsembleDesign.Typography.actionLabel)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, EnsembleDesign.Spacing.xl)
            .padding(.vertical, EnsembleDesign.Spacing.md)
            .background(EnsembleDesign.Color.accent)
            .foregroundColor(EnsembleDesign.Color.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: EnsembleDesign.Radius.card, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

public extension View {
    func ensembleFont(_ font: Font) -> some View {
        self.font(font)
    }

    func ensembleMaterial(
        _ role: EnsembleDesign.Material.Role,
        cornerRadius: CGFloat,
        strokeColor: Color = .primary
    ) -> some View {
        modifier(EnsembleMaterialModifier(role: role, cornerRadius: cornerRadius, strokeColor: strokeColor))
    }

    func ensembleCapsuleMaterial(
        _ role: EnsembleDesign.Material.Role,
        strokeColor: Color = .primary
    ) -> some View {
        modifier(EnsembleCapsuleMaterialModifier(role: role, strokeColor: strokeColor))
    }
}

private struct EnsembleMaterialModifier: ViewModifier {
    let role: EnsembleDesign.Material.Role
    let cornerRadius: CGFloat
    let strokeColor: Color

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *), role.prefersLiquidGlass {
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(role.fallbackMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(EnsembleDesign.Color.accent.opacity(role.tintOpacity))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(strokeColor.opacity(role.strokeOpacity), lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(
                    color: role.shadowColor,
                    radius: role.shadowRadius,
                    y: role.shadowY
                )
        }
    }
}

private struct EnsembleCapsuleMaterialModifier: ViewModifier {
    let role: EnsembleDesign.Material.Role
    let strokeColor: Color

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *), role.prefersLiquidGlass {
            content
                .clipShape(Capsule())
                .glassEffect(in: .capsule)
        } else {
            content
                .background(
                    Capsule()
                        .fill(role.fallbackMaterial)
                        .overlay(
                            Capsule()
                                .fill(EnsembleDesign.Color.accent.opacity(role.tintOpacity))
                        )
                        .overlay(
                            Capsule()
                                .stroke(strokeColor.opacity(role.strokeOpacity), lineWidth: 1)
                        )
                )
                .clipShape(Capsule())
                .shadow(
                    color: role.shadowColor,
                    radius: role.shadowRadius,
                    y: role.shadowY
                )
        }
    }
}
