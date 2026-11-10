import EnsembleCore
import SwiftUI

/// The one configuration every `TrackListHost` caller passes.
///
/// Row display, native backend state, and resolved actions live here so Songs,
/// Search, detail screens, and virtual collections do not drift as native row
/// behavior evolves. The host picks the UIKit or AppKit table.
public struct NativeTrackListConfiguration {
    public var showArtwork: Bool
    public var showTrackNumbers: Bool
    public var showAlbumName: Bool
    public var groupByDisc: Bool
    public var showsSectionIndex: Bool
    /// iOS: when false, the table does not scroll and sits at its full height
    /// inside a parent `ScrollView` (Search, artist favourites). The caller
    /// sizes it. macOS tables always own their scroll view.
    public var managesOwnScrolling: Bool
    public var rowHeight: CGFloat
    public var bottomContentInset: CGFloat
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
        managesOwnScrolling: Bool = true,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        bottomContentInset: CGFloat = 0,
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
        self.managesOwnScrolling = managesOwnScrolling
        self.rowHeight = rowHeight
        self.bottomContentInset = bottomContentInset
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
}
