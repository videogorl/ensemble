import Foundation

@MainActor
public protocol DownloadMutationWorkflowMutating: AnyObject {
    func setFavoritesDownloadEnabled(isEnabled: Bool) async
    func setLibraryDownloadEnabled(sourceCompositeKey: String, displayName: String, isEnabled: Bool) async
    func setAlbumDownloadEnabled(_ album: Album, isEnabled: Bool) async
    func setArtistDownloadEnabled(_ artist: Artist, isEnabled: Bool) async
    func setPlaylistDownloadEnabled(_ playlist: Playlist, isEnabled: Bool) async
    func removeTarget(key: String) async
    func removeAllDownloads() async
    func pauseQueue() async
    func resumeQueue() async
}

extension OfflineDownloadService: DownloadMutationWorkflowMutating {}

public struct DownloadMutationWorkflowResult: Equatable {
    public let completed: Bool

    public init(completed: Bool = true) {
        self.completed = completed
    }
}

/// Shared policy boundary for user-initiated download mutations.
///
/// OfflineDownloadService remains the queue/target owner. This workflow keeps view models
/// and menus from choosing their own action or toast policy for target toggles and queue controls.
@MainActor
public final class DownloadMutationWorkflow {
    private let mutator: DownloadMutationWorkflowMutating

    public init(mutator: DownloadMutationWorkflowMutating) {
        self.mutator = mutator
    }

    @discardableResult
    public func setFavoritesDownloadEnabled(isEnabled: Bool) async -> DownloadMutationWorkflowResult {
        await mutator.setFavoritesDownloadEnabled(isEnabled: isEnabled)
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func setLibraryDownloadEnabled(
        sourceCompositeKey: String,
        displayName: String,
        isEnabled: Bool
    ) async -> DownloadMutationWorkflowResult {
        await mutator.setLibraryDownloadEnabled(
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            isEnabled: isEnabled
        )
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func setAlbumDownloadEnabled(_ album: Album, isEnabled: Bool) async -> DownloadMutationWorkflowResult {
        await mutator.setAlbumDownloadEnabled(album, isEnabled: isEnabled)
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func setArtistDownloadEnabled(_ artist: Artist, isEnabled: Bool) async -> DownloadMutationWorkflowResult {
        await mutator.setArtistDownloadEnabled(artist, isEnabled: isEnabled)
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func setPlaylistDownloadEnabled(_ playlist: Playlist, isEnabled: Bool) async -> DownloadMutationWorkflowResult {
        await mutator.setPlaylistDownloadEnabled(playlist, isEnabled: isEnabled)
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func removeTarget(key: String) async -> DownloadMutationWorkflowResult {
        await mutator.removeTarget(key: key)
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func removeAllDownloads() async -> DownloadMutationWorkflowResult {
        await mutator.removeAllDownloads()
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func pauseQueue() async -> DownloadMutationWorkflowResult {
        await mutator.pauseQueue()
        return DownloadMutationWorkflowResult()
    }

    @discardableResult
    public func resumeQueue() async -> DownloadMutationWorkflowResult {
        await mutator.resumeQueue()
        return DownloadMutationWorkflowResult()
    }
}
