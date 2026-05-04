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

    static func trackItemProvider(for track: Track, shareService: ShareService) -> NSItemProvider {
        trackItemProvider(for: track) { [shareService, track] in
            await shareService.prepareTrackFileURL(track: track)
        }
    }

    static func trackItemProvider(
        for track: Track,
        externalFileProvider: (@MainActor () async -> URL?)? = nil
    ) -> NSItemProvider {
        let fileURL = track.localFilePath.map(URL.init(fileURLWithPath:))
        let exportMetadata = TrackFileExportMetadata(track: track)
        let provider = MediaDragPayload.track(track).itemProvider(
            fallbackFileURL: fileURL,
            externalFileProvider: externalFileProvider,
            externalFileTypeIdentifier: fileTypeIdentifier(for: exportMetadata)
        )
        provider.suggestedName = exportMetadata.sanitizedBaseName
        return provider
    }

    func itemProvider(
        fallbackFileURL: URL? = nil,
        externalFileProvider: (@MainActor () async -> URL?)? = nil,
        externalFileTypeIdentifier: String = UTType.audio.identifier
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        registerExternalFileRepresentation(
            on: provider,
            fallbackFileURL: fallbackFileURL,
            externalFileProvider: externalFileProvider,
            fileTypeIdentifier: externalFileTypeIdentifier
        )

        if let data = encodedData() {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.typeIdentifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.jsonContentType.identifier,
                visibility: .ownProcess
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
    static func trackPasteboardWriter(for track: Track, shareService: ShareService) -> NSPasteboardWriting? {
        let fileURL = track.localFilePath.map(URL.init(fileURLWithPath:))
        let exportMetadata = TrackFileExportMetadata(track: track)
        return MediaDragPayload.track(track).filePromisePasteboardWriter(
            fallbackFileURL: fileURL,
            promisedFileName: exportMetadata.fileName,
            fileTypeIdentifier: fileTypeIdentifier(for: exportMetadata),
            fileURLProvider: { [shareService, track] in
                await shareService.prepareTrackFileURL(track: track)
            }
        )
    }

    func pasteboardItem(fallbackFileURL: URL? = nil) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        var wroteRepresentation = false

        if let data = encodedData() {
            item.setData(data, forType: NSPasteboard.PasteboardType(Self.typeIdentifier))
            wroteRepresentation = true
        }

        if let fallbackFileURL {
            item.setString(fallbackFileURL.absoluteString, forType: .fileURL)
            wroteRepresentation = true
        }

        return wroteRepresentation ? item : nil
    }

    func filePromisePasteboardWriter(
        fallbackFileURL: URL? = nil,
        promisedFileName: String,
        fileTypeIdentifier: String,
        fileURLProvider: (@MainActor () async -> URL?)? = nil
    ) -> NSPasteboardWriting? {
        guard fallbackFileURL != nil || fileURLProvider != nil else {
            return pasteboardItem()
        }

        return MediaDragFilePromiseProvider(
            payload: self,
            promisedFileName: promisedFileName,
            fileTypeIdentifier: fileTypeIdentifier,
            fileURLProvider: {
                if let url = await fileURLProvider?() {
                    return url
                }
                return fallbackFileURL
            }
        )
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

    private func registerExternalFileRepresentation(
        on provider: NSItemProvider,
        fallbackFileURL: URL?,
        externalFileProvider: (@MainActor () async -> URL?)?,
        fileTypeIdentifier: String
    ) {
        guard fallbackFileURL != nil || externalFileProvider != nil else { return }

        provider.registerFileRepresentation(
            forTypeIdentifier: fileTypeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)

            if let externalFileProvider {
                Task { @MainActor in
                    guard !progress.isCancelled else {
                        completion(nil, false, Self.fileDragCancelledError)
                        return
                    }

                    let fileURL = await externalFileProvider() ?? fallbackFileURL
                    progress.completedUnitCount = fileURL == nil ? 0 : 1
                    completion(fileURL, fileURL != nil, fileURL == nil ? Self.fileUnavailableError : nil)
                }
            } else {
                progress.completedUnitCount = fallbackFileURL == nil ? 0 : 1
                completion(
                    fallbackFileURL,
                    fallbackFileURL != nil,
                    fallbackFileURL == nil ? Self.fileUnavailableError : nil
                )
            }

            return progress
        }
    }

    fileprivate static var fileUnavailableError: NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "No audio file was available for this drag."]
        )
    }

    private static var fileDragCancelledError: NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "The file drag was cancelled."]
        )
    }

    private static func fileTypeIdentifier(for exportMetadata: TrackFileExportMetadata) -> String {
        UTType(filenameExtension: exportMetadata.fileExtension)?.identifier ??
            UTType(filenameExtension: "mp3")?.identifier ??
            UTType.audio.identifier
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

#if os(macOS)
private final class MediaDragFilePromiseProvider: NSObject, NSPasteboardWriting {
    private let payloadData: Data?
    // File promise delegates must stay alive until Finder finishes resolving the drag.
    private let retainedDelegate: MediaDragFilePromiseDelegate
    private let filePromiseProvider: NSFilePromiseProvider

    init(
        payload: MediaDragPayload,
        promisedFileName: String,
        fileTypeIdentifier: String,
        fileURLProvider: @escaping @MainActor () async -> URL?
    ) {
        let promiseDelegate = MediaDragFilePromiseDelegate(
            promisedFileName: promisedFileName,
            fileURLProvider: fileURLProvider
        )
        self.payloadData = payload.encodedData()
        self.retainedDelegate = promiseDelegate
        self.filePromiseProvider = NSFilePromiseProvider(fileType: fileTypeIdentifier, delegate: promiseDelegate)
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = filePromiseProvider.writableTypes(for: pasteboard)
        if payloadData != nil {
            types.insert(NSPasteboard.PasteboardType(MediaDragPayload.typeIdentifier), at: 0)
        }
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == MediaDragPayload.typeIdentifier {
            return payloadData
        }
        return filePromiseProvider.pasteboardPropertyList(forType: type)
    }

    func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type.rawValue == MediaDragPayload.typeIdentifier {
            return []
        }
        return filePromiseProvider.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

private final class MediaDragFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let promisedFileName: String
    private let fileURLProvider: @MainActor () async -> URL?
    private let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.videogorl.ensemble.media-drag-file-promise"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(
        promisedFileName: String,
        fileURLProvider: @escaping @MainActor () async -> URL?
    ) {
        self.promisedFileName = promisedFileName
        self.fileURLProvider = fileURLProvider
        super.init()
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        promisedFileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        filePromiseQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            guard let sourceURL = await fileURLProvider() else {
                completionHandler(MediaDragPayload.fileUnavailableError)
                return
            }

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: sourceURL, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
#endif
#endif
