import EnsembleSiriShared
import EnsemblePersistence
import Foundation

public typealias SystemMediaEnabledSourceKeysProvider = @MainActor () -> Set<String>

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

enum SystemMediaSourceScope {
    static func allows(_ sourceCompositeKey: String?, within allowedSourceKeys: Set<String>?) -> Bool {
        guard let allowedSourceKeys else { return true }
        guard let sourceCompositeKey else { return false }
        return allowedSourceKeys.contains(sourceCompositeKey)
    }

    static func playlistSourceKeys(forEnabledLibraryKeys enabledLibrarySourceKeys: Set<String>) -> Set<String> {
        var sourceKeys = enabledLibrarySourceKeys

        for librarySourceKey in enabledLibrarySourceKeys {
            guard let serverSourceKey = MediaSourceIdentity.serverSourceKey(from: librarySourceKey) else {
                continue
            }
            sourceKeys.insert(serverSourceKey)
        }

        return sourceKeys
    }
}

/// Persists and refreshes the Siri media index in the shared App Group container.
@MainActor
public final class SiriMediaIndexStore {
    nonisolated private static let appGroupIdentifier = SiriSharedConstants.appGroupIdentifier
    nonisolated private static let filename = SiriSharedConstants.indexFilename

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeysProvider = enabledSourceKeysProvider
    }

    /// Loads a fresh-enough Siri index from disk.
    public func loadIndex(maxAge: TimeInterval = 3600) async -> SiriMediaIndex? {
        guard let index = await loadIndexUnbounded() else { return nil }
        guard Date().timeIntervalSince(index.generatedAt) <= maxAge else { return nil }
        return index
    }

    /// Loads the latest Siri index from disk without staleness checks.
    public func loadIndexUnbounded() async -> SiriMediaIndex? {
        await Task.detached(priority: .utility) {
            Self.loadIndexUnboundedFromDisk()
        }.value
    }

    nonisolated private static func loadIndexUnboundedFromDisk() -> SiriMediaIndex? {
        guard let url = indexURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiriMediaIndex.self, from: data)
    }

    /// Rebuilds and writes a compact searchable index.
    @discardableResult
    public func rebuildIndex() async -> SiriMediaIndex? {
        do {
            let enabledLibrarySourceKeys = enabledSourceKeysProvider?()
            let playlistSourceKeys = enabledLibrarySourceKeys.map {
                SystemMediaSourceScope.playlistSourceKeys(forEnabledLibraryKeys: $0)
            }
            let artists = Array(try await libraryRepository.fetchArtists()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .prefix(1500))
            let albums = Array(try await libraryRepository.fetchAlbums()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .prefix(1500))
            let tracks = Array(try await libraryRepository.fetchSiriEligibleTracks()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .prefix(1000))
            let playlists = Array(try await playlistRepository.fetchPlaylists()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: playlistSourceKeys) }
                .prefix(500))

            var items: [SiriMediaIndexItem] = []
            items.reserveCapacity(artists.count + albums.count + tracks.count + playlists.count)

            for artist in artists {
                let artwork = Self.artistArtworkDescriptor(for: artist)
                items.append(
                    SiriMediaIndexItem(
                        kind: .artist,
                        id: artist.ratingKey,
                        displayName: artist.name,
                        sourceCompositeKey: artist.sourceCompositeKey,
                        secondaryText: nil,
                        lastPlayed: nil,
                        playCount: nil,
                        trackCount: nil,
                        artistName: artist.name,
                        artworkPath: artwork.path,
                        artworkCacheKey: artwork.cacheKey,
                        artworkCacheType: artwork.cacheType
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
                        trackCount: Int(album.trackCount),
                        albumTitle: album.title,
                        artistName: album.artistName ?? album.albumArtist,
                        genre: album.genreNames,
                        artworkPath: album.thumbPath,
                        artworkCacheKey: album.ratingKey,
                        artworkCacheType: .album
                    )
                )
            }

            for track in tracks {
                let artwork = Self.trackArtworkDescriptor(for: track)
                items.append(
                    SiriMediaIndexItem(
                        kind: .track,
                        id: track.ratingKey,
                        displayName: track.title,
                        sourceCompositeKey: track.sourceCompositeKey,
                        secondaryText: track.artistName ?? track.albumName,
                        lastPlayed: track.lastPlayed,
                        playCount: Int(track.playCount),
                        trackCount: nil,
                        albumTitle: track.albumName,
                        artistName: track.artistName,
                        genre: track.genreNames,
                        duration: track.durationSeconds,
                        trackNumber: Int(track.trackNumber),
                        discNumber: Int(track.discNumber),
                        artworkPath: artwork.path,
                        artworkCacheKey: artwork.cacheKey,
                        artworkCacheType: artwork.cacheType
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
                        trackCount: Int(playlist.trackCount),
                        duration: TimeInterval(playlist.duration) / 1000.0,
                        isSmartPlaylist: playlist.isSmart,
                        artworkPath: playlist.compositePath,
                        artworkCacheKey: playlist.ratingKey,
                        artworkCacheType: .playlist
                    )
                )
            }

            let index = SiriMediaIndex(items: items)
            try await save(index)
            return index
        } catch {
            EnsembleLogger.debug("Failed to rebuild Siri media index: \(error)")
            return nil
        }
    }

    private func save(_ index: SiriMediaIndex) async throws {
        try await Task.detached(priority: .utility) {
            try Self.saveToDisk(index)
        }.value
    }

    nonisolated private static func saveToDisk(_ index: SiriMediaIndex) throws {
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

    nonisolated private static func indexURL() -> URL? {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(Self.filename)
        }

        EnsembleLogger.debug("App Group unavailable for Siri index; using caches fallback")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.filename)
    }

    private struct ArtworkDescriptor {
        let path: String?
        let cacheKey: String?
        let cacheType: SiriMediaArtworkCacheType?
    }

    private static func artistArtworkDescriptor(for artist: CDArtist) -> ArtworkDescriptor {
        if let thumbPath = artist.thumbPath, !thumbPath.isEmpty {
            return ArtworkDescriptor(path: thumbPath, cacheKey: artist.ratingKey, cacheType: .artist)
        }

        return ArtworkDescriptor(path: nil, cacheKey: nil, cacheType: nil)
    }

    private static func trackArtworkDescriptor(for track: CDTrack) -> ArtworkDescriptor {
        let path = track.thumbPath ?? track.album?.thumbPath
        let cacheKey = track.album?.ratingKey
            ?? ratingKey(fromArtworkPath: track.thumbPath)
            ?? ratingKey(fromArtworkPath: track.album?.thumbPath)

        return ArtworkDescriptor(
            path: path,
            cacheKey: cacheKey,
            cacheType: cacheKey == nil ? nil : .album
        )
    }

    /// Extract ratingKey from artwork paths like `/library/metadata/{ratingKey}/thumb/...`.
    private static func ratingKey(fromArtworkPath path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "library",
              components[1] == "metadata" else {
            return nil
        }
        return String(components[2])
    }
}
