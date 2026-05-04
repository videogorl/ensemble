import Foundation

@MainActor
public protocol MetadataMutationWorkflowMutating: AnyObject {
    func editTrack(_ track: Track, request: MetadataEditRequest) async throws
    func editAlbum(_ album: Album, request: MetadataEditRequest) async throws
    func editArtist(_ artist: Artist, request: MetadataEditRequest) async throws
    func deleteTrack(_ track: Track) async throws
    func deleteAlbum(_ album: Album) async throws
}

extension MetadataMutationService: MetadataMutationWorkflowMutating {}

public struct MetadataMutationToastScope: Equatable, Sendable {
    public static let track = MetadataMutationToastScope(dedupePrefix: "track")
    public static let album = MetadataMutationToastScope(dedupePrefix: "album")
    public static let albumDetail = MetadataMutationToastScope(dedupePrefix: "album-detail")
    public static let artist = MetadataMutationToastScope(dedupePrefix: "artist")

    public let dedupePrefix: String

    public init(dedupePrefix: String) {
        self.dedupePrefix = dedupePrefix
    }
}

public struct MetadataMutationWorkflowResult {
    public let successToast: ToastPayload

    public init(successToast: ToastPayload) {
        self.successToast = successToast
    }
}

/// Shared metadata mutation workflow for track, album, and artist edit/delete surfaces.
///
/// The service owns request creation, mutation dispatch, and toast payload policy. Views
/// retain ownership of editor presentation, confirmation dialogs, and post-delete navigation.
@MainActor
public final class MetadataMutationWorkflow {
    private enum Icon {
        static let deleteSuccess = "trash.fill"
        static let editSuccess = "checkmark.circle.fill"
        static let failure = "exclamationmark.triangle.fill"
    }

    private let mutator: MetadataMutationWorkflowMutating

    public init(mutator: MetadataMutationWorkflowMutating) {
        self.mutator = mutator
    }

    public func editTrack(
        _ track: Track,
        title newTitle: String,
        scope: MetadataMutationToastScope = .track
    ) async throws -> MetadataMutationWorkflowResult {
        try await mutator.editTrack(track, request: MetadataEditRequest(title: newTitle))
        return MetadataMutationWorkflowResult(
            successToast: editSuccessToast(
                noun: "Track",
                itemID: track.id,
                savedTitle: newTitle,
                scope: scope
            )
        )
    }

    public func editAlbum(
        _ album: Album,
        title newTitle: String,
        scope: MetadataMutationToastScope = .album
    ) async throws -> MetadataMutationWorkflowResult {
        try await mutator.editAlbum(album, request: MetadataEditRequest(title: newTitle))
        return MetadataMutationWorkflowResult(
            successToast: editSuccessToast(
                noun: "Album",
                itemID: album.id,
                savedTitle: newTitle,
                scope: scope
            )
        )
    }

    public func editArtist(
        _ artist: Artist,
        title newTitle: String,
        scope: MetadataMutationToastScope = .artist
    ) async throws -> MetadataMutationWorkflowResult {
        try await mutator.editArtist(artist, request: MetadataEditRequest(title: newTitle))
        return MetadataMutationWorkflowResult(
            successToast: editSuccessToast(
                noun: "Artist",
                itemID: artist.id,
                savedTitle: newTitle,
                scope: scope
            )
        )
    }

    public func deleteTrack(
        _ track: Track,
        scope: MetadataMutationToastScope = .track
    ) async throws -> MetadataMutationWorkflowResult {
        try await mutator.deleteTrack(track)
        return MetadataMutationWorkflowResult(
            successToast: deleteSuccessToast(
                noun: "Track",
                itemID: track.id,
                itemTitle: track.title,
                scope: scope
            )
        )
    }

    public func deleteAlbum(
        _ album: Album,
        scope: MetadataMutationToastScope = .album
    ) async throws -> MetadataMutationWorkflowResult {
        try await mutator.deleteAlbum(album)
        return MetadataMutationWorkflowResult(
            successToast: deleteSuccessToast(
                noun: "Album",
                itemID: album.id,
                itemTitle: album.title,
                scope: scope
            )
        )
    }

    public func editFailureToast(
        noun: String,
        itemID: String,
        error: Error,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Couldn't edit \(noun.lowercased())",
            message: error.localizedDescription,
            dedupeKey: dedupeKey(scope: scope, action: "edit", failed: true, itemID: itemID)
        )
    }

    public func deleteFailureToast(
        noun: String,
        itemID: String,
        error: Error,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Couldn't delete \(noun.lowercased())",
            message: error.localizedDescription,
            dedupeKey: dedupeKey(scope: scope, action: "delete", failed: true, itemID: itemID)
        )
    }

    private func editSuccessToast(
        noun: String,
        itemID: String,
        savedTitle: String,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .success,
            iconSystemName: Icon.editSuccess,
            title: "\(noun) updated",
            message: "\"\(savedTitle)\" was saved to Plex.",
            dedupeKey: dedupeKey(scope: scope, action: "edit", failed: false, itemID: itemID)
        )
    }

    private func deleteSuccessToast(
        noun: String,
        itemID: String,
        itemTitle: String,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .success,
            iconSystemName: Icon.deleteSuccess,
            title: "\(noun) deleted",
            message: "\"\(itemTitle)\" was removed from Plex.",
            dedupeKey: dedupeKey(scope: scope, action: "delete", failed: false, itemID: itemID)
        )
    }

    private func dedupeKey(
        scope: MetadataMutationToastScope,
        action: String,
        failed: Bool,
        itemID: String
    ) -> String {
        let failureSuffix = failed ? "-failed" : ""
        return "\(scope.dedupePrefix)-\(action)\(failureSuffix)-\(itemID)"
    }
}
