import EnsemblePersistence
import Foundation

/// Notification contract for requesting Siri media index rebuilds.
public enum SiriMediaIndexNotifications {
    public static let rebuildRequested = Notification.Name(
        "com.videogorl.ensemble.siriMediaIndex.rebuildRequested"
    )
    public static let reasonKey = "reason"

    public static func postRebuildRequest(
        reason: String,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(
            name: rebuildRequested,
            object: nil,
            userInfo: [reasonKey: reason]
        )
    }
}

/// Persists and refreshes the Siri media index in the shared App Group container.
@MainActor
public final class SiriMediaIndexStore {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let filename = "siri-media-index.json"

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let notificationCenter: NotificationCenter
    private var observerToken: NSObjectProtocol?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        notificationCenter: NotificationCenter = .default
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.notificationCenter = notificationCenter

        observerToken = notificationCenter.addObserver(
            forName: SiriMediaIndexNotifications.rebuildRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.rebuildIndex()
            }
        }
    }

    deinit {
        if let observerToken {
            notificationCenter.removeObserver(observerToken)
        }
    }

    /// Loads a fresh-enough Siri index from disk.
    public func loadIndex(maxAge: TimeInterval = 3600) -> SiriMediaIndex? {
        guard let index = loadIndexUnbounded() else { return nil }
        guard Date().timeIntervalSince(index.generatedAt) <= maxAge else { return nil }
        return index
    }

    /// Loads the latest Siri index from disk without staleness checks.
    public func loadIndexUnbounded() -> SiriMediaIndex? {
        guard let url = indexURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiriMediaIndex.self, from: data)
    }

    /// Rebuilds and writes a compact searchable index.
    @discardableResult
    public func rebuildIndex() async -> SiriMediaIndex? {
        do {
            let artists = Array(try await libraryRepository.fetchArtists().prefix(1500))
            let albums = Array(try await libraryRepository.fetchAlbums().prefix(1500))
            let tracks = Array(try await libraryRepository.fetchSiriEligibleTracks().prefix(1000))
            let playlists = Array(try await playlistRepository.fetchPlaylists().prefix(500))

            var items: [SiriMediaIndexItem] = []
            items.reserveCapacity(artists.count + albums.count + tracks.count + playlists.count)

            for artist in artists {
                items.append(
                    SiriMediaIndexItem(
                        kind: .artist,
                        id: artist.ratingKey,
                        displayName: artist.name,
                        sourceCompositeKey: artist.sourceCompositeKey,
                        secondaryText: nil,
                        lastPlayed: nil,
                        playCount: nil,
                        trackCount: nil
                    )
                )
            }

            for album in albums {
                items.append(
                    SiriMediaIndexItem(
                        kind: .album,
                        id: album.ratingKey,
                        displayName: album.title,
                        sourceCompositeKey: album.sourceCompositeKey,
                        secondaryText: album.artistName,
                        lastPlayed: nil,
                        playCount: nil,
                        trackCount: Int(album.trackCount)
                    )
                )
            }

            for track in tracks {
                items.append(
                    SiriMediaIndexItem(
                        kind: .track,
                        id: track.ratingKey,
                        displayName: track.title,
                        sourceCompositeKey: track.sourceCompositeKey,
                        secondaryText: track.artistName ?? track.albumName,
                        lastPlayed: track.lastPlayed,
                        playCount: Int(track.playCount),
                        trackCount: nil
                    )
                )
            }

            for playlist in playlists {
                items.append(
                    SiriMediaIndexItem(
                        kind: .playlist,
                        id: playlist.ratingKey,
                        displayName: playlist.title,
                        sourceCompositeKey: playlist.sourceCompositeKey,
                        secondaryText: nil,
                        lastPlayed: playlist.lastPlayed,
                        playCount: nil,
                        trackCount: Int(playlist.trackCount)
                    )
                )
            }

            let index = SiriMediaIndex(items: items)
            try save(index)
            return index
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Failed to rebuild Siri media index: \(error)")
            #endif
            return nil
        }
    }

    private func save(_ index: SiriMediaIndex) throws {
        guard let indexURL = indexURL() else {
            throw NSError(
                domain: "SiriMediaIndexStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container URL unavailable"]
            )
        }

        let directory = indexURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(index)
        let tempURL = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: tempURL, options: .atomic)

        _ = try? FileManager.default.replaceItemAt(indexURL, withItemAt: tempURL)
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.moveItem(at: tempURL, to: indexURL)
        }
    }

    private func indexURL() -> URL? {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(Self.filename)
        }

        #if DEBUG
        EnsembleLogger.debug("App Group unavailable for Siri index; using caches fallback")
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.filename)
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
