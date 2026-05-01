import EnsembleCore
import Foundation
import UniformTypeIdentifiers

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
    static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    static let contentTypes: [UTType] = [contentType]

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
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.typeIdentifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.suggestedName = suggestedName
        return provider
    }

    static func load(from providers: [NSItemProvider]) async -> MediaDragPayload? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            guard let data = await loadData(from: provider),
                  let payload = try? JSONDecoder().decode(MediaDragPayload.self, from: data) else {
                continue
            }
            return payload
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    EnsembleLogger.debug("MediaDragPayload load failed: \(error.localizedDescription)")
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
