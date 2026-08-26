import EnsembleDesignTokens
import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum TrackListLayoutMetrics {
    public static let rowHorizontalPadding: CGFloat = EnsembleDesign.Spacing.rowHorizontal
    public static let rowInterItemSpacing: CGFloat = EnsembleDesign.Spacing.rowItemGap
    public static let rowVerticalPadding: CGFloat = EnsembleDesign.Spacing.rowVertical
    public static let detailHorizontalPadding: CGFloat = EnsembleDesign.Spacing.detailGutter
    public static let utilitySectionOuterPadding: CGFloat = detailHorizontalPadding - rowHorizontalPadding

    public static let defaultRowHeight: CGFloat = 68
    public static let rowContentMinHeight: CGFloat = defaultRowHeight - (rowVerticalPadding * 2)
    public static let compactRowHeightThreshold: CGFloat = 60
    public static let standardArtworkDimension: CGFloat = 44
    public static let compactArtworkDimension: CGFloat = 40
    public static let trackNumberWidth: CGFloat = 30
    public static let overflowControlDimension: CGFloat = 25
    public static let queueHorizontalGutter: CGFloat = 20
    public static let queueOuterContentPadding = detailHorizontalPadding - queueHorizontalGutter
    public static let queueDragHandleDimension: CGFloat = 20
    public static let queueGeneratedBadgeDimension: CGFloat = 14
    public static let nativeSectionIconDimension: CGFloat = 14
    public static let nativePrimaryFontSize: CGFloat = 16
    public static let nativeSecondaryFontSize: CGFloat = 14
    public static let nativeCompactPrimaryFontSize: CGFloat = 15
    public static let nativeCompactSecondaryFontSize: CGFloat = 13
    #if os(macOS)
    public static let nativeMacPrimaryFontSize: CGFloat = NSFont.systemFontSize
    public static let nativeMacSecondaryFontSize: CGFloat = NSFont.smallSystemFontSize
    public static let nativeMacSectionHeaderFontSize: CGFloat = NSFont.systemFontSize
    #endif
    public static let durationMinimumWidth: CGFloat = 40
    public static let durationColumnWidth: CGFloat = 52
    public static let favoriteIndicatorDimension: CGFloat = 14
    public static let favoriteIndicatorCenterX: CGFloat = 8
    public static let downloadIndicatorDimension: CGFloat = 14
    public static let downloadIndicatorScale: CGFloat = 0.7
    public static let playingIndicatorDimension: CGFloat = 18
    public static let rowAccessoryGap: CGFloat = 8
    public static let rowTightAccessoryGap: CGFloat = 6
    public static let dividerColor = EnsembleDesign.Color.divider
    public static let nativeDividerAlpha: CGFloat = 0.18
    public static let unavailableOpacity = 0.45
    public static let primarySecondaryTextSpacing: CGFloat = EnsembleDesign.Spacing.xxs
    public static let defaultTitleTopPadding: CGFloat = 14
    public static let compactTitleTopPadding: CGFloat = 10

    public static let artworkLeadingInset: CGFloat = 68
    public static let trackNumberLeadingInset: CGFloat = 54
    public static let plainLeadingInset: CGFloat = EnsembleDesign.Spacing.rowHorizontal

    public static let supplementalArtistColumnThreshold: CGFloat = 700
    public static let supplementalAlbumColumnThreshold: CGFloat = 940
    public static let supplementalArtistColumnRatio: CGFloat = 0.22
    public static let supplementalAlbumColumnRatio: CGFloat = 0.28
    public static let supplementalArtistColumnMinimum: CGFloat = 150
    public static let supplementalArtistColumnMaximum: CGFloat = 260
    public static let supplementalAlbumColumnMinimum: CGFloat = 180
    public static let supplementalAlbumColumnMaximum: CGFloat = 360

    public static let miniPlayerBottomSpacing: CGFloat = 140
    public static let compactMiniPlayerBottomSpacing: CGFloat = 110
    public static let miniPlayerContainerInset: CGFloat = 70
    public static let miniPlayerBottomLiftBase: CGFloat = 52
    public static let miniPlayerAdditionalBottomPadding: CGFloat = 12

    public static func detailMiniPlayerBottomLift(safeAreaBottom: CGFloat) -> CGFloat {
        min(max(safeAreaBottom + 12, 20), 32)
    }

    public static func rootMiniPlayerBottomLift(
        safeAreaBottom: CGFloat,
        tabBarBottomClearance: CGFloat = 0
    ) -> CGFloat {
        guard tabBarBottomClearance > 0 else { return 0 }
        return max(tabBarBottomClearance - safeAreaBottom, 0) + miniPlayerAdditionalBottomPadding
    }

    public static func contentLeadingInset(showArtwork: Bool, showTrackNumbers: Bool) -> CGFloat {
        if showArtwork {
            return artworkLeadingInset
        }

        if showTrackNumbers {
            return trackNumberLeadingInset
        }

        return plainLeadingInset
    }

    public static func rowInsets() -> EdgeInsets {
        EdgeInsets(
            top: rowVerticalPadding,
            leading: rowHorizontalPadding,
            bottom: rowVerticalPadding,
            trailing: rowHorizontalPadding
        )
    }

    #if os(iOS)
    public static var nativeSeparatorColor: UIColor {
        UIColor.secondaryLabel.withAlphaComponent(nativeDividerAlpha)
    }
    #elseif os(macOS)
    public static var nativeSeparatorColor: NSColor {
        NSColor.secondaryLabelColor.withAlphaComponent(nativeDividerAlpha)
    }
    #endif

    public static func showsArtistMetadataColumn(for width: CGFloat?) -> Bool {
        guard let width else { return false }
        return width >= supplementalArtistColumnThreshold
    }

    public static func showsAlbumMetadataColumn(for width: CGFloat?) -> Bool {
        guard let width else { return false }
        return width >= supplementalAlbumColumnThreshold
    }

    public static func artistMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        guard let width else { return 0 }
        return min(
            max(width * supplementalArtistColumnRatio, supplementalArtistColumnMinimum),
            supplementalArtistColumnMaximum
        )
    }

    public static func albumMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        guard let width else { return 0 }
        return min(
            max(width * supplementalAlbumColumnRatio, supplementalAlbumColumnMinimum),
            supplementalAlbumColumnMaximum
        )
    }
}
