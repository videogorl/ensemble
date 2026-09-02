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
    public var topContentInset: CGFloat
    public var bottomContentInset: CGFloat
    public var tableHeaderExtraHeight: CGFloat
    public var usesDynamicTableHeaderHeight: Bool
    public var supplementalMetadataWidth: CGFloat?
    public var trackSourceLabels: [String: String]
    public var currentTrackId: String?
    public var selectedTrackId: String?
    public var contentRevision: UInt64?
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
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        tableHeaderExtraHeight: CGFloat = 0,
        usesDynamicTableHeaderHeight: Bool = false,
        supplementalMetadataWidth: CGFloat? = nil,
        trackSourceLabels: [String: String] = [:],
        currentTrackId: String? = nil,
        selectedTrackId: String? = nil,
        contentRevision: UInt64? = nil,
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
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.tableHeaderExtraHeight = tableHeaderExtraHeight
        self.usesDynamicTableHeaderHeight = usesDynamicTableHeaderHeight
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.trackSourceLabels = trackSourceLabels
        self.currentTrackId = currentTrackId
        self.selectedTrackId = selectedTrackId
        self.contentRevision = contentRevision
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.interactionModel = interactionModel
    }

    public static func songs(
        currentTrackId: String? = nil,
        contentRevision: UInt64? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        tableHeaderExtraHeight: CGFloat = 0,
        usesDynamicTableHeaderHeight: Bool = false,
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
            topContentInset: topContentInset,
            bottomContentInset: bottomContentInset,
            tableHeaderExtraHeight: tableHeaderExtraHeight,
            usesDynamicTableHeaderHeight: usesDynamicTableHeaderHeight,
            supplementalMetadataWidth: supplementalMetadataWidth,
            currentTrackId: currentTrackId,
            contentRevision: contentRevision,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            interactionModel: interactionModel
        )
    }
}
