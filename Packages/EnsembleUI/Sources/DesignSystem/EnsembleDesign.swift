import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Semantic design tokens for Ensemble UI surfaces.
///
/// Keep these tokens role-based rather than value-based. A screen should ask for
/// "card spacing" or "toolbar pill material" instead of copying a raw number or
/// material stack from another component.
public enum EnsembleDesign {
    public enum Spacing {
        public static let none: CGFloat = 0
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32

        public static let rowHorizontal: CGFloat = lg
        public static let rowVertical: CGFloat = sm
        public static let rowItemGap: CGFloat = md
        public static let detailGutter: CGFloat = 40
        public static let utilityOuterGutter: CGFloat = detailGutter - rowHorizontal
        public static let cardTextGap: CGFloat = xxs
        public static let cardGridGap: CGFloat = lg
        public static let cardRowGap: CGFloat = xl
        public static let chipHorizontal: CGFloat = md
        public static let chipVertical: CGFloat = 6
        public static let sheetRowVertical: CGFloat = 10
        public static let sheetOuterHorizontal: CGFloat = xxxl
        public static let sheetOuterVertical: CGFloat = 28
        public static let sheetFooterHorizontal: CGFloat = xl
        public static let sheetFooterVertical: CGFloat = md
        public static let sheetSectionPadding: CGFloat = 18
        public static let popoverActionHorizontal: CGFloat = 14
        public static let popoverActionVertical: CGFloat = 9
        public static let compactControlVertical: CGFloat = 10
    }

    public enum Radius {
        public static let control: CGFloat = 10
        public static let compactControl: CGFloat = 8
        public static let card: CGFloat = 12
        public static let sectionCard: CGFloat = 14
        public static let largeCard: CGFloat = 20
        public static let sheet: CGFloat = 20
        public static let chip: CGFloat = 20
        public static let miniPlayer: CGFloat = 28
        public static let toolbarPill: CGFloat = 28

        public static func artworkSquare(for dimension: CGFloat) -> CGFloat {
            guard dimension > 0 else { return 4 }
            return min(max(dimension * 0.08, 4), 20)
        }

        public static func artworkCircle(for dimension: CGFloat) -> CGFloat {
            max(0, dimension / 2)
        }
    }

    public enum Typography {
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

    public enum Color {
        public static let primaryText = SwiftUI.Color.primary
        public static let secondaryText = SwiftUI.Color.secondary
        public static let mutedPrimaryText = SwiftUI.Color.primary.opacity(0.7)
        public static let placeholderText = SwiftUI.Color.secondary
        /// Ambient app accent resolved by SwiftUI.
        ///
        /// On macOS this intentionally follows Apple's accent policy: an explicit
        /// system accent wins, while Multicolor lets the app-provided accent show.
        public static let accent = SwiftUI.Color.accentColor
        public static let accentSelection = SwiftUI.Color.accentColor.opacity(0.12)
        public static let accentBadge = SwiftUI.Color.accentColor.opacity(0.15)
        public static let neutralBadge = SwiftUI.Color.secondary.opacity(0.15)
        public static let secondaryControlFill = SwiftUI.Color.gray.opacity(0.2)
        public static let destructive = SwiftUI.Color.red
        public static let warning = SwiftUI.Color.orange
        public static let pending = SwiftUI.Color.yellow
        public static let success = SwiftUI.Color.green
        public static let neutralStatus = SwiftUI.Color.gray
        public static let favorite = SwiftUI.Color.pink
        public static let generated = SwiftUI.Color.purple
        public static let queueNext = SwiftUI.Color.blue
        public static let queueLast = SwiftUI.Color.indigo
        public static let addToPlaylist = SwiftUI.Color.orange
        public static let onAccent = SwiftUI.Color.white
        public static let onArtwork = SwiftUI.Color.white.opacity(0.9)
        public static let divider = SwiftUI.Color.secondary.opacity(0.18)
        public static let placeholderArtwork = SwiftUI.Color.primary.opacity(0.1)
        public static let placeholderArtworkIcon = SwiftUI.Color.gray.opacity(0.5)
        public static let modalProgressScrim = SwiftUI.Color.black.opacity(0.12)

        public static var groupedSurface: SwiftUI.Color {
            #if os(iOS)
            SwiftUI.Color(UIColor.secondarySystemGroupedBackground)
            #else
            SwiftUI.Color(NSColor.controlBackgroundColor)
            #endif
        }

        public static var windowSurface: SwiftUI.Color {
            #if os(iOS)
            SwiftUI.Color(uiColor: .systemBackground)
            #else
            SwiftUI.Color(nsColor: .windowBackgroundColor)
            #endif
        }
    }

    public enum Icon {
        public static let add = "plus"
        public static let addCircle = "plus.circle.fill"
        public static let addCircleOutline = "plus.circle"
        public static let addToPlaylist = "text.badge.plus"
        public static let removeFromPlaylist = "text.badge.minus"
        public static let album = "square.stack"
        public static let artist = "music.mic"
        public static let artists = artist
        public static let back = "chevron.left"
        public static let chevronDown = "chevron.down"
        public static let chevronRight = "chevron.right"
        public static let chevronUp = "chevron.up"
        public static let checkmark = "checkmark.circle.fill"
        public static let checkmarkOutline = "checkmark.circle"
        public static let cloud = "icloud"
        public static let selectionCheckmark = "checkmark"
        public static let close = "xmark"
        public static let closeCircle = "xmark.circle.fill"
        public static let copy = "doc.on.doc"
        public static let delete = "trash"
        public static let deleteFilled = "trash.fill"
        public static let download = "arrow.down.circle"
        public static let downloaded = "arrow.down.circle.fill"
        public static let dragReorder = "line.3.horizontal"
        public static let dragHandle = "circle.grid.2x3.fill"
        public static let edit = "pencil"
        public static let editCircleFilled = "pencil.circle.fill"
        public static let editPlaylist = "slider.horizontal.3"
        public static let error = "exclamationmark.triangle.fill"
        public static let errorOutline = "exclamationmark.triangle"
        public static let failure = "xmark.octagon.fill"
        public static let externalLink = "arrow.up.forward.app"
        public static let externalLinkSquare = "arrow.up.right.square"
        public static let externalDevice = "externaldrive"
        public static let favorite = "heart"
        public static let favoriteFilled = "heart.fill"
        public static let favoriteRemove = "heart.slash"
        public static let favoriteRemoveFilled = "heart.slash.fill"
        public static let filter = "line.3.horizontal.decrease"
        public static let filterCircle = "line.3.horizontal.decrease.circle"
        public static let filterCircleFilled = "line.3.horizontal.decrease.circle.fill"
        public static let forward = "forward.fill"
        public static let generatedBadge = "sparkles"
        public static let genre = "music.note.list"
        public static let genreEmpty = "guitars"
        public static let genreFilled = "guitars.fill"
        public static let library = "music.note.house.fill"
        public static let libraryBuilding = "building.columns"
        public static let home = "house"
        public static let logs = "doc.text.magnifyingglass"
        public static let logsVerified = "text.badge.checkmark"
        public static let merge = "arrow.triangle.merge"
        public static let mergeBranch = "arrow.triangle.branch"
        public static let more = "ellipsis"
        public static let moreCircle = "ellipsis.circle"
        public static let musicNote = "music.note"
        public static let notification = "bell.fill"
        public static let notificationBadge = "bell.badge"
        public static let next = "forward.fill"
        public static let offline = "wifi.slash"
        public static let recentSearchReuse = "arrow.up.left"
        public static let removeAccounts = "person.2.slash"
        public static let removeCircle = "minus.circle"
        public static let removeCircleFilled = "minus.circle.fill"
        public static let selectionCircle = "circle"
        public static let server = "server.rack"
        public static let pin = "pin.fill"
        public static let playLast = "text.append"
        public static let playNext = "text.insert"
        public static let play = "play.fill"
        public static let playCircleFilled = "play.circle.fill"
        public static let pause = "pause.fill"
        public static let pauseCircleFilled = "pause.circle.fill"
        public static let profile = "person.crop.circle"
        public static let profilePlaceholder = "person.circle"
        public static let playlist = "music.note.list"
        public static let previous = "backward.fill"
        public static let radio = "dot.radiowaves.left.and.right"
        public static let recentPlaylist = "clock.arrow.circlepath"
        public static let refreshCycle = "arrow.triangle.2.circlepath"
        public static let removeDownload = "xmark.circle"
        public static let retry = "arrow.clockwise"
        public static let search = "magnifyingglass"
        public static let settings = "gear"
        public static let signIn = "person.circle.fill"
        public static let shareAudioFile = "square.and.arrow.up"
        public static let shareLink = "link"
        public static let shuffle = "shuffle"
        public static var smartMix: String {
            smartMixIconName(modernSymbolSetAvailable: isModernSmartMixSymbolAvailable)
        }
        public static let smartPlaylist = "gearshape.fill"
        public static let sort = "arrow.up.arrow.down"
        public static let speakerPlayingCompact = "speaker.wave.2.fill"
        public static let speakerPlaying = "speaker.wave.3.fill"
        public static let unpin = "pin.slash"
        public static let aurora = "sparkles"
        public static let autoplay = "infinity.circle.fill"
        public static let scrobble = "checkmark.circle"
        public static let waveform = "waveform"
        public static let secureConnection = "lock.shield"
        public static let info = "info.circle"
        public static let help = "questionmark.circle"
        public static let ticket = "ticket.fill"
        public static let lyrics = "quote.bubble.fill"
        public static let infinity = "infinity"
        public static let clock = "clock"
        public static let unknown = "questionmark.circle"
        public static let libraryStack = "square.stack.3d.up"
        public static let paintPalette = "paintpalette"
        public static let tapGesture = "hand.tap"
        public static let saveQueue = "square.and.arrow.down"
        public static let instrumentalOn = "mic.slash.circle"
        public static let instrumentalOff = "mic.circle"
        public static var chords: String {
            chordIconName(modernSymbolSetAvailable: isModernChordSymbolAvailable)
        }
        public static let lyricsUnavailable = "text.quote"
        public static let scrubFine = "minus"
        public static let scrubUp = "chevron.compact.up"
        public static let scrubDown = "chevron.compact.down"
        public static let trackActions = more
        public static let trackActionsCircle = moreCircle

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

    public enum Breakpoint {
        public static let compactControlMinimumWidth: CGFloat = 430
        public static let detailWideHeader: CGFloat = 620
        public static let browseSplitMinimumWidth: CGFloat = 760
        public static let nowPlayingSinglePanelWidth: CGFloat = 860
        public static let auxiliaryWindowMaxWidth: CGFloat = 420
    }

    public enum Effect {
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

    public enum Animation {
        public static let quickDuration = 0.25
        public static let standardDuration = 0.3
    }

    public enum Material {
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
