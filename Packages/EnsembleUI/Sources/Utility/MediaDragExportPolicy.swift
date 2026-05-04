import Foundation

#if !os(watchOS)
enum MediaDragDestination: Equatable {
    case inAppPlaylist
    case queueReorder
    case externalFile
    case finder
}

enum MediaDragOperationPolicy: Equatable {
    case copy
    case move
    case unsupported(reason: String)
}

/// Single policy matrix for media drag/drop and file-export defaults.
struct MediaDragExportPolicy {
    static func operation(for kind: MediaDragPayload.Kind, destination: MediaDragDestination) -> MediaDragOperationPolicy {
        switch destination {
        case .inAppPlaylist:
            return .copy
        case .queueReorder:
            return kind == .track ? .move : .unsupported(reason: "Only queue track rows can be reordered.")
        case .externalFile, .finder:
            return kind == .track ? .copy : .unsupported(reason: "Only tracks provide audio file promises.")
        }
    }

    static func supportsExternalFilePromise(for kind: MediaDragPayload.Kind) -> Bool {
        switch kind {
        case .track:
            return true
        case .album, .playlist:
            return false
        }
    }
}
#endif
