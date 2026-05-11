import EnsembleCore
import SwiftUI
import Nuke

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
    private let searchTextBinding: Binding<String>?
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
        searchTextBinding: Binding<String>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = [
            NativeTrackListSection(id: "all", title: "", tracks: tracks)
        ]
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.searchTextBinding = searchTextBinding
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    public init(
        sections: [NativeTrackListSection],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        searchTextBinding: Binding<String>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = sections
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.searchTextBinding = searchTextBinding
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    public init(
        tracks: [Track],
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        interactionModel: TrackRowInteractionModel,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        searchTextBinding: Binding<String>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            tracks: tracks,
            configuration: .songs(
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                bottomContentInset: bottomContentInset,
                supplementalMetadataWidth: supplementalMetadataWidth,
                interactionModel: interactionModel
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            searchTextBinding: searchTextBinding,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    public init(
        sections: [NativeTrackListSection],
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        showsSectionIndex: Bool = true,
        interactionModel: TrackRowInteractionModel,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        searchTextBinding: Binding<String>? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            sections: sections,
            configuration: .songs(
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                bottomContentInset: bottomContentInset,
                supplementalMetadataWidth: supplementalMetadataWidth,
                showsSectionIndex: showsSectionIndex,
                interactionModel: interactionModel
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            searchTextBinding: searchTextBinding,
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
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(sections) { section in
                                    iOSSection(section, allTracks: allTracks)
                                }
                            }
                            .padding(.vertical)
                        }

                        sectionIndex { sectionID in
                            proxy.scrollTo(sectionID, anchor: .top)
                        }
                    }
                }
            } else {
                MediaTrackList(
                    tracks: allTracks,
                    showArtwork: configuration.showArtwork,
                    showTrackNumbers: configuration.showTrackNumbers,
                    showAlbumName: configuration.showAlbumName,
                    groupByDisc: configuration.groupByDisc,
                    currentTrackId: configuration.currentTrackId,
                    availabilityGeneration: configuration.availabilityGeneration,
                    activeDownloadRatingKeys: configuration.activeDownloadRatingKeys,
                    managesOwnScrolling: true,
                    bottomContentInset: configuration.bottomContentInset,
                    rowHeight: configuration.rowHeight,
                    tableHeaderContent: tableHeaderContent,
                    tableFooterContent: tableFooterContent,
                    searchTextBinding: searchTextBinding,
                    interactionModel: configuration.interactionModel,
                    supplementalMetadataWidth: configuration.supplementalMetadataWidth,
                    onRemoveFromPlaylist: onRemoveFromPlaylist
                ) { track, index in
                    onTrackTap(track, index)
                }
            }
        }
    }

    private func iOSSection(
        _ section: NativeTrackListSection,
        allTracks: [Track]
    ) -> some View {
        let height = CGFloat(section.tracks.count) * configuration.rowHeight

        return VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            if !section.title.isEmpty {
                sectionHeader(section.title)
            }

            MediaTrackList(
                tracks: section.tracks,
                showArtwork: configuration.showArtwork,
                showTrackNumbers: configuration.showTrackNumbers,
                showAlbumName: configuration.showAlbumName,
                groupByDisc: configuration.groupByDisc,
                currentTrackId: configuration.currentTrackId,
                availabilityGeneration: configuration.availabilityGeneration,
                activeDownloadRatingKeys: configuration.activeDownloadRatingKeys,
                rowHeight: configuration.rowHeight,
                interactionModel: configuration.interactionModel,
                supplementalMetadataWidth: configuration.supplementalMetadataWidth
            ) { track, _ in
                onTrackTap(track, allTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
            }
            .frame(height: height)
        }
        .id(section.id)
    }
    #endif

    #if os(macOS)
    private var macTrackList: some View {
        searchableIfNeeded(
            ZStack(alignment: .trailing) {
            MacNativeTrackTableView(
                sections: sections,
                showArtwork: configuration.showArtwork,
                showTrackNumbers: configuration.showTrackNumbers,
                showAlbumName: configuration.showAlbumName,
                tableHeaderContent: tableHeaderContent,
                tableFooterContent: tableFooterContent,
                currentTrackId: configuration.currentTrackId,
                availabilityGeneration: configuration.availabilityGeneration,
                activeDownloadRatingKeys: configuration.activeDownloadRatingKeys,
                bottomContentInset: configuration.bottomContentInset,
                tableHeaderExtraHeight: configuration.tableHeaderExtraHeight,
                supplementalMetadataWidth: configuration.supplementalMetadataWidth,
                rowHeight: configuration.rowHeight,
                interactionModel: configuration.interactionModel,
                onRemoveFromPlaylist: onRemoveFromPlaylist,
                sectionScrollRequest: sectionScrollRequest,
                onTrackTap: onTrackTap
            )

            sectionIndex { sectionID in
                sectionScrollRequestID += 1
                sectionScrollRequest = TrackSectionScrollRequest(
                    id: sectionScrollRequestID,
                    sectionID: sectionID
                )
            }
            }
        )
    }

    @ViewBuilder
    private func searchableIfNeeded<Content: View>(_ content: Content) -> some View {
        if let searchTextBinding {
            content.searchable(text: searchTextBinding)
        } else {
            content
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
            .libraryScrollIndexPositioning(.centered)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        EnsembleBrowseSectionHeader(title, backgroundColor: platformBackground)
    }

    private var platformBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #elseif os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.clear
        #endif
    }
}
