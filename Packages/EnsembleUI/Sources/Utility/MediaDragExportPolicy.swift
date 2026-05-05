import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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

    static func itemProvider(
        for payload: MediaDragPayload,
        fallbackFileURL: URL? = nil,
        externalFileProvider: (@MainActor () async -> URL?)? = nil,
        externalFileTypeIdentifier: String = UTType.audio.identifier
    ) -> NSItemProvider {
        let kind = payload.primaryKind
        let canPromiseExternalFile = kind.map(supportsExternalFilePromise(for:)) ?? false
        return payload.itemProvider(
            fallbackFileURL: canPromiseExternalFile ? fallbackFileURL : nil,
            externalFileProvider: canPromiseExternalFile ? externalFileProvider : nil,
            externalFileTypeIdentifier: externalFileTypeIdentifier
        )
    }

    #if os(macOS)
    static func pasteboardWriter(
        for payload: MediaDragPayload,
        fallbackFileURL: URL? = nil,
        promisedFileName: String,
        fileTypeIdentifier: String,
        fileURLProvider: (@MainActor () async -> URL?)? = nil
    ) -> NSPasteboardWriting? {
        let kind = payload.primaryKind
        let canPromiseExternalFile = kind.map(supportsExternalFilePromise(for:)) ?? false
        if canPromiseExternalFile {
            return payload.filePromisePasteboardWriter(
                fallbackFileURL: fallbackFileURL,
                promisedFileName: promisedFileName,
                fileTypeIdentifier: fileTypeIdentifier,
                fileURLProvider: fileURLProvider
            )
        }
        return payload.pasteboardItem()
    }
    #endif
}
#endif
