import EnsembleCore
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

#if !os(watchOS)
/// App-internal drag payload for media references. The payload carries stable
/// identifiers only; drop targets resolve those identifiers against current cache.
struct MediaDragPayload: Codable, Equatable {
    enum Kind: String, Codable {
        case track
        case album
        case playlist
    }

    struct Item: Codable, Equatable {
        let kind: Kind
        let id: String
        let sourceKey: String?
        let title: String
        let isSmartPlaylist: Bool?
    }

    static let typeIdentifier = "com.videogorl.ensemble.media-drag-payload"
    static let contentType = UTType(exportedAs: typeIdentifier)
    static let jsonContentType = UTType.json
    static let contentTypes: [UTType] = [contentType, jsonContentType]
    private static let acceptedTypeIdentifiers = [typeIdentifier, UTType.json.identifier]

    let items: [Item]

    static func track(_ track: Track) -> MediaDragPayload {
        MediaDragPayload(items: [
            Item(
                kind: .track,
                id: track.id,
                sourceKey: track.sourceCompositeKey,
                title: track.title,
                isSmartPlaylist: nil
            )
        ])
    }

    static func album(_ album: Album) -> MediaDragPayload {
        MediaDragPayload(items: [
            Item(
                kind: .album,
                id: album.id,
                sourceKey: album.sourceCompositeKey,
                title: album.title,
                isSmartPlaylist: nil
            )
        ])
    }

    static func playlist(_ playlist: Playlist) -> MediaDragPayload {
        MediaDragPayload(items: [
            Item(
                kind: .playlist,
                id: playlist.id,
                sourceKey: playlist.sourceCompositeKey,
                title: playlist.title,
                isSmartPlaylist: playlist.isSmart
            )
        ])
    }

    static func displayPlaylist(_ displayPlaylist: DisplayPlaylist) -> MediaDragPayload {
        MediaDragPayload(
            items: displayPlaylist.playlists.map { playlist in
                Item(
                    kind: .playlist,
                    id: playlist.id,
                    sourceKey: playlist.sourceCompositeKey,
                    title: playlist.title,
                    isSmartPlaylist: playlist.isSmart
                )
            }
        )
    }

    func itemProvider(fallbackFileURL: URL? = nil) -> NSItemProvider {
        let provider = fallbackFileURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        if let data = encodedData() {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.typeIdentifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.jsonContentType.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.suggestedName = suggestedName
        return provider
    }

    func encodedData() -> Data? {
        try? JSONEncoder().encode(self)
    }

    #if os(macOS)
    func pasteboardItem(fallbackFileURL: URL? = nil) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        var wroteRepresentation = false

        if let data = encodedData() {
            item.setData(data, forType: NSPasteboard.PasteboardType(Self.typeIdentifier))
            item.setData(data, forType: NSPasteboard.PasteboardType(Self.jsonContentType.identifier))
            wroteRepresentation = true
        }

        if let fallbackFileURL {
            item.setString(fallbackFileURL.absoluteString, forType: .fileURL)
            wroteRepresentation = true
        }

        if let suggestedName {
            item.setString(suggestedName, forType: .string)
            wroteRepresentation = true
        }

        return wroteRepresentation ? item : nil
    }
    #endif

    static func canLoad(from providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            acceptedTypeIdentifiers.contains { typeIdentifier in
                providerSupportsType(provider, typeIdentifier: typeIdentifier)
            }
        }
    }

    static func debugRegisteredTypeIdentifiers(for providers: [NSItemProvider]) -> String {
        let identifiers = providers.flatMap(\.registeredTypeIdentifiers)
        return identifiers.isEmpty ? "none" : identifiers.joined(separator: ",")
    }

    static func load(from providers: [NSItemProvider]) async -> MediaDragPayload? {
        for provider in providers {
            for typeIdentifier in acceptedTypeIdentifiers where providerSupportsType(provider, typeIdentifier: typeIdentifier) {
                guard let data = await loadData(from: provider, typeIdentifier: typeIdentifier),
                      let payload = try? JSONDecoder().decode(MediaDragPayload.self, from: data) else {
                    continue
                }
                return payload
            }
        }
        return nil
    }

    private static func providerSupportsType(_ provider: NSItemProvider, typeIdentifier: String) -> Bool {
        provider.registeredTypeIdentifiers.contains(typeIdentifier) ||
            provider.hasItemConformingToTypeIdentifier(typeIdentifier)
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    EnsembleLogger.debug("MediaDragPayload load failed for type=\(typeIdentifier): \(error.localizedDescription)")
                }
                continuation.resume(returning: data)
            }
        }
    }

    private var suggestedName: String? {
        guard let first = items.first else { return nil }
        if items.count == 1 {
            return first.title
        }
        return "\(items.count) media items"
    }
}
#endif
