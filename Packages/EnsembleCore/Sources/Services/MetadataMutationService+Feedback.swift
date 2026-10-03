import Foundation

public enum MetadataMutationToastScope: String, Sendable {
    case track, album, artist
    case albumDetail = "album-detail"
}

extension MetadataMutationService {
    public func editTrack(
        _ track: Track,
        title: String,
        scope: MetadataMutationToastScope = .track
    ) async throws -> ToastPayload {
        try await editTrack(track, request: MetadataEditRequest(title: title))
        return editSuccessToast(noun: "Track", itemID: track.sourceScopedID, savedTitle: title, scope: scope)
    }

    public func editAlbum(
        _ album: Album,
        title: String,
        scope: MetadataMutationToastScope = .album
    ) async throws -> ToastPayload {
        try await editAlbum(album, request: MetadataEditRequest(title: title))
        return editSuccessToast(noun: "Album", itemID: album.sourceScopedID, savedTitle: title, scope: scope)
    }

    public func editArtist(
        _ artist: Artist,
        title: String,
        scope: MetadataMutationToastScope = .artist
    ) async throws -> ToastPayload {
        try await editArtist(artist, request: MetadataEditRequest(title: title))
        return editSuccessToast(noun: "Artist", itemID: artist.sourceScopedID, savedTitle: title, scope: scope)
    }

    public func editFailureToast(
        noun: String,
        itemID: String,
        error: Error,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: "exclamationmark.triangle.fill",
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
            iconSystemName: "exclamationmark.triangle.fill",
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
            iconSystemName: "checkmark.circle.fill",
            title: "\(noun) updated",
            message: "\"\(savedTitle)\" was saved to Plex.",
            dedupeKey: dedupeKey(scope: scope, action: "edit", failed: false, itemID: itemID)
        )
    }

    func deleteSuccessToast(
        noun: String,
        itemID: String,
        itemTitle: String,
        scope: MetadataMutationToastScope
    ) -> ToastPayload {
        ToastPayload(
            style: .success,
            iconSystemName: "trash.fill",
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
        return "\(scope.rawValue)-\(action)\(failureSuffix)-\(itemID)"
    }
}
