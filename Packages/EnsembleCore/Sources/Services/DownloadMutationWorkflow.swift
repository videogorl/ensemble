import Foundation

@MainActor
public protocol DownloadMutationWorkflowMutating: AnyObject {
    func isAlbumDownloadEnabled(_ album: Album) -> Bool
    func isArtistDownloadEnabled(_ artist: Artist) -> Bool
    func isPlaylistDownloadEnabled(_ playlist: Playlist) -> Bool
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

public struct DownloadMutationBatchState: Equatable {
    public let eligibleCount: Int
    public let enabledCount: Int

    public var isEnabled: Bool {
        eligibleCount > 0 && enabledCount == eligibleCount
    }

    public init(eligibleCount: Int, enabledCount: Int) {
        self.eligibleCount = eligibleCount
        self.enabledCount = enabledCount
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

    public func batchState(for albums: [Album]) -> DownloadMutationBatchState {
        batchState(
            for: albums,
            isEnabled: mutator.isAlbumDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) }
        )
    }

    public func batchState(for artists: [Artist]) -> DownloadMutationBatchState {
        batchState(
            for: artists,
            isEnabled: mutator.isArtistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) }
        )
    }

    public func batchState(for playlists: [Playlist]) -> DownloadMutationBatchState {
        batchState(
            for: playlists,
            isEnabled: mutator.isPlaylistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) }
        )
    }

    @discardableResult
    public func toggleDownloads(for albums: [Album]) async -> DownloadMutationWorkflowResult {
        await toggleDownloads(
            for: albums,
            isEnabled: mutator.isAlbumDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: mutator.setAlbumDownloadEnabled
        )
    }

    @discardableResult
    public func toggleDownloads(for artists: [Artist]) async -> DownloadMutationWorkflowResult {
        await toggleDownloads(
            for: artists,
            isEnabled: mutator.isArtistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: mutator.setArtistDownloadEnabled
        )
    }

    @discardableResult
    public func toggleDownloads(for playlists: [Playlist]) async -> DownloadMutationWorkflowResult {
        await toggleDownloads(
            for: playlists,
            isEnabled: mutator.isPlaylistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: mutator.setPlaylistDownloadEnabled
        )
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

    private func batchState<Item>(
        for items: [Item],
        isEnabled: (Item) -> Bool,
        availability: (Item) -> MusicItemActionAvailability
    ) -> DownloadMutationBatchState {
        let eligible = items.filter { isEnabled($0) || availability($0).isAvailable }
        return DownloadMutationBatchState(
            eligibleCount: eligible.count,
            enabledCount: eligible.filter(isEnabled).count
        )
    }

    private func toggleDownloads<Item>(
        for items: [Item],
        isEnabled: (Item) -> Bool,
        availability: (Item) -> MusicItemActionAvailability,
        setEnabled: (Item, Bool) async -> Void
    ) async -> DownloadMutationWorkflowResult {
        let eligible = items.filter { isEnabled($0) || availability($0).isAvailable }
        let shouldEnable = !eligible.isEmpty && !eligible.allSatisfy(isEnabled)
        for item in eligible where isEnabled(item) != shouldEnable {
            await setEnabled(item, shouldEnable)
        }
        return DownloadMutationWorkflowResult()
    }
}
