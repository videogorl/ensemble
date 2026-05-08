import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Shared adaptive UI patterns that sit above raw design tokens.
public enum EnsembleScaffold {
    public enum Chip {
        public static let horizontalPadding = EnsembleDesign.Spacing.chipHorizontal
        public static let verticalPadding = EnsembleDesign.Spacing.chipVertical
        public static let rowSpacing = EnsembleDesign.Spacing.sm
        public static let barHeight: CGFloat = 36
        public static let clearButtonIconSize: CGFloat = 14
        public static let badgeVerticalPadding: CGFloat = 3
        public static let badgeHorizontalPadding = EnsembleDesign.Spacing.sm
        public static let iconBadgeHorizontalPadding = EnsembleDesign.Spacing.chipVertical
        public static let borderWidth: CGFloat = 1
    }

    public enum MediaCard {
        public static let textSpacing = EnsembleDesign.Spacing.cardTextGap
        public static let contentSpacing = EnsembleDesign.Spacing.sm
        public static let gridSpacing = EnsembleDesign.Spacing.cardGridGap
        public static let rowSpacing = EnsembleDesign.Spacing.cardRowGap
        public static let hubArtworkDimension: CGFloat = 140
        public static let hubShadowY = EnsembleDesign.Effect.shadowY
        public static let horizontalScrollMetadataHeight: CGFloat = 78
        public static let metadataTextHeight: CGFloat = 66
        public static let compactColumnMinimum: CGFloat = 100
        public static let compactColumnMaximum: CGFloat = 140
        public static let shelfColumnMinimum: CGFloat = 140
        public static let shelfColumnMaximum: CGFloat = 180
        public static let prominentColumnMinimum: CGFloat = 136
        public static let prominentColumnMaximum: CGFloat = 172
        public static let personColumnMaximum: CGFloat = 120
        public static let genreGradientTopOpacity = 0.8
        public static let genreGradientBottomOpacity = 0.4
        public static let genreHashMultiplier = 31
        public static let genrePalette: [Color] = [
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo
        ]

        public static var personGridColumns: [GridItem] {
            [
                GridItem(
                    .adaptive(minimum: compactColumnMinimum, maximum: personColumnMaximum),
                    spacing: gridSpacing,
                    alignment: .top
                )
            ]
        }
    }

    public enum Toast {
        public static let hiddenHostDimension = EnsembleDesign.Spacing.none
        public static let iconTextSpacing: CGFloat = 10
        public static let textSpacing = EnsembleDesign.Spacing.xxs
        public static let trailingSpacerMinLength = EnsembleDesign.Spacing.sm
        public static let hostHorizontalPadding = EnsembleDesign.Spacing.lg
        public static let hostBottomPadding = EnsembleDesign.Spacing.lg
        public static let globalHorizontalPadding = EnsembleDesign.Spacing.xl
        public static let horizontalPadding: CGFloat = 14
        public static let verticalPadding = EnsembleDesign.Spacing.md
        public static let borderOpacity = 0.4
    }

    public enum Marquee {
        public static let duplicateTextSpacing: CGFloat = 50
        public static let fadeWidth = EnsembleDesign.Spacing.xxl
        public static let fallbackLineHeight = EnsembleDesign.Spacing.xxl
        public static let preferredLineHeightMultiplier: CGFloat = 1.5
        public static let measurementOpacity = EnsembleDesign.Spacing.none
    }

    public enum Waveform {
        public static let emptyBarCount = 40
        public static let emptyBarHeightRatio = 0.2
        public static let barSpacing: CGFloat = 1
        public static let barCornerRadius: CGFloat = 1
        public static let minimumBarHeight = EnsembleDesign.Spacing.xxs
        public static let bufferedOpacity = 0.35
        public static let idleOpacity = 0.12
    }

    public enum ProfileHeader {
        public static let contentSpacing = EnsembleDesign.Spacing.md
        public static let verticalPadding = EnsembleDesign.Spacing.xxl
        public static let imageDimension: CGFloat = 120
        public static let nameSpacing = EnsembleDesign.Spacing.xs
        public static let placeholderOpacity = 0.5
        public static let imageLoadingOpacity = 0.2
        public static let accentSwatchDimension: CGFloat = 30
        public static let accentSwatchSelectionDimension: CGFloat = 36
        public static let accentSwatchSelectionLineWidth: CGFloat = 2
    }

    public enum ProfileToolbar {
        public static let imageDimension: CGFloat = 28
    }

    public enum Sidebar {
        public static let artworkDimension: CGFloat = 22
    }

    public enum BrowseToolbar {
        public static let itemSpacing = EnsembleDesign.Spacing.lg
        public static let activeBadgeSize = EnsembleDesign.Spacing.sm
        public static let activeBadgeOffset = EnsembleDesign.Spacing.xxs
    }

    public enum BrowseSectionHeader {
        public static let verticalPadding = EnsembleDesign.Spacing.sm
        public static let horizontalPadding = EnsembleDesign.Spacing.lg
        public static let backgroundOpacity = 0.9
    }

    public enum BrowseSelection {
        public static let horizontalPadding = EnsembleDesign.Spacing.lg
        public static let verticalPadding = EnsembleDesign.Spacing.sm
        public static let outerHorizontalPadding = EnsembleDesign.Spacing.sm
        public static let cornerRadius = EnsembleDesign.Radius.compactControl
        public static let fillColor = EnsembleDesign.Material.Role.selection.fallbackBackgroundColor
    }

    public enum VirtualDetailHeader {
        public static let heroIconSize: CGFloat = 80
        public static let heroArtworkDimension: CGFloat = 140
        public static let symbolBackgroundOpacity = 0.16
    }

    public enum Favorites {
        public static let heroIconSize = EnsembleScaffold.VirtualDetailHeader.heroIconSize
        public static let heroArtworkDimension = EnsembleScaffold.VirtualDetailHeader.heroArtworkDimension
        public static let heroTopPadding = EnsembleDesign.Spacing.xl
        public static let headerBottomPadding = EnsembleDesign.Spacing.xl
        public static let metadataSpacing = EnsembleDesign.Spacing.xs
    }

    public enum MoodDetail {
        public static let heroIconSize = EnsembleScaffold.VirtualDetailHeader.heroIconSize
        public static let heroArtworkDimension = EnsembleScaffold.VirtualDetailHeader.heroArtworkDimension
        public static let backgroundHeight: CGFloat = 400
        public static let backgroundStrongOpacity = 0.6
        public static let backgroundSoftOpacity = 0.3
        public static let symbolBackgroundOpacity = EnsembleScaffold.VirtualDetailHeader.symbolBackgroundOpacity
    }

    public enum Genres {
        public static let iconLaneWidth = EnsembleScaffold.UtilityRow.iconLaneWidth
        public static let detailHeaderSpacing = EnsembleDesign.Spacing.xs
    }

    public enum Discovery {
        public static let sectionSpacing = EnsembleDesign.Spacing.xxl
        public static let exploreSectionSpacing = EnsembleDesign.Spacing.xxxl
        public static let subsectionSpacing = EnsembleDesign.Spacing.md
        public static let gridSpacing = EnsembleDesign.Spacing.lg
        public static let loadingPlaceholderHeight: CGFloat = 200
        public static let loadingVerticalPadding = EnsembleDesign.Spacing.xl
        public static let recentSearchRowHeight = EnsembleScaffold.UtilityRow.artworkDimension
        public static let recentSearchExtraHeight = EnsembleDesign.Spacing.lg
        public static let recentSearchCornerRadius = EnsembleDesign.Radius.control
        public static let editControlTrailingPadding = EnsembleDesign.Spacing.xs
        public static let editingBadgeOffset = EnsembleDesign.Spacing.sm
    }

    public enum ArtistDetail {
        public static let wideHeaderThreshold: CGFloat = 700
        public static let backgroundHeight: CGFloat = 600
        public static let wideArtworkDimension: CGFloat = 240
        public static let wideActionMaxWidth: CGFloat = 520
        public static let wideHeaderTopPadding: CGFloat = 72
        public static let toolbarChromeRevealHeight: CGFloat = 44
        public static let sectionTopPadding: CGFloat = 32
        public static let loadingTopPadding = TrackListLayoutMetrics.detailHorizontalPadding
        public static let compactActionTopPadding = EnsembleDesign.Spacing.xxl
        public static let metadataSpacing = EnsembleDesign.Spacing.sm
        public static let factsSpacing = EnsembleDesign.Spacing.chipVertical
        public static let descriptionSpacing = EnsembleDesign.Spacing.sm
        public static let aboutSpacing = EnsembleDesign.Spacing.lg
        public static let factLabelWidth: CGFloat = 50
        public static let actionIconDimension = EnsembleScaffold.UtilityRow.iconLaneWidth
        public static let wideArtworkShadowColor = EnsembleDesign.Effect.shadowColor
        public static let wideArtworkShadowRadius = EnsembleDesign.Effect.shadowRadius
        public static let wideArtworkShadowY = EnsembleDesign.Effect.shadowY
        public static let placeholderArtworkColor = Color.gray.opacity(0.2)
        public static let darkLegibilityOverlayOpacity = EnsembleScaffold.DetailSurface.darkLegibilityOverlayOpacity
        public static let lightLegibilityOverlayOpacity = EnsembleScaffold.DetailSurface.lightLegibilityOverlayOpacity
    }

    public enum AccountSetup {
        public static let macMinimumWidth: CGFloat = 720
        public static let macMinimumHeight: CGFloat = 560
        public static let contentMaxWidth: CGFloat = 620
        public static let pinCodeMaxWidth: CGFloat = 320
        public static let rowIconWidth: CGFloat = 44
        public static let iconSize: CGFloat = 60
        public static let pinCodeFontSize: CGFloat = 48
        public static let pinCodeTracking: CGFloat = 8
        public static let contentSpacing = EnsembleDesign.Spacing.xxl
        public static let sectionSpacing = EnsembleDesign.Spacing.lg
        public static let cardSpacing = EnsembleDesign.Spacing.sm
        public static let rowSpacing = TrackListLayoutMetrics.rowInterItemSpacing
        public static let inlineIconSpacing = EnsembleDesign.Spacing.chipVertical
        public static let cardPadding = EnsembleDesign.Spacing.lg
        public static let horizontalPadding = EnsembleDesign.Spacing.xl
        public static let prominentHorizontalPadding = EnsembleDesign.Spacing.xxxl
        public static let footerVerticalPadding = EnsembleDesign.Spacing.md
        public static let cardCornerRadius = EnsembleDesign.Radius.card
        public static let cardBackground = Color.gray.opacity(0.1)
    }

    public enum UtilityRow {
        public static let iconLaneWidth = EnsembleScaffold.AccountSetup.rowIconWidth
        public static let inlineIconWidth: CGFloat = 14
        public static let chevronLaneWidth: CGFloat = 12
        public static let statusIconWidth: CGFloat = 24
        public static let compactArtworkDimension: CGFloat = 40
        public static let downloadArtworkDimension: CGFloat = 44
        public static let artworkDimension: CGFloat = 48
        public static let textSpacing = EnsembleDesign.Spacing.xxs
        public static let detailTextSpacing = EnsembleDesign.Spacing.xs
        public static let inlineSpacing = EnsembleDesign.Spacing.chipVertical
        public static let rowSpacing = EnsembleDesign.Spacing.sm
        public static let controlSpacing: CGFloat = 10
        public static let nestedLeadingPadding: CGFloat = iconLaneWidth - EnsembleDesign.Spacing.lg
        public static let tightVerticalPadding = EnsembleDesign.Spacing.xxs
        public static let subtleVerticalPadding = EnsembleDesign.Spacing.xs
        public static let halfRowVerticalPadding = TrackListLayoutMetrics.rowVerticalPadding / 2
        public static let negativeListPadding: CGFloat = -EnsembleDesign.Spacing.xs
        public static let hiddenNavigationLinkOpacity = EnsembleDesign.Spacing.none
        public static let chevronSubtleOpacity = 0.5
        public static let percentProgressTotal = 100.0
        public static let statusChipOpacity = 0.12
        public static let downloadErrorLeadingPadding: CGFloat = downloadArtworkDimension + rowSpacing + EnsembleDesign.Spacing.xs

        public static var insetIconBackground: Color {
            #if os(iOS)
            return Color(UIColor.tertiarySystemGroupedBackground)
            #else
            return Color(NSColor.controlBackgroundColor)
            #endif
        }
    }

    public enum UtilitySectionHeader {
        public static let defaultColor = EnsembleDesign.Color.accent
    }

    public enum UtilityScreen {
        public static let contentMaxWidth = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth
        public static let outerHorizontalPadding = EnsembleDesign.Spacing.sheetOuterHorizontal
        public static let outerVerticalPadding = EnsembleDesign.Spacing.sheetOuterVertical
        public static let sectionSpacing = EnsembleDesign.Spacing.xl
        public static let sectionHeaderHorizontalPadding = EnsembleDesign.Spacing.sm
        public static let rowHorizontalPadding = EnsembleDesign.Spacing.lg
        public static let rowVerticalPadding = EnsembleDesign.Spacing.compactControlVertical
        public static let cardCornerRadius = EnsembleDesign.Radius.control
        public static let cardStrokeWidth: CGFloat = 0.5
        public static let dividerLeadingPadding = rowHorizontalPadding + UtilityRow.iconLaneWidth + TrackListLayoutMetrics.rowInterItemSpacing

        public static var cardBackground: Color {
            #if os(macOS)
            Color(NSColor.controlBackgroundColor).opacity(0.72)
            #else
            Color.clear
            #endif
        }
    }

    public enum LogViewer {
        public static let loadMoreButtonVerticalPadding = EnsembleDesign.Spacing.sm
        public static let lineVerticalPadding: CGFloat = 1
    }

    public enum TabEditor {
        public static let maximumTabBarItems = 4
        public static let instructionHorizontalPadding = EnsembleDesign.Spacing.xl
        public static let instructionTopPadding = EnsembleDesign.Spacing.lg
        public static let instructionBottomPadding = EnsembleDesign.Spacing.md
        public static let dividerLeadingPadding: CGFloat = 52
        public static let rowIconWidth = EnsembleScaffold.UtilityRow.statusIconWidth
        public static let rowVerticalPadding = TrackListLayoutMetrics.rowVerticalPadding + EnsembleDesign.Spacing.xs
        public static let sectionHeaderTopPadding = EnsembleDesign.Spacing.xxl
        public static let sectionHeaderBottomPadding = EnsembleDesign.Spacing.sm
        public static let emptyVerticalPadding = EnsembleDesign.Spacing.xxl
        public static let sectionCornerRadius = EnsembleDesign.Radius.control
        public static let insertionDotSize = EnsembleDesign.Spacing.chipVertical
        public static let insertionLineHeight = EnsembleDesign.Spacing.xxs
        public static let addRemoveAnimationDuration = EnsembleDesign.Animation.quickDuration
        public static let reorderAnimationDuration = EnsembleDesign.Animation.standardDuration - 0.05
        public static let dropExitAnimationDuration = 0.15
    }

    public enum SyncSettings {
        public static let rowStatusSpacing = EnsembleDesign.Spacing.compactControlVertical
        public static let iconLaneWidth = EnsembleDesign.Spacing.lg
        public static let statusFont = EnsembleDesign.Typography.rowSecondary.weight(.semibold)
        public static let timestampFont = EnsembleDesign.Typography.cardMetadata
        public static let rowVerticalPadding = EnsembleDesign.Spacing.xxs
        public static let successTint = EnsembleDesign.Color.success
    }

    public enum FilterPresentation {
        public enum Style: Equatable {
            case toolbarPopover
            case sheet
            case inline
        }

        #if os(iOS)
        /// Default filter presentation policy for iOS and iPadOS library browse screens.
        public static func preferredStyle(horizontalSizeClass: UserInterfaceSizeClass?) -> Style {
            if #available(iOS 26.0, *), horizontalSizeClass == .regular {
                return .toolbarPopover
            }
            return .sheet
        }
        #else
        /// Default filter presentation policy for macOS library browse screens.
        public static func preferredStyle() -> Style {
            .toolbarPopover
        }
        #endif
    }

    public enum FilterSheet {
        public static let macContentMaxWidth: CGFloat = 640
        public static let macMinimumWidth: CGFloat = EnsembleScaffold.AccountSetup.macMinimumWidth
        public static let macMinimumHeight: CGFloat = EnsembleScaffold.AccountSetup.macMinimumHeight
        public static let macFieldLabelSpacing = EnsembleDesign.Spacing.chipVertical
        public static let sectionBackgroundOpacity = 0.04
        public static let subtleSectionBackgroundOpacity = 0.1
        public static let selectionSheetMinimumWidth = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth
        public static let selectionSheetMinimumHeight: CGFloat = 520
    }

    public enum BrowseSplit {
        public struct Configuration: Equatable {
            public let minimumSplitWidth: CGFloat
            public let sidebarWidth: CGFloat
            public let minimumSidebarWidth: CGFloat
            public let maximumSidebarWidth: CGFloat
            public let minimumDetailWidth: CGFloat
            public let resizeHandleWidth: CGFloat

            public init(
                minimumSplitWidth: CGFloat = EnsembleDesign.Breakpoint.browseSplitMinimumWidth,
                sidebarWidth: CGFloat = 340,
                minimumSidebarWidth: CGFloat = 260,
                maximumSidebarWidth: CGFloat = 460,
                minimumDetailWidth: CGFloat = 420,
                resizeHandleWidth: CGFloat = 12
            ) {
                self.minimumSplitWidth = minimumSplitWidth
                self.sidebarWidth = sidebarWidth
                self.minimumSidebarWidth = minimumSidebarWidth
                self.maximumSidebarWidth = maximumSidebarWidth
                self.minimumDetailWidth = minimumDetailWidth
                self.resizeHandleWidth = resizeHandleWidth
            }

            public static let rootBrowse = Configuration(
                minimumSplitWidth: 720,
                sidebarWidth: 340,
                minimumSidebarWidth: 280,
                maximumSidebarWidth: 420,
                minimumDetailWidth: 360
            )
        }

        public static let coordinateSpaceName = "LargeScreenBrowseSplitView"
        public static let resizeHandleBackingWidth: CGFloat = 10
        public static let resizeHandleBackingHeight: CGFloat = 64
        public static let resizeHandleThumbWidth: CGFloat = 3
        public static let resizeHandleThumbHeight: CGFloat = 48
        public static let resizeHandleThumbCornerRadius: CGFloat = 1.5
        public static let placeholderIcon = EnsembleDesign.Typography.mediaPlaceholderIcon
    }

    public enum DetailSurface {
        public static let wideHeaderThreshold = EnsembleDesign.Breakpoint.detailWideHeader
        public static let compactHeaderSpacing = EnsembleDesign.Spacing.lg
        public static let wideHeaderSpacing = EnsembleDesign.Spacing.xxl
        public static let metadataSpacing = EnsembleDesign.Spacing.sm
        public static let actionTopPadding = EnsembleDesign.Spacing.xs
        public static let headerPadding = EnsembleDesign.Spacing.lg
        public static let macWideHeaderTopPadding = EnsembleDesign.Spacing.xxl
        public static let macWideHeaderBottomPadding = EnsembleDesign.Spacing.xxl
        public static let actionVerticalPadding = EnsembleDesign.Spacing.md
        public static let actionCornerRadius = EnsembleDesign.Radius.control
        public static let compactActionFont = EnsembleDesign.Typography.actionLabel
        public static let compactActionVerticalPadding = EnsembleDesign.Spacing.compactControlVertical
        public static let compactActionCornerRadius = EnsembleDesign.Radius.compactControl
        public static let listCardCornerRadius = EnsembleDesign.Radius.card
        public static let listCardHorizontalPadding = EnsembleDesign.Spacing.lg
        public static let loadingTopPadding = TrackListLayoutMetrics.detailHorizontalPadding
        public static let compactWideActionThreshold: CGFloat = 300
        public static let stackedWideActionThreshold: CGFloat = 420
        public static let compactWideActionHorizontalPadding: CGFloat = 18
        public static let wideActionHorizontalPadding = EnsembleDesign.Spacing.xxl
        public static let iconActionDimension = EnsembleScaffold.UtilityRow.iconLaneWidth
        public static let darkLegibilityOverlayOpacity = 0.45
        public static let lightLegibilityOverlayOpacity = 0.7
        public static let backgroundFadeDuration = 0.55

        public enum ArtworkShadow {
            public static let color = EnsembleDesign.Effect.shadowColor
            public static let radius = EnsembleDesign.Effect.shadowRadius
            public static let x = EnsembleDesign.Effect.shadowX
            public static let y = EnsembleDesign.Effect.shadowY
        }

        public static var listCardBackground: Color {
            EnsembleDesign.Color.groupedSurface
        }
    }

    public enum DownloadDetail {
        public static let headerSpacing = EnsembleDesign.Spacing.lg
        public static let metadataSpacing = EnsembleDesign.Spacing.sm
        public static let progressSpacing = EnsembleDesign.Spacing.xs
        public static let bannerSpacing = EnsembleDesign.Spacing.sm
        public static let actionVerticalPadding = EnsembleScaffold.DetailSurface.actionVerticalPadding
        public static let actionCornerRadius = EnsembleScaffold.DetailSurface.actionCornerRadius
        public static let headerIconDimension: CGFloat = 120
        public static let headerIconSize = EnsembleDesign.Typography.emptyStateIcon
        public static let backgroundHeight: CGFloat = 400
        public static let progressMaxWidth: CGFloat = 280
        public static let backgroundAccentOpacity = 0.3
        public static let headerIconShadowColor = EnsembleDesign.Effect.shadowColor
        public static let headerIconShadowRadius = EnsembleDesign.Effect.shadowRadius
        public static let headerIconShadowY = EnsembleDesign.Effect.shadowY
    }

    public enum NowPlaying {
        public static let headerTopPadding = EnsembleDesign.Spacing.lg
        public static let headerBottomPadding = EnsembleDesign.Spacing.md
        public static let headerMinHeight: CGFloat = 36
        public static let pageIndicatorReservedHeight: CGFloat = headerMinHeight
        public static let cardBottomPadding = EnsembleDesign.Spacing.xl
        public static let viewportContentPadding = EnsembleDesign.Spacing.xxl
        public static let viewportInnerSpacing = EnsembleDesign.Spacing.xl
        public static let viewportNarrowTrailingPadding = EnsembleDesign.Spacing.sm
        public static let sectionTopPadding = EnsembleDesign.Spacing.lg
        public static let compactSectionTopPadding = EnsembleDesign.Spacing.sm
        public static let spaciousHeightThreshold: CGFloat = 700
        public static let artworkMaxHeightRatio: CGFloat = 0.4
        public static let artworkMaxDimension: CGFloat = 400
        public static let secondaryControlsSpacing: CGFloat = 30
        public static let transportControlsSpacing: CGFloat = 40
        public static let primaryControlsSpacing: CGFloat = 50
        public static let secondaryControlsTopPadding = EnsembleDesign.Spacing.lg
        public static let secondaryControlsStackSpacing = EnsembleDesign.Spacing.sm
        public static let scrubIndicatorSpacing = EnsembleDesign.Spacing.xs
        public static let inactiveControlOpacity = 0.7
        public static let activeControlOpacity = 0.9
        public static let unavailableControlOpacity = 0.4
        public static let offlineControlOpacity = 0.25
        public static let backgroundDarkOverlayOpacity = 0.45
        public static let backgroundLightOverlayOpacity = 0.7
        public static let smallIconSize: CGFloat = 14
        public static let menuIconSize: CGFloat = 16
        public static let routePickerSize: CGFloat = 24
        public static let primaryControlIconSize: CGFloat = 32
        public static let playPauseControlIconSize: CGFloat = 80
        public static let loadingIndicatorScale: CGFloat = 1.5
        public static let emptyIconSize: CGFloat = 48
        public static let emptyArtworkFillOpacity = 0.05
        public static let emptyArtworkIconOpacity = 0.35
        public static let emptyVerticalPadding = TrackListLayoutMetrics.detailHorizontalPadding
        public static let emptyTextSpacing = TrackListLayoutMetrics.rowInterItemSpacing + EnsembleDesign.Spacing.xs
        public static let statusDotSize = EnsembleDesign.Spacing.sm
        public static let infoLabelWidth: CGFloat = 72
        public static let rowDisclosureTopPadding = EnsembleDesign.Spacing.xxs
        public static let disabledControlsOpacity = 0.5
        public static let scrubberHeight: CGFloat = 24
        public static let waveformOpacity = 0.8
        public static let scrubFineDistance: CGFloat = 120
        public static let scrubFullSpeedDistance: CGFloat = 40
        public static let scrubHalfSpeedDistance: CGFloat = 80
        public static let scrubHalfRate = 0.5
        public static let scrubQuarterRate = 0.25
        public static let scrubFineRate = 0.1
        public static let loadingIndicatorDelayNanoseconds: UInt64 = 300_000_000
        public static let auroraActiveContentMaxWidth: CGFloat = 670
        public static let viewportContentMaxWidth: CGFloat = 1024
        public static let viewportHeaderMaxWidth: CGFloat = 1120
        public static let viewportContentMaxHeight: CGFloat = 768
        public static let viewportSinglePanelMaxWidth: CGFloat = 560
        public static let viewportDualPanelMinimumWidth: CGFloat = 920
        public static let viewportDualPanelMinimumHeight: CGFloat = 620
        public static let viewportSinglePickerWidth: CGFloat = 390
        public static let viewportPickerWidth: CGFloat = 300
        public static let viewportMinimumPanelWidth: CGFloat = 320
        public static let viewportWideAspectMultiplier: CGFloat = 0.82
        public static let viewportMacTopSafeAreaPadding = EnsembleDesign.Spacing.lg
        public static let viewportMacMinimumTopInset: CGFloat = 60
        public static let viewportModernTopSafeAreaPadding: CGFloat = 18
        public static let viewportModernMinimumTopInset: CGFloat = 30
        public static let viewportLegacyTopSafeAreaPadding = EnsembleDesign.Spacing.md
        public static let viewportLegacyMinimumTopInset = EnsembleDesign.Spacing.xl
        public static let viewportMacTrafficLightClearance: CGFloat = 88
        public static let viewportModernTrafficLightClearance: CGFloat = 92
        public static let viewportLegacyChromeInset = EnsembleDesign.Spacing.sm
        public static let dismissPillTopPadding: CGFloat = 28
        public static let dismissPillWidth: CGFloat = 36
        public static let dismissPillHeight: CGFloat = 5
        public static let dismissPillOpacity = 0.3
        public static let dismissDragThreshold: CGFloat = 120
        public static let externalDisplayAspectRatio: CGFloat = 4.0 / 3.0
        public static let lyricTimedLineSpacing: CGFloat = 24
        public static let lyricPlainLineSpacing = EnsembleDesign.Spacing.md
        public static let lyricTopSpacerHeight: CGFloat = 120
        public static let lyricBottomSpacerHeight: CGFloat = 200
        public static let lyricIndicatorSpacing = EnsembleDesign.Spacing.chipVertical
        public static let lyricIndicatorDotSize = EnsembleDesign.Spacing.sm
        public static let lyricIndicatorFilledOpacity = 0.6
        public static let lyricIndicatorEmptyOpacity = 0.15
        public static let lyricActiveScale = 1.05
        public static let lyricPastOpacity = 0.5
        public static let lyricFutureOpacity = 0.3
        public static let lyricPlainOpacity = 0.9
        public static let lyricBlurStartDistance = 2
        public static let lyricBlurStep: CGFloat = 1.5
        public static let lyricMaxBlur: CGFloat = 5

        public enum FadeMask {
            public static let topHeight: CGFloat = 50
            public static let bottomHeight: CGFloat = 80
            public static let topOpaqueLocation = 0.1
            public static let bottomOpaqueLocation = 0.7
            public static let infoTopHeight: CGFloat = 30
            public static let infoBottomHeight: CGFloat = 50
            public static let infoTopOpaqueLocation = 0.05
            public static let infoBottomOpaqueLocation = 0.85
        }

        public enum Shadow {
            public static let controlColor = EnsembleDesign.Effect.shadowColor
            public static let controlRadius = EnsembleDesign.Effect.shadowRadius
            public static let controlX = EnsembleDesign.Effect.shadowX
            public static let controlY = EnsembleDesign.Effect.shadowY
            public static let artworkColor = EnsembleDesign.Effect.shadowColor
            public static let emptyArtworkColor = EnsembleDesign.Effect.shadowColor
            public static let artworkRadius = EnsembleDesign.Effect.shadowRadius
            public static let artworkY = EnsembleDesign.Effect.shadowY
        }

        public enum PageIndicator {
            public static let itemSize: CGFloat = 20
            public static let activeDotSize = EnsembleDesign.Spacing.sm
            public static let inactiveIconSize: CGFloat = 12
            public static let inactiveOpacity = 0.4
            public static let verticalPadding = EnsembleDesign.Spacing.sm
        }
    }

    public enum ScrollIndex {
        public static let verticalPadding = EnsembleDesign.Spacing.sm
        public static let horizontalPadding = EnsembleDesign.Spacing.xs
        public static let letterHeight: CGFloat = 15
        public static let letterSpacing = EnsembleDesign.Spacing.xxs
        public static let letterWidth = EnsembleDesign.Spacing.xl
        public static let letterFont: Font = .system(size: 10, weight: .bold)
        public static let bottomLift: CGFloat = 6
        public static let compactTrailingPadding = EnsembleDesign.Spacing.xxs
        public static let regularTrailingPadding = EnsembleDesign.Spacing.xxs
        public static let regularBottomPadding = EnsembleDesign.Spacing.lg
    }

    public enum TrackSwipe {
        public static let actionWidth: CGFloat = 72
        public static let actionCornerRadius = EnsembleDesign.Radius.card
        public static let actionLabelSpacing: CGFloat = 5
        public static let actionIconFont: Font = .system(size: 16, weight: .semibold)
        public static let actionTextFont = EnsembleDesign.Typography.cardMetadata
    }

    public enum MiniPlayer {
        public static let materialRole = EnsembleDesign.Material.Role.miniPlayer
        public static let popoverMaterialRole = EnsembleDesign.Material.Role.popover
        public static let cornerRadius = EnsembleDesign.Radius.miniPlayer
        public static let popoverCornerRadius = EnsembleDesign.Radius.miniPlayer
        public static let floatingHorizontalPadding = EnsembleDesign.Spacing.xl
        public static let inlineHorizontalPadding = EnsembleDesign.Spacing.md
        public static let floatingBottomPadding = EnsembleDesign.Spacing.chipVertical
        public static let inlineBottomPadding = EnsembleDesign.Spacing.xs
        public static let containerBottomPadding: CGFloat = 70
        public static let verticalSwipeRubberBandFactor: CGFloat = 0.5
        public static let verticalOpenThreshold: CGFloat = 50
        public static let artworkDimension: CGFloat = 32
        public static let compactControlLaneWidth: CGFloat = 78
        public static let expandedControlLaneWidth: CGFloat = 148
        public static let trackLaneMinimumWidth: CGFloat = 120
        public static let trackLaneMaximumWidth: CGFloat = 220
        public static let trackLaneWidthRatio: CGFloat = 0.42
        public static let waveformLaneMinimumWidth: CGFloat = 70
        public static let waveformHeight: CGFloat = 18
        public static let waveformOpacity = 0.9
        public static let largeRowMinimumHeight: CGFloat = 34
        public static let horizontalSwipeFadeDistance: CGFloat = 200
        public static let horizontalSwipeMaximumFade = 0.5
        public static let horizontalSwipeThreshold: CGFloat = 80
        public static let horizontalSwipeDismissOffset: CGFloat = 200
        public static let horizontalSwipeResetDelay: TimeInterval = 0.1
        public static let controlSpacing: CGFloat = 18
        public static let controlLoadingScale: CGFloat = 0.8
        public static let unavailableControlOpacity = EnsembleScaffold.NowPlaying.unavailableControlOpacity
        public static let actionButtonDimension: CGFloat = 25
        public static let popoverWidth: CGFloat = 240
        public static let popoverDividerVerticalPadding = EnsembleDesign.Spacing.chipVertical
        public static let macMenuYOffset = EnsembleDesign.Spacing.xs
        public static let backgroundBlurRadius: CGFloat = 50
        public static let backgroundContrast: CGFloat = 2.0
        public static let backgroundSaturation: CGFloat = 1.9
        public static let backgroundDarkBrightness: CGFloat = -0.1
        public static let backgroundLightBrightness: CGFloat = 0.05
        public static let backgroundOpacity = 0.3
        public static let backgroundTopDimming = 0.2
        public static let backgroundBottomDimming = 0.15
        public static let backgroundAnimationDuration = 0.8
        public static let sheenDarkTopOpacity = 0.03
        public static let sheenDarkBottomOpacity = 0.02
        public static let sheenLightOpacity = 0.01
        public static let edgeGlowDarkOpacity = 0.15
        public static let edgeGlowLightOpacity = 0.05
        public static let edgeGlowInset: CGFloat = 1
    }

    public enum AuxiliaryWindow {
        public struct Configuration: Equatable {
            public let minWidth: CGFloat
            public let idealWidth: CGFloat
            public let maxWidth: CGFloat
            public let minHeight: CGFloat
            public let idealHeight: CGFloat

            public init(
                minWidth: CGFloat = 380,
                idealWidth: CGFloat = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth,
                maxWidth: CGFloat = EnsembleDesign.Breakpoint.auxiliaryWindowMaxWidth,
                minHeight: CGFloat,
                idealHeight: CGFloat
            ) {
                self.minWidth = minWidth
                self.idealWidth = idealWidth
                self.maxWidth = maxWidth
                self.minHeight = minHeight
                self.idealHeight = idealHeight
            }

            public static let profile = Configuration(
                minHeight: 560,
                idealHeight: 640
            )

            public static let downloads = Configuration(
                minHeight: 640,
                idealHeight: 720
            )
        }

        public static let backgroundColor = EnsembleDesign.Material.Role.sheet.fallbackBackgroundColor
    }
}

/// Platform-aligned browse toolbar host that keeps the macOS search spacer pattern in one place.
public struct EnsembleBrowseToolbar<Content: View>: ToolbarContent {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    public init(
        isVisible: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isVisible = isVisible
        self.content = content
    }

    public var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            if isVisible {
                HStack(spacing: EnsembleScaffold.BrowseToolbar.itemSpacing) {
                    content()
                }
            }
        }
        #else
        EnsembleToolbarLeadingSpacer()
        ToolbarItem(placement: .primaryActionIfAvailable) {
            if isVisible {
                HStack(spacing: EnsembleScaffold.BrowseToolbar.itemSpacing) {
                    content()
                }
            }
        }
        #endif
    }
}

/// Platform-aligned leading toolbar spacer for macOS action groups.
/// SwiftUI's macOS toolbar layout can cluster primary actions near the title or
/// search field unless a flexible toolbar item precedes the action group.
public struct EnsembleToolbarLeadingSpacer: ToolbarContent {
    @Environment(\.isInLargeScreenBrowseDetailPane) private var isInLargeScreenBrowseDetailPane
    private let suppressesInLargeScreenBrowseDetailPane: Bool

    public init(suppressesInLargeScreenBrowseDetailPane: Bool = false) {
        self.suppressesInLargeScreenBrowseDetailPane = suppressesInLargeScreenBrowseDetailPane
    }

    public var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItem {
            if !suppressesInLargeScreenBrowseDetailPane || !isInLargeScreenBrowseDetailPane {
                Spacer()
            }
        }
        #else
        ToolbarItem(placement: .navigationBarTrailing) {
            EmptyView()
        }
        #endif
    }
}

/// Standalone detail views on macOS need a leading flexible toolbar item so
/// actions align with the trailing edge instead of clustering near the title.
/// Detail panes inside LargeScreenBrowseSplitView already participate in the
/// split's shared toolbar geometry and should not add that spacer.
public struct EnsembleDetailToolbarLeadingSpacer: ToolbarContent {
    public init() {}

    public var body: some ToolbarContent {
        EnsembleToolbarLeadingSpacer(suppressesInLargeScreenBrowseDetailPane: true)
    }
}

/// Standard filter button for browse screens, including the active-filter badge treatment.
public struct EnsembleBrowseFilterButton: View {
    let title: String
    let hasActiveFilters: Bool
    let action: () -> Void

    public init(
        title: String = "Filter",
        hasActiveFilters: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.hasActiveFilters = hasActiveFilters
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: EnsembleDesign.Icon.filter)

                if hasActiveFilters {
                    Circle()
                        .fill(EnsembleDesign.Color.destructive)
                        .frame(
                            width: EnsembleScaffold.BrowseToolbar.activeBadgeSize,
                            height: EnsembleScaffold.BrowseToolbar.activeBadgeSize
                        )
                        .offset(
                            x: EnsembleScaffold.BrowseToolbar.activeBadgeOffset,
                            y: -EnsembleScaffold.BrowseToolbar.activeBadgeOffset
                        )
                }
            }
        }
        .accessibilityLabel(title)
    }
}

/// Standard section header treatment for indexed library browse lists.
public struct EnsembleBrowseSectionHeader: View {
    private let title: String
    private let backgroundColor: Color?

    public init(_ title: String, backgroundColor: Color? = nil) {
        self.title = title
        self.backgroundColor = backgroundColor
    }

    public var body: some View {
        Text(title)
            .font(EnsembleDesign.Typography.browseSectionHeader)
            .foregroundColor(EnsembleDesign.Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EnsembleScaffold.BrowseSectionHeader.horizontalPadding)
            .padding(.vertical, EnsembleScaffold.BrowseSectionHeader.verticalPadding)
            .background(backgroundColor?.opacity(EnsembleScaffold.BrowseSectionHeader.backgroundOpacity))
    }
}

/// Standard title treatment for content shelves and sections.
public struct EnsembleContentSectionHeader: View {
    private let title: String
    private let showsDisclosure: Bool

    public init(_ title: String, showsDisclosure: Bool = false) {
        self.title = title
        self.showsDisclosure = showsDisclosure
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            if showsDisclosure {
                Spacer()

                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }
}

/// Standard section header treatment for profile, downloads, account, and settings lists.
public struct EnsembleUtilitySectionHeader: View {
    private let title: String
    private let color: Color

    public init(_ title: String, color: Color = EnsembleScaffold.UtilitySectionHeader.defaultColor) {
        self.title = title
        self.color = color
    }

    public var body: some View {
        Text(title)
            .foregroundColor(color)
            .textCase(nil)
    }
}

/// Fixed-width icon lane used by profile/settings/downloads utility rows.
public struct EnsembleUtilityIcon: View {
    private let systemName: String
    private let color: Color
    private let font: Font?
    private let width: CGFloat

    public init(
        _ systemName: String,
        color: Color = EnsembleDesign.Color.accent,
        font: Font? = nil,
        width: CGFloat = EnsembleScaffold.UtilityRow.iconLaneWidth
    ) {
        self.systemName = systemName
        self.color = color
        self.font = font
        self.width = width
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundColor(color)
            .frame(width: width)
    }
}

/// Compact icon + status text row used inside utility cards and account detail rows.
public struct EnsembleUtilityInlineStatusRow: View {
    private let iconSystemName: String
    private let text: String
    private let iconColor: Color
    private let textColor: Color
    private let iconFont: Font
    private let textFont: Font
    private let iconWidth: CGFloat
    private let spacing: CGFloat
    private let lineLimit: Int?

    public init(
        iconSystemName: String,
        text: String,
        iconColor: Color = EnsembleDesign.Color.secondaryText,
        textColor: Color = EnsembleDesign.Color.secondaryText,
        iconFont: Font = EnsembleDesign.Typography.rowSecondary,
        textFont: Font = EnsembleDesign.Typography.rowSecondary,
        iconWidth: CGFloat = EnsembleScaffold.UtilityRow.inlineIconWidth,
        spacing: CGFloat = EnsembleScaffold.UtilityRow.inlineSpacing,
        lineLimit: Int? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.text = text
        self.iconColor = iconColor
        self.textColor = textColor
        self.iconFont = iconFont
        self.textFont = textFont
        self.iconWidth = iconWidth
        self.spacing = spacing
        self.lineLimit = lineLimit
    }

    public var body: some View {
        HStack(spacing: spacing) {
            EnsembleUtilityIcon(iconSystemName, color: iconColor, font: iconFont, width: iconWidth)

            Text(text)
                .font(textFont)
                .foregroundColor(textColor)
                .lineLimit(lineLimit)
        }
    }
}

/// Shared title/subtitle stack for compact utility list rows.
public struct EnsembleUtilityTextStack: View {
    private let title: String
    private let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.UtilityRow.textSpacing) {
            Text(title)
                .font(EnsembleDesign.Typography.rowPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }
}

/// Shared icon + title/subtitle row for lightweight settings and profile lists.
public struct EnsembleUtilityRowLabel: View {
    private let iconSystemName: String
    private let title: String
    private let subtitle: String?
    private let iconColor: Color
    private let iconFont: Font?

    public init(
        iconSystemName: String,
        title: String,
        subtitle: String? = nil,
        iconColor: Color = EnsembleDesign.Color.accent,
        iconFont: Font? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.subtitle = subtitle
        self.iconColor = iconColor
        self.iconFont = iconFont
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            EnsembleUtilityIcon(iconSystemName, color: iconColor, font: iconFont)
            EnsembleUtilityTextStack(title, subtitle: subtitle)
        }
    }
}

public extension View {
    func browseSelectionBackground(isSelected: Bool) -> some View {
        background(
            RoundedRectangle(
                cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
                style: .continuous
            )
            .fill(isSelected ? EnsembleScaffold.BrowseSelection.fillColor : Color.clear)
        )
    }
}

/// Presents filter UI using the shared platform policy: compact screens keep sheets, while
/// regular-width modern iPadOS and macOS use toolbar popovers.
public struct EnsembleFilterPresentationModifier<PresentedContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let presentedContent: () -> PresentedContent
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(
        isPresented: Binding<Bool>,
        @ViewBuilder presentedContent: @escaping () -> PresentedContent
    ) {
        self._isPresented = isPresented
        self.presentedContent = presentedContent
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        #if os(iOS)
        switch EnsembleScaffold.FilterPresentation.preferredStyle(horizontalSizeClass: horizontalSizeClass) {
        case .toolbarPopover:
            content.popover(isPresented: $isPresented, arrowEdge: .top) {
                presentedContent()
            }
        case .sheet, .inline:
            content.sheet(isPresented: $isPresented) {
                presentedContent()
            }
        }
        #else
        switch EnsembleScaffold.FilterPresentation.preferredStyle() {
        case .toolbarPopover:
            content.popover(isPresented: $isPresented, arrowEdge: .top) {
                presentedContent()
            }
        case .sheet, .inline:
            content.sheet(isPresented: $isPresented) {
                presentedContent()
            }
        }
        #endif
    }
}

public extension View {
    func ensembleFilterPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        modifier(
            EnsembleFilterPresentationModifier(
                isPresented: isPresented,
                presentedContent: content
            )
        )
    }
}

/// Consistent empty/loading/error state used by browse and utility screens.
public struct EnsembleStateScaffold<Action: View>: View {
    public enum Presentation {
        case fullScreen
        case compactFooter

        var outerSpacing: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.lg
            case .compactFooter: return EnsembleDesign.Spacing.md
            }
        }

        var textSpacing: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.sm
            case .compactFooter: return EnsembleDesign.Spacing.xs
            }
        }

        var iconFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.emptyStateIcon
            case .compactFooter: return EnsembleDesign.Typography.mediaPlaceholderIcon
            }
        }

        var titleFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.stateTitle
            case .compactFooter: return .headline
            }
        }

        var messageFont: Font {
            switch self {
            case .fullScreen: return EnsembleDesign.Typography.stateMessage
            case .compactFooter: return .caption
            }
        }

        var topPadding: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.xxxl
            case .compactFooter: return 40
            }
        }

        var bottomPadding: CGFloat {
            switch self {
            case .fullScreen: return EnsembleDesign.Spacing.xxxl
            case .compactFooter: return EnsembleDesign.Spacing.none
            }
        }
    }

    public enum Kind {
        case empty
        case loading
        case error

        var defaultIcon: String {
            switch self {
            case .empty: return EnsembleDesign.Icon.musicNote
            case .loading: return EnsembleDesign.Icon.musicNote
            case .error: return EnsembleDesign.Icon.error
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String?
    let iconSystemName: String?
    let presentation: Presentation
    @ViewBuilder let action: () -> Action

    public init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        presentation: Presentation = .fullScreen,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.iconSystemName = iconSystemName
        self.presentation = presentation
        self.action = action
    }

    public var body: some View {
        VStack(spacing: presentation.outerSpacing) {
            if kind == .loading {
                ProgressView()
            } else {
                Image(systemName: iconSystemName ?? kind.defaultIcon)
                    .font(presentation.iconFont)
                    .foregroundColor(EnsembleDesign.Color.placeholderText)
            }

            VStack(spacing: presentation.textSpacing) {
                Text(title)
                    .font(presentation.titleFont)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(presentation.messageFont)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            action()
        }
        .padding(.horizontal, EnsembleDesign.Spacing.xxl)
        .padding(.top, presentation.topPadding)
        .padding(.bottom, presentation.bottomPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: presentation == .fullScreen ? .infinity : nil
        )
    }
}

public extension EnsembleStateScaffold where Action == EmptyView {
    init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        presentation: Presentation = .fullScreen
    ) {
        self.init(
            kind: kind,
            title: title,
            message: message,
            iconSystemName: iconSystemName,
            presentation: presentation
        ) {
            EmptyView()
        }
    }
}

/// Shared filled capsule action used inside empty/loading/error states.
public struct EnsembleStateActionLabel: View {
    private let title: String
    private let systemImage: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, EnsembleDesign.Spacing.xl)
            .padding(.vertical, EnsembleDesign.Spacing.compactControlVertical)
            .background(EnsembleDesign.Color.accent)
            .foregroundColor(EnsembleDesign.Color.onAccent)
            .clipShape(Capsule())
    }
}

/// Shared empty-state decision tree for library browse screens that depend on
/// configured music sources, enabled libraries, and sync/cloud-restore state.
public struct EnsembleLibraryEmptyStateScaffold: View {
    public enum Recovery {
        case restoringCloudSources
        case noSources
        case syncing
        case noEnabledLibraries
        case empty(message: String)

        var message: String? {
            switch self {
            case .restoringCloudSources:
                return "Restoring libraries from iCloud…"
            case .noSources:
                return "No music sources connected"
            case .syncing:
                return nil
            case .noEnabledLibraries:
                return "No libraries enabled"
            case .empty(let message):
                return message
            }
        }
    }

    private let title: String
    private let iconSystemName: String
    private let recovery: Recovery
    private let addSource: () -> Void
    private let manageSources: () -> Void

    public init(
        title: String,
        iconSystemName: String,
        recovery: Recovery,
        addSource: @escaping () -> Void,
        manageSources: @escaping () -> Void
    ) {
        self.title = title
        self.iconSystemName = iconSystemName
        self.recovery = recovery
        self.addSource = addSource
        self.manageSources = manageSources
    }

    public var body: some View {
        EnsembleStateScaffold(
            kind: .empty,
            title: title,
            message: recovery.message,
            iconSystemName: iconSystemName
        ) {
            recoveryAction
        }
    }

    @ViewBuilder
    private var recoveryAction: some View {
        switch recovery {
        case .restoringCloudSources:
            VStack(spacing: EnsembleDesign.Spacing.sm) {
                ProgressView()
                Text("This can take a moment on first launch.")
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .multilineTextAlignment(.center)
            }
        case .noSources:
            Button(action: addSource) {
                actionLabel("Add Source", systemImage: EnsembleDesign.Icon.addCircle)
            }
            .buttonStyle(.plain)
        case .syncing:
            HStack(spacing: EnsembleDesign.Spacing.sm) {
                ProgressView()
                Text("Sync in progress…")
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        case .noEnabledLibraries:
            Button(action: manageSources) {
                actionLabel("Manage Sources", systemImage: EnsembleDesign.Icon.editPlaylist)
            }
            .buttonStyle(.plain)
        case .empty:
            EmptyView()
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        EnsembleStateActionLabel(title, systemImage: systemImage)
    }
}
