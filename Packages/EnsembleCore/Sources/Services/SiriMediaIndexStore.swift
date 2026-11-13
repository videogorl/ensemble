import EnsembleAPI
import EnsembleSiriShared
import EnsemblePersistence
import Foundation

public typealias SystemMediaEnabledSourceKeysProvider = @MainActor () -> Set<String>

enum SystemMediaSourceScope {
    static func enabledLibraryKeys(for sources: [MusicSourceIdentifier]) -> Set<String> {
        Set(sources.map(\.compositeKey))
    }

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
    nonisolated private static let spotlightAppliedFilename = "ensemble.spotlight.applied-index.json"

    /// Playlists are few and small, and Voice Add must be able to name any editable one. The repository returns them
    /// by title, so a tight cap would drop the playlists that sort last, whatever their age or play history.
    nonisolated static let playlistLimit = 2000

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider?
    private let hiddenMediaStore: HiddenMediaStore
    private let sourcePresentationProvider: (@MainActor (String) -> MusicSourcePresentation?)?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        sourcePresentationProvider: (@MainActor (String) -> MusicSourcePresentation?)? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeysProvider = enabledSourceKeysProvider
        self.hiddenMediaStore = hiddenMediaStore ?? .shared
        self.sourcePresentationProvider = sourcePresentationProvider
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
            Self.loadIndexFromDisk(filename: Self.filename)
        }.value
    }

    func loadSpotlightAppliedIndex() async -> SiriMediaIndex? {
        await Task.detached(priority: .utility) {
            Self.loadIndexFromDisk(filename: Self.spotlightAppliedFilename)
        }.value
    }

    /// Captures the last shared catalog as Spotlight's initial baseline before a
    /// catalog refresh can replace it. An empty baseline also records the first
    /// catalog publication when no prior Siri index exists.
    func seedSpotlightAppliedIndexIfNeeded(from index: SiriMediaIndex?) async throws -> Bool {
        try RefreshExecution.checkCancellation()
        guard await loadSpotlightAppliedIndex() == nil else { return false }
        try RefreshExecution.checkCancellation()
        try await save(index ?? SiriMediaIndex(items: []), filename: Self.spotlightAppliedFilename)
        return true
    }

    func saveSpotlightAppliedIndex(_ index: SiriMediaIndex) async throws {
        try await save(index, filename: Self.spotlightAppliedFilename)
    }

    nonisolated private static func loadIndexFromDisk(filename: String) -> SiriMediaIndex? {
        guard let url = indexURL(filename: filename), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiriMediaIndex.self, from: data)
    }

    /// Rebuilds and writes a compact searchable index.
    @discardableResult
    public func rebuildIndex(previousIndex: SiriMediaIndex? = nil) async -> SiriMediaIndex? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try RefreshExecution.checkCancellation()
            let existingIndex: SiriMediaIndex?
            if let providedIndex = previousIndex {
                existingIndex = providedIndex
            } else {
                existingIndex = await loadIndexUnbounded()
            }
            try await seedSpotlightAppliedIndexIfNeeded(from: existingIndex)
            let enabledLibrarySourceKeys = enabledSourceKeysProvider?()
            let playlistSourceKeys = enabledLibrarySourceKeys.map {
                SystemMediaSourceScope.playlistSourceKeys(forEnabledLibraryKeys: $0)
            }
            let hidden = hiddenMediaStore.snapshot
            let artists = Array(try await libraryRepository.fetchSiriArtistRows()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .filter { !Self.isHidden($0, in: hidden) }
                .prefix(1500))
            try RefreshExecution.checkCancellation()
            let albums = Array(try await libraryRepository.fetchSiriAlbumRows()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .filter { !Self.isHidden($0, in: hidden) }
                .prefix(1500))
            try RefreshExecution.checkCancellation()
            let tracks = Array(try await libraryRepository.fetchSiriEligibleTracks()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .filter { !hiddenMediaStore.snapshot.isHidden(Track(from: $0)) }
                .prefix(1000))
            try RefreshExecution.checkCancellation()
            let playlists = Array(try await playlistRepository.fetchPlaylists()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: playlistSourceKeys) }
                .filter { !hiddenMediaStore.snapshot.isHidden(Playlist(from: $0)) }
                .prefix(Self.playlistLimit))
            try RefreshExecution.checkCancellation()

            var items: [SiriMediaIndexItem] = []
            items.reserveCapacity(artists.count + albums.count + tracks.count + playlists.count)

            items += artists.map(Self.indexItem(for:))
            items += albums.map(Self.indexItem(for:))
            items += tracks.map(Self.indexItem(for:))

            let sourceNames = Self.playlistSourceNames(for: playlists, presentation: { sourcePresentationProvider?($0) })
            items += playlists.map { playlist in
                Self.indexItem(for: playlist, sourceName: playlist.sourceCompositeKey.flatMap { sourceNames["\(playlist.ratingKey)||\($0)"] })
            }

            try RefreshExecution.checkCancellation()
            let index = SiriMediaIndex(items: items)
            guard Self.hasMaterialChanges(from: existingIndex, to: index) else {
                try RefreshExecution.checkCancellation()
                EnsembleLogger.debug(
                    "[Performance] siriIndexRebuild artists=\(artists.count) albums=\(albums.count) tracks=\(tracks.count) playlists=\(playlists.count) changed=false saved=false elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
                )
                return existingIndex
            }
            try RefreshExecution.checkCancellation()
            try await save(index, filename: Self.filename)
            EnsembleLogger.debug(
                "[Performance] siriIndexRebuild artists=\(artists.count) albums=\(albums.count) tracks=\(tracks.count) playlists=\(playlists.count) changed=true saved=true elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
            )
            return index
        } catch {
            EnsembleLogger.debug("Failed to rebuild Siri media index: \(error)")
            return nil
        }
    }

    private func save(_ index: SiriMediaIndex, filename: String) async throws {
        try RefreshExecution.checkCancellation()
        try await Task.detached(priority: .utility) {
            try Self.saveToDisk(index, filename: filename)
        }.value
    }

    nonisolated private static func saveToDisk(_ index: SiriMediaIndex, filename: String) throws {
        guard let indexURL = indexURL(filename: filename) else {
            throw NSError(
                domain: "SiriMediaIndexStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container URL unavailable"]
            )
        }

        let directory = indexURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    /// Friendly server names per playlist (`ratingKey||sourceCompositeKey`). Where two sources would share a name for one title, the
    /// account is added so the rows still read differently.
    static func playlistSourceNames(
        for playlists: [CDPlaylist],
        presentation: (String) -> MusicSourcePresentation?
    ) -> [String: String] {
        var presentations: [String: MusicSourcePresentation] = [:]
        var sourcesByLabel: [String: Set<String>] = [:]
        for playlist in playlists {
            guard let key = playlist.sourceCompositeKey, let info = presentation(key) else { continue }
            presentations[key] = info
            sourcesByLabel["\(PlexPlaylistMergeRules.normalizedTitle(playlist.title))|\(info.serverName)", default: []].insert(key)
        }
        var names: [String: String] = [:]
        for playlist in playlists {
            guard let key = playlist.sourceCompositeKey, let info = presentations[key] else { continue }
            let shared = sourcesByLabel["\(PlexPlaylistMergeRules.normalizedTitle(playlist.title))|\(info.serverName)"]?.count ?? 0 > 1
            names["\(playlist.ratingKey)||\(key)"] = shared ? "\(info.serverName) · \(info.accountName)" : info.serverName
        }
        return names
    }

    nonisolated static func hasMaterialChanges(
        from previousIndex: SiriMediaIndex?,
        to currentIndex: SiriMediaIndex
    ) -> Bool {
        previousIndex?.schemaVersion != currentIndex.schemaVersion
            || previousIndex?.items != currentIndex.items
    }

    nonisolated private static func indexURL(filename: String) -> URL? {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(filename)
        }

        EnsembleLogger.debug("App Group unavailable for Siri index; using caches fallback")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(filename)
    }

    /// The same decisions as `HiddenMediaSnapshot.isHidden(Artist)` and `isHidden(Album)`, from the narrow rows.
    nonisolated static func isHidden(_ artist: SiriArtistRow, in snapshot: HiddenMediaSnapshot) -> Bool {
        guard let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty else { return false }
        return snapshot.contains(.init(kind: .artist, itemID: artist.ratingKey, sourceCompositeKey: sourceKey))
    }

    nonisolated static func isHidden(_ album: SiriAlbumRow, in snapshot: HiddenMediaSnapshot) -> Bool {
        guard let sourceKey = album.sourceCompositeKey else { return false }
        if snapshot.contains(.init(kind: .album, itemID: album.ratingKey, sourceCompositeKey: sourceKey)) { return true }
        guard let artistID = album.artistRatingKey else { return false }
        return snapshot.contains(.init(kind: .artist, itemID: artistID, sourceCompositeKey: sourceKey))
    }

    nonisolated static func indexItem(for artist: CDArtist) -> SiriMediaIndexItem {
        indexItem(for: SiriArtistRow(from: artist))
    }

    nonisolated static func indexItem(for album: CDAlbum) -> SiriMediaIndexItem {
        indexItem(for: SiriAlbumRow(from: album))
    }

    nonisolated static func indexItem(for artist: SiriArtistRow) -> SiriMediaIndexItem {
        let artwork = artistArtworkDescriptor(for: artist)
        return SiriMediaIndexItem(
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
    }

    /// A playlist's artwork is indexed by its signature-free identity: a pre-signed URL changes on every read,
    /// which would otherwise rewrite the index on every sync. Artwork is read back by cache key, not by this path.
    nonisolated static func indexItem(for playlist: CDPlaylist, sourceName: String?) -> SiriMediaIndexItem {
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
            artworkPath: ArtworkPathIdentity.of(playlist.compositePath),
            artworkCacheKey: playlist.ratingKey,
            artworkCacheType: .playlist,
            sourceName: sourceName
        )
    }

    nonisolated static func indexItem(for album: SiriAlbumRow) -> SiriMediaIndexItem {
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
            artworkCacheType: .album,
            year: album.year > 0 ? Int(album.year) : nil,
            albumArtist: album.albumArtist ?? album.artistName ?? album.relatedArtistName
        )
    }

    nonisolated static func indexItem(for track: CDTrack) -> SiriMediaIndexItem {
        let artwork = trackArtworkDescriptor(for: track)
        return SiriMediaIndexItem(
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
            artworkCacheType: artwork.cacheType,
            albumArtist: track.album?.artist?.name
        )
    }

    private nonisolated struct ArtworkDescriptor {
        let path: String?
        let cacheKey: String?
        let cacheType: SiriMediaArtworkCacheType?
    }

    private nonisolated static func artistArtworkDescriptor(for artist: SiriArtistRow) -> ArtworkDescriptor {
        if let thumbPath = artist.thumbPath, !thumbPath.isEmpty {
            return ArtworkDescriptor(path: thumbPath, cacheKey: artist.ratingKey, cacheType: .artist)
        }

        return ArtworkDescriptor(path: nil, cacheKey: nil, cacheType: nil)
    }

    private nonisolated static func trackArtworkDescriptor(for track: CDTrack) -> ArtworkDescriptor {
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
    private nonisolated static func ratingKey(fromArtworkPath path: String?) -> String? {
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
