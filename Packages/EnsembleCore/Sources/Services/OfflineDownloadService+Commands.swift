import Foundation

public struct DownloadBatchState: Equatable {
    public let eligibleCount: Int
    public let enabledCount: Int

    public var isEnabled: Bool {
        eligibleCount > 0 && enabledCount == eligibleCount
    }
}

extension OfflineDownloadService {
    public func batchState(for albums: [Album]) -> DownloadBatchState {
        batchState(for: albums, isEnabled: isAlbumDownloadEnabled, availability: { $0.actionAvailability(for: .download) })
    }

    public func batchState(for artists: [Artist]) -> DownloadBatchState {
        batchState(for: artists, isEnabled: isArtistDownloadEnabled, availability: { $0.actionAvailability(for: .download) })
    }

    public func batchState(for playlists: [Playlist]) -> DownloadBatchState {
        batchState(for: playlists, isEnabled: isPlaylistDownloadEnabled, availability: { $0.actionAvailability(for: .download) })
    }

    public func toggleDownloads(for albums: [Album]) async {
        await toggleDownloads(
            for: albums,
            isEnabled: isAlbumDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: setAlbumDownloadEnabled
        )
    }

    public func toggleDownloads(for artists: [Artist]) async {
        await toggleDownloads(
            for: artists,
            isEnabled: isArtistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: setArtistDownloadEnabled
        )
    }

    public func toggleDownloads(for playlists: [Playlist]) async {
        await toggleDownloads(
            for: playlists,
            isEnabled: isPlaylistDownloadEnabled,
            availability: { $0.actionAvailability(for: .download) },
            setEnabled: setPlaylistDownloadEnabled
        )
    }

    private func batchState<Item>(
        for items: [Item],
        isEnabled: (Item) -> Bool,
        availability: (Item) -> MusicItemActionAvailability
    ) -> DownloadBatchState {
        let eligible = items.filter { isEnabled($0) || availability($0).isAvailable }
        return DownloadBatchState(eligibleCount: eligible.count, enabledCount: eligible.filter(isEnabled).count)
    }

    private func toggleDownloads<Item>(
        for items: [Item],
        isEnabled: (Item) -> Bool,
        availability: (Item) -> MusicItemActionAvailability,
        setEnabled: (Item, Bool) async -> Void
    ) async {
        let eligible = items.filter { isEnabled($0) || availability($0).isAvailable }
        let shouldEnable = !eligible.isEmpty && !eligible.allSatisfy(isEnabled)
        for item in eligible where isEnabled(item) != shouldEnable {
            await setEnabled(item, shouldEnable)
        }
    }
}
