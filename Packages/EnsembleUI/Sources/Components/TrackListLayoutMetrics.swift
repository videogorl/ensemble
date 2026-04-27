import CoreGraphics
import SwiftUI

public enum TrackListLayoutMetrics {
    public static let rowHorizontalPadding: CGFloat = EnsembleDesign.Spacing.rowHorizontal
    public static let rowInterItemSpacing: CGFloat = EnsembleDesign.Spacing.rowItemGap
    public static let rowVerticalPadding: CGFloat = EnsembleDesign.Spacing.rowVertical
    public static let detailHorizontalPadding: CGFloat = EnsembleDesign.Spacing.detailGutter
    public static let utilitySectionOuterPadding: CGFloat = detailHorizontalPadding - rowHorizontalPadding

    public static let defaultRowHeight: CGFloat = 68
    public static let rowContentMinHeight: CGFloat = defaultRowHeight - (rowVerticalPadding * 2)
    public static let compactRowHeightThreshold: CGFloat = 60

    public static let artworkLeadingInset: CGFloat = 68
    public static let trackNumberLeadingInset: CGFloat = 54
    public static let plainLeadingInset: CGFloat = EnsembleDesign.Spacing.rowHorizontal

    public static let miniPlayerBottomSpacing: CGFloat = 140
    public static let compactMiniPlayerBottomSpacing: CGFloat = 110
    public static let miniPlayerContainerInset: CGFloat = 70
    public static let miniPlayerBottomLiftBase: CGFloat = 52

    public static func contentLeadingInset(showArtwork: Bool, showTrackNumbers: Bool) -> CGFloat {
        if showArtwork {
            return artworkLeadingInset
        }

        if showTrackNumbers {
            return trackNumberLeadingInset
        }

        return plainLeadingInset
    }

    public static func rowInsets(showArtwork: Bool, showTrackNumbers: Bool) -> EdgeInsets {
        EdgeInsets(
            top: rowVerticalPadding,
            leading: rowHorizontalPadding,
            bottom: rowVerticalPadding,
            trailing: rowHorizontalPadding
        )
    }

    public static func utilityListRowInsets(verticalPadding: CGFloat = rowVerticalPadding) -> EdgeInsets {
        EdgeInsets(
            top: verticalPadding,
            leading: detailHorizontalPadding,
            bottom: verticalPadding,
            trailing: detailHorizontalPadding
        )
    }
}
