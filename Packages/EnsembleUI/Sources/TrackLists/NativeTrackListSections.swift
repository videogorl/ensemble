import EnsembleCore
import SwiftUI

/// Shared section model for native track list backends.
///
/// Screens can pass a flat section or indexed sections without depending on a
/// Songs-specific type name.
public struct NativeTrackListSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let tracks: [Track]

    public init(id: String, title: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.tracks = tracks
    }

    /// One section per disc in disc order, keeping track order within a disc.
    /// Sections are titled only when there is more than one disc.
    static func discSections(for tracks: [Track]) -> [NativeTrackListSection] {
        let grouped = Dictionary(grouping: tracks, by: \.discNumber)
        let discs = grouped.keys.sorted()
        let showsTitles = discs.count > 1
        return discs.map { disc in
            NativeTrackListSection(
                id: "disc-\(disc)",
                title: showsTitles ? "Disc \(disc)" : "",
                tracks: grouped[disc] ?? []
            )
        }
    }
}

extension Array where Element == NativeTrackListSection {
    /// All tracks in order. A single section keeps the caller's array storage,
    /// which lets the UIKit table skip its per-track comparison on unchanged
    /// updates.
    var allTracks: [Track] {
        count == 1 ? self[0].tracks : flatMap(\.tracks)
    }
}

func arraysShareStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    guard !lhs.isEmpty else { return true }
    return lhs.withUnsafeBufferPointer { lhsBuffer in
        rhs.withUnsafeBufferPointer { rhsBuffer in
            lhsBuffer.baseAddress == rhsBuffer.baseAddress
        }
    }
}

/// Row bookkeeping shared by the UIKit and AppKit track tables: the
/// sections in display order and each track's global index, its position in
/// the queue a tap builds from the whole list.
struct TrackListRows {
    /// A row of a table without native sections (AppKit). Header, footer,
    /// section and spacer rows are visual only.
    enum FlatRow: Equatable {
        case header
        case section(id: String, title: String)
        /// A position in `sections`; `track(section:row:)` resolves it.
        case track(section: Int, row: Int)
        case footer
        case bottomSpacer(CGFloat)
    }

    let sections: [NativeTrackListSection]
    /// Global index of each section's first track.
    private let firstTrackIndexes: [Int]

    init(sections: [NativeTrackListSection]) {
        self.sections = sections
        var nextIndex = 0
        firstTrackIndexes = sections.map { section in
            defer { nextIndex += section.tracks.count }
            return nextIndex
        }
    }

    /// The track at `row` of `section` with its global index, or nil for a
    /// position the table still holds from before an update.
    func track(section: Int, row: Int) -> (track: Track, index: Int)? {
        guard sections.indices.contains(section),
              sections[section].tracks.indices.contains(row) else { return nil }
        return (sections[section].tracks[row], firstTrackIndexes[section] + row)
    }

    /// Every track in order. One section keeps the caller's array storage.
    var tracks: [Track] { sections.allTracks }

    func position(ofTrackID id: String) -> (section: Int, row: Int)? {
        for (section, content) in sections.enumerated() {
            if let row = content.tracks.firstIndex(where: { $0.playbackIdentity == id }) {
                return (section, row)
            }
        }
        return nil
    }

    func section(withID id: String) -> Int? {
        sections.firstIndex { $0.id == id }
    }

    /// Same section ids, titles and track counts, in order.
    func hasSameSections(as other: TrackListRows) -> Bool {
        sections.count == other.sections.count && zip(sections, other.sections).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.tracks.count == $1.tracks.count
        }
    }

    /// Same sections whose track arrays share storage with `other`'s, which
    /// proves the tracks unchanged without comparing them.
    func sharesStorage(with other: TrackListRows) -> Bool {
        hasSameSections(as: other) && zip(sections, other.sections).allSatisfy {
            arraysShareStorage($0.tracks, $1.tracks)
        }
    }

    func flattened(
        hasHeader: Bool = false,
        hasFooter: Bool = false,
        bottomContentInset: CGFloat = 0
    ) -> [FlatRow] {
        var rows: [FlatRow] = []
        rows.reserveCapacity(firstTrackIndexes.last.map { $0 + (sections.last?.tracks.count ?? 0) } ?? 0)
        if hasHeader {
            rows.append(.header)
        }
        for (section, content) in sections.enumerated() {
            if !content.title.isEmpty {
                rows.append(.section(id: content.id, title: content.title))
            }
            for row in content.tracks.indices {
                rows.append(.track(section: section, row: row))
            }
        }
        if hasFooter {
            rows.append(.footer)
        }
        if bottomContentInset > 0 {
            rows.append(.bottomSpacer(bottomContentInset))
        }
        return rows
    }
}

/// What a track table does after an update: reload when the tracks, their
/// order or the sections change; redraw the visible rows when the same tracks
/// have changed details or row state changed; otherwise nothing. Both native
/// tables use this one rule.
enum TrackListChange: Equatable {
    case none
    case reconfigureVisibleRows
    case reload

    /// Everything one update compares.
    struct State {
        var rows: TrackListRows
        /// Equal non-nil revisions are the caller's promise of equal tracks.
        var contentRevision: UInt64?
        var hasHeader = false
        /// The UIKit table reloads its hosted header row when this changes.
        var headerRevision: String?
        var hasFooter = false
        /// The AppKit table draws the bottom inset as a spacer row.
        var bottomSpacer: CGFloat = 0
        var rowState: RowState
    }

    /// Display and runtime state that row content depends on besides the tracks.
    struct RowState: Equatable {
        let showArtwork: Bool
        let showTrackNumbers: Bool
        let showAlbumName: Bool
        let rowHeight: CGFloat
        let supplementalMetadataWidth: CGFloat?
        let trackSourceLabels: [String: String]
        let currentTrackId: String?
        let availabilityGeneration: UInt64
        let activeDownloadTrackIdentities: Set<String>
        let isOffline: Bool
        /// Favourite state the interaction model resolves outside the tracks.
        let displayRatingsRevision: UInt64

        init(configuration: NativeTrackListConfiguration, isOffline: Bool, displayRatingsRevision: UInt64) {
            showArtwork = configuration.showArtwork
            showTrackNumbers = configuration.showTrackNumbers
            showAlbumName = configuration.showAlbumName
            rowHeight = configuration.rowHeight
            supplementalMetadataWidth = configuration.supplementalMetadataWidth
            trackSourceLabels = configuration.trackSourceLabels
            currentTrackId = configuration.currentTrackId
            availabilityGeneration = configuration.availabilityGeneration
            activeDownloadTrackIdentities = configuration.activeDownloadTrackIdentities
            self.isOffline = isOffline
            self.displayRatingsRevision = displayRatingsRevision
        }
    }

    static func between(_ old: State, _ new: State) -> TrackListChange {
        guard old.hasHeader == new.hasHeader,
              old.headerRevision == new.headerRevision,
              old.hasFooter == new.hasFooter,
              old.bottomSpacer == new.bottomSpacer,
              old.rows.hasSameSections(as: new.rows) else { return .reload }

        let tracksUnchanged = if let revision = new.contentRevision {
            revision == old.contentRevision
        } else {
            old.rows.sharesStorage(with: new.rows)
        }
        if !tracksUnchanged {
            var detailsChanged = false
            for (oldSection, newSection) in zip(old.rows.sections, new.rows.sections) {
                for (oldTrack, newTrack) in zip(oldSection.tracks, newSection.tracks) {
                    guard oldTrack.sourceScopedID == newTrack.sourceScopedID else { return .reload }
                    detailsChanged = detailsChanged || oldTrack != newTrack
                }
            }
            if detailsChanged { return .reconfigureVisibleRows }
        }
        return old.rowState == new.rowState ? .none : .reconfigureVisibleRows
    }
}
