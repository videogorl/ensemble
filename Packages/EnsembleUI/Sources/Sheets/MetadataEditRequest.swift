import SwiftUI

enum MetadataEditItemKind {
    case track
    case album
    case artist

    var title: String {
        switch self {
        case .track: return "Edit Track"
        case .album: return "Edit Album"
        case .artist: return "Edit Artist"
        }
    }

    var fieldLabel: String {
        switch self {
        case .track: return "Track title"
        case .album: return "Album title"
        case .artist: return "Artist name"
        }
    }
}

@MainActor
struct ContextMenuMetadataEditorRequest: Identifiable {
    let id = UUID()
    let kind: MetadataEditItemKind
    let currentTitle: String
    let onSave: (String) async throws -> Void
}
