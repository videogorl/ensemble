import EnsembleCore
import SwiftUI

struct TrackSectionScrollRequest: Equatable {
    let id: Int
    let sectionID: String
}

/// The one host for native track lists.
///
/// Callers pass tracks or sections and one `NativeTrackListConfiguration`.
/// The host picks the native table: UIKit `MediaTrackList` on iOS and iPadOS,
/// AppKit `MacNativeTrackTableView` on macOS. It also owns disc grouping and
/// the section index. Callers own filtering and sorting.
public struct TrackListHost: View {
    private let sections: [NativeTrackListSection]
    private let configuration: NativeTrackListConfiguration
    private let tableHeaderContent: AnyView?
    /// Changes when the header content changes without a structural change.
    /// The UIKit table reloads its hosted header row on a new value; the
    /// AppKit table reconfigures the header on every update.
    private let tableHeaderRevision: String?
    private let tableFooterContent: AnyView?
    private let onRefresh: (() async -> Void)?
    private let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    private let onTrackTap: (Track, Int) -> Void

    @State private var sectionScrollRequestID = 0
    @State private var sectionScrollRequest: TrackSectionScrollRequest?

    public init(
        tracks: [Track],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView? = nil,
        tableHeaderRevision: String? = nil,
        tableFooterContent: AnyView? = nil,
        onRefresh: (() async -> Void)? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            sections: [NativeTrackListSection(id: "all", title: "", tracks: tracks)],
            configuration: configuration,
            tableHeaderContent: tableHeaderContent,
            tableHeaderRevision: tableHeaderRevision,
            tableFooterContent: tableFooterContent,
            onRefresh: onRefresh,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    public init(
        sections: [NativeTrackListSection],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView? = nil,
        tableHeaderRevision: String? = nil,
        tableFooterContent: AnyView? = nil,
        onRefresh: (() async -> Void)? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = sections
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableHeaderRevision = tableHeaderRevision
        self.tableFooterContent = tableFooterContent
        self.onRefresh = onRefresh
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    public var body: some View {
        #if os(iOS)
        if configuration.showsSectionIndex {
            ZStack {
                nativeTable
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
            .libraryScrollIndexOverlay { sectionIndex }
        } else if configuration.managesOwnScrolling {
            nativeTable
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        } else {
            nativeTable
        }
        #elseif os(macOS)
        nativeTable
            .ignoresSafeArea(.container, edges: .top)
            .libraryScrollIndexOverlay(.centered) { sectionIndex }
        #else
        EmptyView()
        #endif
    }

    private var tableSections: [NativeTrackListSection] {
        if configuration.groupByDisc {
            return NativeTrackListSection.discSections(for: sections.allTracks)
        }
        #if os(iOS)
        // iOS shows section headers only together with the section index.
        if !configuration.showsSectionIndex {
            return [NativeTrackListSection(id: "all", title: "", tracks: sections.allTracks)]
        }
        #endif
        return sections
    }

    #if os(iOS)
    private var nativeTable: MediaTrackList {
        MediaTrackList(
            sections: tableSections,
            configuration: configuration,
            tableHeaderContent: tableHeaderContent,
            tableHeaderRevision: tableHeaderRevision,
            tableFooterContent: tableFooterContent,
            onRefresh: onRefresh,
            sectionScrollRequest: sectionScrollRequest,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }
    #elseif os(macOS)
    private var nativeTable: MacNativeTrackTableView {
        MacNativeTrackTableView(
            sections: tableSections,
            configuration: configuration,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            sectionScrollRequest: sectionScrollRequest,
            onTrackTap: onTrackTap
        )
    }
    #endif

    @ViewBuilder
    private var sectionIndex: some View {
        if configuration.showsSectionIndex && !sections.isEmpty {
            ScrollIndex(
                letters: sections.map(\.title),
                currentLetter: .constant(nil),
                onLetterTap: { sectionID in
                    sectionScrollRequestID += 1
                    sectionScrollRequest = TrackSectionScrollRequest(
                        id: sectionScrollRequestID,
                        sectionID: sectionID
                    )
                }
            )
        }
    }
}
