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
    public var rowHeight: CGFloat
    public var bottomContentInset: CGFloat
    public var tableHeaderExtraHeight: CGFloat
    public var supplementalMetadataWidth: CGFloat?
    public var currentTrackId: String?
    public var availabilityGeneration: UInt64
    public var activeDownloadTrackIdentities: Set<String>
    public var interactionModel: TrackRowInteractionModel

    public init(
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        showAlbumName: Bool = true,
        groupByDisc: Bool = false,
        showsSectionIndex: Bool = false,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        bottomContentInset: CGFloat = 0,
        tableHeaderExtraHeight: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        interactionModel: TrackRowInteractionModel = TrackRowInteractionModel()
    ) {
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.showAlbumName = showAlbumName
        self.groupByDisc = groupByDisc
        self.showsSectionIndex = showsSectionIndex
        self.rowHeight = rowHeight
        self.bottomContentInset = bottomContentInset
        self.tableHeaderExtraHeight = tableHeaderExtraHeight
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.interactionModel = interactionModel
    }

    public static func songs(
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        tableHeaderExtraHeight: CGFloat = 0,
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
            tableHeaderExtraHeight: tableHeaderExtraHeight,
            supplementalMetadataWidth: supplementalMetadataWidth,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            interactionModel: interactionModel
        )
    }
}
