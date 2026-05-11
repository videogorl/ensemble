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
}

/// Flattened row description shared by native track-list renderers and tests.
///
/// Header, footer, section, and spacer rows are visual rows only. Track rows
/// carry the global index used by playback queues.
public enum NativeTrackListFlattenedRow: Equatable {
    case header
    case section(id: String, title: String)
    case track(Track, globalIndex: Int)
    case footer
    case bottomSpacer(CGFloat)
}

enum NativeTrackListFlattening {
    static func rows(
        sections: [NativeTrackListSection],
        hasHeader: Bool = false,
        hasFooter: Bool = false,
        bottomContentInset: CGFloat = 0
    ) -> [NativeTrackListFlattenedRow] {
        var rows: [NativeTrackListFlattenedRow] = []
        var globalIndex = 0

        if hasHeader {
            rows.append(.header)
        }

        for section in sections {
            if !section.title.isEmpty {
                rows.append(.section(id: section.id, title: section.title))
            }

            for track in section.tracks {
                rows.append(.track(track, globalIndex: globalIndex))
                globalIndex += 1
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
