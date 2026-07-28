import EnsembleAPI
import EnsemblePersistence
import Foundation

public protocol MetadataMutationClient: Sendable {
    func deleteMetadata(ids: [String]) async throws
    func updateMetadata(
        sectionId: String,
        metadataType: Int,
        ids: [String],
        fieldUpdates: [PlexMetadataFieldUpdate]
    ) async throws
}

extension PlexAPIClient: MetadataMutationClient {}

public enum MetadataMutationError: LocalizedError, Equatable {
    case unavailableOffline(String)
    case invalidSource
    case clientUnavailable
    case insufficientPermissions
    case noChangesRequested

    public var errorDescription: String? {
        switch self {
        case let .unavailableOffline(action):
            return "\(action) is only available while online."
        case .invalidSource:
            return "This item is missing a valid Plex library source."
        case .clientUnavailable:
            return "The selected Plex server is not available for metadata changes."
        case .insufficientPermissions:
            return "Only Plex server admins can edit or delete library metadata."
        case .noChangesRequested:
            return "No metadata changes were requested."
        }
    }
}

public struct MetadataEditRequest: Sendable, Equatable {
    public let title: String?
    public let sortTitle: String?
    public let titleLocked: Bool?
    public let sortTitleLocked: Bool?

    public init(
        title: String? = nil,
        sortTitle: String? = nil,
        titleLocked: Bool? = nil,
        sortTitleLocked: Bool? = nil
    ) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortTitle = sortTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.titleLocked = titleLocked
        self.sortTitleLocked = sortTitleLocked
    }

    var fieldUpdates: [PlexMetadataFieldUpdate] {
        var updates: [PlexMetadataFieldUpdate] = []
        if let title, !title.isEmpty || titleLocked != nil {
            updates.append(
                PlexMetadataFieldUpdate(fieldName: "title", value: title, isLocked: titleLocked)
            )
        } else if let titleLocked {
            updates.append(PlexMetadataFieldUpdate(fieldName: "title", isLocked: titleLocked))
        }

        if let sortTitle, !sortTitle.isEmpty || sortTitleLocked != nil {
            updates.append(
                PlexMetadataFieldUpdate(fieldName: "titleSort", value: sortTitle, isLocked: sortTitleLocked)
            )
        } else if let sortTitleLocked {
            updates.append(PlexMetadataFieldUpdate(fieldName: "titleSort", isLocked: sortTitleLocked))
        }
        return updates
    }
}

@MainActor
public final class MetadataMutationService {
    public static let metadataDidChange = Notification.Name("MetadataMutationService.metadataDidChange")

    private struct SourceContext {
        let accountId: String
        let serverId: String
        let libraryId: String
    }

    private let libraryRepository: LibraryRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let isOffline: () -> Bool
    private let canManageServer: (_ accountId: String, _ serverId: String) -> Bool
    private let makeClient: (_ accountId: String, _ serverId: String) -> MetadataMutationClient?
    private let clearLyricsCache: (_ ratingKey: String, _ sourceCompositeKey: String) -> Void
    private let removeDeletedTracksFromPlayback: @MainActor (Set<String>) -> Void

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        isOffline: @escaping () -> Bool,
        canManageServer: @escaping (_ accountId: String, _ serverId: String) -> Bool,
        makeClient: @escaping (_ accountId: String, _ serverId: String) -> MetadataMutationClient?,
        clearLyricsCache: @escaping (_ ratingKey: String, _ sourceCompositeKey: String) -> Void,
        removeDeletedTracksFromPlayback: @escaping @MainActor (Set<String>) -> Void
    ) {
        self.libraryRepository = libraryRepository
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.isOffline = isOffline
        self.canManageServer = canManageServer
        self.makeClient = makeClient
        self.clearLyricsCache = clearLyricsCache
        self.removeDeletedTracksFromPlayback = removeDeletedTracksFromPlayback
    }

    public func deleteTrack(_ track: Track) async throws {
        try ensureOnline(action: "Delete Track")
        let source = try sourceContext(for: track.sourceCompositeKey)
        logServerCapabilityIfUnknown(source: source)
        guard let client = makeClient(source.accountId, source.serverId) else {
            throw MetadataMutationError.clientUnavailable
        }

        do {
            try await client.deleteMetadata(ids: [track.id])
        } catch {
            throw mapMutationError(error)
        }
        try await cleanupTrackArtifacts(track)
        try await libraryRepository.deleteTrack(ratingKey: track.id, sourceCompositeKey: track.sourceCompositeKey)
        removeDeletedTracksFromPlayback(Set([track.sourceScopedID]))
        postMetadataDidChange()
    }

    public func deleteAlbum(_ album: Album) async throws {
        try ensureOnline(action: "Delete Album")
        let source = try sourceContext(for: album.sourceCompositeKey)
        logServerCapabilityIfUnknown(source: source)
        guard let client = makeClient(source.accountId, source.serverId) else {
            throw MetadataMutationError.clientUnavailable
        }

        let albumSourceKey = album.sourceCompositeKey ?? "plex:\(source.accountId):\(source.serverId):\(source.libraryId)"
        let albumTracks = try await libraryRepository.fetchTracks(
            forAlbum: album.id,
            sourceCompositeKey: albumSourceKey
        )
        let trackModels = albumTracks.map(Track.init(from:))

        do {
            try await client.deleteMetadata(ids: [album.id])
        } catch {
            throw mapMutationError(error)
        }

        for track in trackModels {
            try await cleanupTrackArtifacts(track)
        }
        artworkDownloadManager.deleteArtwork(
            ratingKey: album.id,
            type: .album,
            sourceCompositeKey: album.sourceCompositeKey
        )
        try await libraryRepository.deleteAlbum(ratingKey: album.id, sourceCompositeKey: album.sourceCompositeKey)
        removeDeletedTracksFromPlayback(Set(trackModels.map(\.sourceScopedID)))
        postMetadataDidChange()
    }

    public func editTrack(_ track: Track, request: MetadataEditRequest) async throws {
        let updates = request.fieldUpdates
        guard !updates.isEmpty else { throw MetadataMutationError.noChangesRequested }
        try ensureOnline(action: "Edit Track")
        let source = try sourceContext(for: track.sourceCompositeKey)
        logServerCapabilityIfUnknown(source: source)
        guard let client = makeClient(source.accountId, source.serverId) else {
            throw MetadataMutationError.clientUnavailable
        }

        do {
            try await client.updateMetadata(
                sectionId: source.libraryId,
                metadataType: 10,
                ids: [track.id],
                fieldUpdates: updates
            )
        } catch {
            throw mapMutationError(error)
        }

        if let title = request.title, !title.isEmpty {
            try await libraryRepository.updateTrackTitle(
                ratingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey,
                title: title
            )
        }
        postMetadataDidChange()
    }

    public func editAlbum(_ album: Album, request: MetadataEditRequest) async throws {
        let updates = request.fieldUpdates
        guard !updates.isEmpty else { throw MetadataMutationError.noChangesRequested }
        try ensureOnline(action: "Edit Album")
        let source = try sourceContext(for: album.sourceCompositeKey)
        logServerCapabilityIfUnknown(source: source)
        guard let client = makeClient(source.accountId, source.serverId) else {
            throw MetadataMutationError.clientUnavailable
        }

        do {
            try await client.updateMetadata(
                sectionId: source.libraryId,
                metadataType: 9,
                ids: [album.id],
                fieldUpdates: updates
            )
        } catch {
            throw mapMutationError(error)
        }

        if let title = request.title, !title.isEmpty {
            try await libraryRepository.updateAlbumTitle(
                ratingKey: album.id,
                sourceCompositeKey: album.sourceCompositeKey,
                title: title
            )
        }
        postMetadataDidChange()
    }

    public func editArtist(_ artist: Artist, request: MetadataEditRequest) async throws {
        let updates = request.fieldUpdates
        guard !updates.isEmpty else { throw MetadataMutationError.noChangesRequested }
        try ensureOnline(action: "Edit Artist")
        let source = try sourceContext(for: artist.sourceCompositeKey)
        logServerCapabilityIfUnknown(source: source)
        guard let client = makeClient(source.accountId, source.serverId) else {
            throw MetadataMutationError.clientUnavailable
        }

        do {
            try await client.updateMetadata(
                sectionId: source.libraryId,
                metadataType: 8,
                ids: [artist.id],
                fieldUpdates: updates
            )
        } catch {
            throw mapMutationError(error)
        }

        if let title = request.title, !title.isEmpty {
            try await libraryRepository.updateArtistName(
                ratingKey: artist.id,
                sourceCompositeKey: artist.sourceCompositeKey,
                name: title
            )
        }
        postMetadataDidChange()
    }

    private func cleanupTrackArtifacts(_ track: Track) async throws {
        if let sourceCompositeKey = track.sourceCompositeKey {
            try? await downloadManager.deleteDownload(
                forTrackRatingKey: track.id,
                sourceCompositeKey: sourceCompositeKey
            )
            try await removeTrackMemberships(
                OfflineTrackReference(
                    trackRatingKey: track.id,
                    trackSourceCompositeKey: sourceCompositeKey
                )
            )
            clearLyricsCache(track.id, sourceCompositeKey)
        } else {
            try? await downloadManager.deleteDownload(forTrackRatingKey: track.id)
        }

        artworkDownloadManager.deleteArtwork(
            ratingKey: track.id,
            type: .track,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }

    private func removeTrackMemberships(_ reference: OfflineTrackReference) async throws {
        let targetKeys = try await targetRepository.fetchTargetKeys(containing: reference)
        for targetKey in targetKeys {
            let remaining = try await targetRepository.fetchTrackReferences(targetKey: targetKey)
                .filter { $0 != reference }

            if remaining.isEmpty {
                try await targetRepository.deleteTarget(key: targetKey)
            } else {
                try await targetRepository.replaceMemberships(targetKey: targetKey, trackReferences: remaining)
            }
        }
    }

    private func ensureOnline(action: String) throws {
        if isOffline() {
            throw MetadataMutationError.unavailableOffline(action)
        }
    }

    private func logServerCapabilityIfUnknown(source: SourceContext) {
        guard !canManageServer(source.accountId, source.serverId) else { return }
        EnsembleLogger.info(
            "Metadata mutation permission unknown for \(source.accountId):\(source.serverId); attempting request and deferring auth to Plex."
        )
    }

    private func mapMutationError(_ error: Error) -> Error {
        if case PlexAPIError.notAuthenticated = error {
            return MetadataMutationError.insufficientPermissions
        }

        if case let PlexAPIError.httpError(statusCode) = error,
           statusCode == 401 || statusCode == 403
        {
            return MetadataMutationError.insufficientPermissions
        }

        return error
    }

    private func postMetadataDidChange() {
        NotificationCenter.default.post(name: Self.metadataDidChange, object: nil)
    }

    private func sourceContext(for sourceCompositeKey: String?) throws -> SourceContext {
        guard let identity = MediaSourceIdentity.parse(sourceCompositeKey),
              let libraryId = identity.libraryId else {
            throw MetadataMutationError.invalidSource
        }
        return SourceContext(
            accountId: identity.accountId,
            serverId: identity.serverId,
            libraryId: libraryId
        )
    }
}
