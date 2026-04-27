import SwiftUI

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
    }

    public enum Radius {
        public static let control: CGFloat = 10
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
        public static let cardTitle: Font = .subheadline.weight(.medium)
        public static let cardSubtitle: Font = .caption
        public static let cardMetadata: Font = .caption2
        public static let rowPrimary: Font = .body
        public static let rowSecondary: Font = .caption
        public static let actionLabel: Font = .headline
        public static let popoverAction: Font = .body
        public static let emptyStateIcon: Font = .system(size: 60)
        public static let mediaPlaceholderIcon: Font = .system(size: 40)
        public static let miniPlayerTitle: Font = .subheadline.weight(.bold)
        public static let miniPlayerSubtitle: Font = .caption
    }

    public enum Color {
        public static let primaryText = SwiftUI.Color.primary
        public static let secondaryText = SwiftUI.Color.secondary
        public static let mutedPrimaryText = SwiftUI.Color.primary.opacity(0.7)
        public static let placeholderText = SwiftUI.Color.secondary
        public static let accent = SwiftUI.Color.accentColor
        public static let accentSelection = SwiftUI.Color.accentColor.opacity(0.12)
        public static let accentBadge = SwiftUI.Color.accentColor.opacity(0.15)
        public static let neutralBadge = SwiftUI.Color.secondary.opacity(0.15)
        public static let destructive = SwiftUI.Color.red
        public static let warning = SwiftUI.Color.orange
        public static let onAccent = SwiftUI.Color.white
        public static let divider = SwiftUI.Color.secondary.opacity(0.18)
        public static let placeholderArtwork = SwiftUI.Color.primary.opacity(0.1)

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
        public static let addCircle = "plus.circle.fill"
        public static let addToPlaylist = "text.badge.plus"
        public static let album = "square.stack"
        public static let artist = "person.circle"
        public static let back = "chevron.left"
        public static let chevronRight = "chevron.right"
        public static let checkmark = "checkmark.circle.fill"
        public static let selectionCheckmark = "checkmark"
        public static let closeCircle = "xmark.circle.fill"
        public static let delete = "trash"
        public static let download = "arrow.down.circle"
        public static let downloaded = "arrow.down.circle.fill"
        public static let dragHandle = "circle.grid.2x3.fill"
        public static let error = "exclamationmark.triangle.fill"
        public static let favorite = "heart"
        public static let favoriteFilled = "heart.fill"
        public static let favoriteRemove = "heart.slash"
        public static let favoriteRemoveFilled = "heart.slash.fill"
        public static let filter = "line.3.horizontal.decrease"
        public static let forward = "forward.fill"
        public static let genre = "music.note.list"
        public static let library = "music.note.house.fill"
        public static let merge = "arrow.triangle.merge"
        public static let more = "ellipsis"
        public static let musicNote = "music.note"
        public static let next = "forward.fill"
        public static let play = "play.fill"
        public static let playlist = "music.note.list"
        public static let previous = "backward.fill"
        public static let radio = "dot.radiowaves.left.and.right"
        public static let retry = "arrow.clockwise"
        public static let search = "magnifyingglass"
        public static let settings = "gear"
        public static let shuffle = "shuffle"
        public static let smartPlaylist = "gearshape.fill"
        public static let sort = "arrow.up.arrow.down"
        public static let speakerPlaying = "speaker.wave.3.fill"
    }

    public enum Breakpoint {
        public static let compactControlMinimumWidth: CGFloat = 430
        public static let detailWideHeader: CGFloat = 620
        public static let browseSplitMinimumWidth: CGFloat = 760
        public static let nowPlayingSinglePanelWidth: CGFloat = 860
        public static let auxiliaryWindowMaxWidth: CGFloat = 420
    }

    public enum Effect {
        public static let cardShadowColor = SwiftUI.Color.black.opacity(0.15)
        public static let cardShadowRadius: CGFloat = 6
        public static let cardShadowY: CGFloat = 2
        public static let elevatedShadowColor = SwiftUI.Color.black.opacity(0.15)
        public static let elevatedShadowRadius: CGFloat = 20
        public static let elevatedShadowY: CGFloat = 5
    }

    public enum Material {
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
                case .miniPlayer, .toolbarPill, .floatingControl:
                    return .ultraThinMaterial
                case .sheet:
                    return .regularMaterial
                case .detailSurface, .sidebar, .popover, .selection:
                    return .thinMaterial
                }
            }

            var tintOpacity: Double {
                switch self {
                case .miniPlayer:
                    return 0
                case .toolbarPill, .floatingControl:
                    return 0.04
                case .sheet, .detailSurface, .sidebar, .popover:
                    return 0.02
                case .selection:
                    return 0.12
                }
            }

            var strokeOpacity: Double {
                switch self {
                case .miniPlayer:
                    return 0.10
                case .toolbarPill, .floatingControl:
                    return 0.08
                case .sheet, .detailSurface, .sidebar, .popover:
                    return 0.06
                case .selection:
                    return 0
                }
            }

            var shadowRadius: CGFloat {
                switch self {
                case .miniPlayer:
                    return EnsembleDesign.Effect.elevatedShadowRadius
                case .toolbarPill, .floatingControl, .popover:
                    return 12
                case .sheet, .detailSurface, .sidebar, .selection:
                    return 0
                }
            }

            var shadowY: CGFloat {
                switch self {
                case .miniPlayer:
                    return EnsembleDesign.Effect.elevatedShadowY
                case .toolbarPill, .floatingControl:
                    return 3
                case .popover:
                    return 4
                case .sheet, .detailSurface, .sidebar, .selection:
                    return 0
                }
            }

            var shadowColor: SwiftUI.Color {
                switch self {
                case .popover:
                    return SwiftUI.Color.black.opacity(0.18)
                default:
                    return EnsembleDesign.Effect.elevatedShadowColor
                }
            }

            var prefersLiquidGlass: Bool {
                switch self {
                case .miniPlayer, .toolbarPill, .floatingControl:
                    return true
                case .sheet, .detailSurface, .sidebar, .popover, .selection:
                    return false
                }
            }
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
