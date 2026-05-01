import EnsembleCore
import SwiftUI

/// Shared configuration for native track-list hosts.
///
/// Keep row display, native backend state, and resolved action plumbing in one
/// contract so Songs, Search, detail screens, and virtual collections do not
/// drift as native row behavior evolves.
public struct NativeTrackListConfiguration {
    public var showArtwork: Bool
    public var showTrackNumbers: Bool
    public var showAlbumName: Bool
    public var groupByDisc: Bool
    public var showsSectionIndex: Bool
    public var managesOwnScrolling: Bool
    public var rowHeight: CGFloat
    public var bottomContentInset: CGFloat
    public var supplementalMetadataWidth: CGFloat?
    public var currentTrackId: String?
    public var availabilityGeneration: UInt64
    public var activeDownloadRatingKeys: Set<String>
    public var interactionModel: TrackRowInteractionModel

    public init(
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        showAlbumName: Bool = true,
        groupByDisc: Bool = false,
        showsSectionIndex: Bool = false,
        managesOwnScrolling: Bool = true,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        interactionModel: TrackRowInteractionModel = TrackRowInteractionModel()
    ) {
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.showAlbumName = showAlbumName
        self.groupByDisc = groupByDisc
        self.showsSectionIndex = showsSectionIndex
        self.managesOwnScrolling = managesOwnScrolling
        self.rowHeight = rowHeight
        self.bottomContentInset = bottomContentInset
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadRatingKeys = activeDownloadRatingKeys
        self.interactionModel = interactionModel
    }

    public static func songs(
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        showsSectionIndex: Bool = false,
        interactionModel: TrackRowInteractionModel
    ) -> NativeTrackListConfiguration {
        NativeTrackListConfiguration(
            showArtwork: true,
            showTrackNumbers: false,
            showAlbumName: true,
            groupByDisc: false,
            showsSectionIndex: showsSectionIndex,
            bottomContentInset: bottomContentInset,
            supplementalMetadataWidth: supplementalMetadataWidth,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            interactionModel: interactionModel
        )
    }

    public static func albumDetail(
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        interactionModel: TrackRowInteractionModel
    ) -> NativeTrackListConfiguration {
        NativeTrackListConfiguration(
            showArtwork: false,
            showTrackNumbers: true,
            showAlbumName: false,
            groupByDisc: true,
            bottomContentInset: bottomContentInset,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            interactionModel: interactionModel
        )
    }
}
