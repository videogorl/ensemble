import EnsembleCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TrackSectionScrollRequest: Equatable {
    let id: Int
    let sectionID: String
}

/// Platform host for dense Songs track lists.
///
/// iOS/iPadOS uses `MediaTrackList` (`UITableView`) and macOS uses an AppKit
/// `NSTableView`. The calling view owns filtering/sorting; this host owns the
/// native row backend and section index wiring.
public struct SongsTrackListHost: View {
    private let sections: [NativeTrackListSection]
    private let configuration: NativeTrackListConfiguration
    private let tableHeaderContent: AnyView?
    private let tableFooterContent: AnyView?
    private let scrollOffset: Binding<CGFloat>?
    private let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    private let onTrackTap: (Track, Int) -> Void

    @State private var sectionScrollRequestID = 0
    @State private var sectionScrollRequest: TrackSectionScrollRequest?

    private var allTracks: [Track] {
        sections.flatMap(\.tracks)
    }

    public init(
        tracks: [Track],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        scrollOffset: Binding<CGFloat>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = [
            NativeTrackListSection(id: "all", title: "", tracks: tracks)
        ]
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.scrollOffset = scrollOffset
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    public init(
        sections: [NativeTrackListSection],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        scrollOffset: Binding<CGFloat>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = sections
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.scrollOffset = scrollOffset
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    public init(
        tracks: [Track],
        currentTrackId: String? = nil,
        contentRevision: UInt64? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        usesDynamicTableHeaderHeight: Bool = false,
        supplementalMetadataWidth: CGFloat? = nil,
        interactionModel: TrackRowInteractionModel,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        scrollOffset: Binding<CGFloat>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            tracks: tracks,
            configuration: .songs(
                currentTrackId: currentTrackId,
                contentRevision: contentRevision,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset,
                usesDynamicTableHeaderHeight: usesDynamicTableHeaderHeight,
                supplementalMetadataWidth: supplementalMetadataWidth,
                interactionModel: interactionModel
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            scrollOffset: scrollOffset,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    public init(
        sections: [NativeTrackListSection],
        currentTrackId: String? = nil,
        contentRevision: UInt64? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        usesDynamicTableHeaderHeight: Bool = false,
        supplementalMetadataWidth: CGFloat? = nil,
        showsSectionIndex: Bool = true,
        interactionModel: TrackRowInteractionModel,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        scrollOffset: Binding<CGFloat>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            sections: sections,
            configuration: .songs(
                currentTrackId: currentTrackId,
                contentRevision: contentRevision,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset,
                usesDynamicTableHeaderHeight: usesDynamicTableHeaderHeight,
                supplementalMetadataWidth: supplementalMetadataWidth,
                showsSectionIndex: showsSectionIndex,
                interactionModel: interactionModel
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            scrollOffset: scrollOffset,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    public var body: some View {
        #if os(iOS)
        iOSTrackList
        #elseif os(macOS)
        macTrackList
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    private var iOSTrackList: some View {
        Group {
            if configuration.showsSectionIndex {
                indexedIOSTrackList
            } else {
                flatIOSTrackList
            }
        }
    }

    private var indexedIOSTrackList: some View {
        ZStack {
            MediaTrackList(
                sections: sections,
                showArtwork: configuration.showArtwork,
                showTrackNumbers: configuration.showTrackNumbers,
                showAlbumName: configuration.showAlbumName,
                currentTrackId: configuration.currentTrackId,
                selectedTrackId: configuration.selectedTrackId,
                contentRevision: configuration.contentRevision,
                availabilityGeneration: configuration.availabilityGeneration,
                activeDownloadTrackIdentities: configuration.activeDownloadTrackIdentities,
                topContentInset: configuration.topContentInset,
                bottomContentInset: configuration.bottomContentInset,
                rowHeight: configuration.rowHeight,
                tableHeaderContent: tableHeaderContent,
                tableFooterContent: tableFooterContent,
                interactionModel: configuration.interactionModel,
                supplementalMetadataWidth: configuration.supplementalMetadataWidth,
                trackSourceLabels: configuration.trackSourceLabels,
                scrollOffset: scrollOffset,
                sectionScrollRequestID: sectionScrollRequest?.id,
                sectionScrollTargetID: sectionScrollRequest?.sectionID,
                onRemoveFromPlaylist: onRemoveFromPlaylist
            ) { track, index in
                onTrackTap(track, index)
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .libraryScrollIndexOverlay {
            sectionIndex { sectionID in
                sectionScrollRequestID += 1
                sectionScrollRequest = TrackSectionScrollRequest(
                    id: sectionScrollRequestID,
                    sectionID: sectionID
                )
            }
        }
    }

    private var flatIOSTrackList: some View {
        MediaTrackList(
            tracks: allTracks,
            showArtwork: configuration.showArtwork,
            showTrackNumbers: configuration.showTrackNumbers,
            showAlbumName: configuration.showAlbumName,
            groupByDisc: configuration.groupByDisc,
            currentTrackId: configuration.currentTrackId,
            selectedTrackId: configuration.selectedTrackId,
            contentRevision: configuration.contentRevision,
            availabilityGeneration: configuration.availabilityGeneration,
            activeDownloadTrackIdentities: configuration.activeDownloadTrackIdentities,
            managesOwnScrolling: true,
            topContentInset: configuration.topContentInset,
            bottomContentInset: configuration.bottomContentInset,
            rowHeight: configuration.rowHeight,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            interactionModel: configuration.interactionModel,
            supplementalMetadataWidth: configuration.supplementalMetadataWidth,
            trackSourceLabels: configuration.trackSourceLabels,
            scrollOffset: scrollOffset,
            onRemoveFromPlaylist: onRemoveFromPlaylist
        ) { track, index in
            onTrackTap(track, index)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
    #endif

    #if os(macOS)
    private var macTrackList: some View {
        MacNativeTrackTableView(
            sections: sections,
            showArtwork: configuration.showArtwork,
            showTrackNumbers: configuration.showTrackNumbers,
            showAlbumName: configuration.showAlbumName,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            currentTrackId: configuration.currentTrackId,
            selectedTrackId: configuration.selectedTrackId,
            availabilityGeneration: configuration.availabilityGeneration,
            activeDownloadTrackIdentities: configuration.activeDownloadTrackIdentities,
            bottomContentInset: configuration.bottomContentInset,
            tableHeaderExtraHeight: configuration.tableHeaderExtraHeight,
            usesDynamicTableHeaderHeight: configuration.usesDynamicTableHeaderHeight,
            supplementalMetadataWidth: configuration.supplementalMetadataWidth,
            trackSourceLabels: configuration.trackSourceLabels,
            rowHeight: configuration.rowHeight,
            interactionModel: configuration.interactionModel,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            sectionScrollRequest: sectionScrollRequest,
            onTrackTap: onTrackTap
        )
        .libraryScrollIndexOverlay(.centered) {
            sectionIndex { sectionID in
                sectionScrollRequestID += 1
                sectionScrollRequest = TrackSectionScrollRequest(
                    id: sectionScrollRequestID,
                    sectionID: sectionID
                )
            }
        }
    }
    #endif

    @ViewBuilder
    private func sectionIndex(onTap: @escaping (String) -> Void) -> some View {
        if configuration.showsSectionIndex && !sections.isEmpty {
            ScrollIndex(
                letters: sections.map(\.title),
                currentLetter: .constant(nil),
                onLetterTap: onTap
            )
        }
    }

}
