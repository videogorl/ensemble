import EnsembleDomain
import EnsemblePersistence
import EnsembleSiriShared
import Foundation

/// Resolves library-independent Ensemble links against visible libraries and Apple Music fallback.
@MainActor
public final class EnsemblePermalinkResolver {
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeys: () -> Set<String>
    private let mergingPreferences: () -> EnsembleMergingPreferences
    private let appleMusicCatalogSearch: AppleMusicCatalogSearchClient
    private let accountManager: AccountManager?
    private let visibilityStore: LibraryVisibilityStore?

    public init(
        accountManager: AccountManager,
        settingsManager: SettingsManager,
        visibilityStore: LibraryVisibilityStore,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore
        self.enabledSourceKeys = {
            let enabledSourceKeys = Set(accountManager.enabledSources().map(\.compositeKey))
            return enabledSourceKeys.subtracting(
                visibilityStore.effectiveHiddenSourceCompositeKeys(
                    enabledSourceCompositeKeys: enabledSourceKeys
                )
            )
        }
        self.mergingPreferences = { settingsManager.mergingPreferences }
        self.appleMusicCatalogSearch = .live
    }

    init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        enabledSourceKeys: @escaping () -> Set<String>,
        mergingPreferences: @escaping () -> EnsembleMergingPreferences = { .default },
        appleMusicCatalogSearch: AppleMusicCatalogSearchClient = .live
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.accountManager = nil
        self.visibilityStore = nil
        self.enabledSourceKeys = enabledSourceKeys
        self.mergingPreferences = mergingPreferences
        self.appleMusicCatalogSearch = appleMusicCatalogSearch
    }

    /// Returns a typed scene-local navigation destination without starting playback.
    public func resolve(
        _ permalink: EnsemblePermalink,
        onLibraryEnabled: ((String) -> Void)? = nil
    ) async throws -> NavigationCoordinator.Destination? {
        if let accountManager, accountManager.credentialLoadState == .loading {
            await accountManager.loadAccountsAsync()
        }
        try Task.checkCancellation()
        let sourceKeys = enabledSourceKeys()

        let localDestination = switch permalink.kind {
        case .artist:
            try await resolveArtist(permalink, sourceKeys: sourceKeys)
        case .album:
            try await resolveAlbum(permalink, sourceKeys: sourceKeys)
        case .track:
            try await resolveTrack(permalink, sourceKeys: sourceKeys)
        case .playlist:
            try await resolvePlaylist(permalink, sourceKeys: playlistSourceKeys(from: sourceKeys))
        }
        if let localDestination { return localDestination }

        if permalink.kind == .album {
            if let destination = try await resolveRemoteAlbum(permalink, sourceKeys: sourceKeys) {
                return destination
            }
            if let accountManager, let visibilityStore {
                let disabledKeys = Set(accountManager.disabledSources().map(\.compositeKey))
                let visibleDisabledKeys = disabledKeys.subtracting(
                    visibilityStore.effectiveHiddenSourceCompositeKeys(enabledSourceCompositeKeys: disabledKeys)
                )
                if let destination = try await resolveRemoteAlbum(
                    permalink,
                    sourceKeys: visibleDisabledKeys,
                    enableLibrary: true,
                    onLibraryEnabled: onLibraryEnabled
                ) {
                    return destination
                }
            }
        }

        guard sourceKeys.contains(MusicSourceIdentifier.appleMusic.compositeKey) else { return nil }
        let query = [permalink.artistName, permalink.title, permalink.albumTitle]
            .compactMap { $0 }
            .joined(separator: " ")
        let results = try await appleMusicCatalogSearch.search(query)
        if let destination = appleMusicDestination(for: permalink, results: results) {
            return destination
        }
        guard permalink.kind == .track, let albumTitle = permalink.albumTitle else { return nil }
        let albumResults = try await appleMusicCatalogSearch.search(
            [permalink.artistName, albumTitle].compactMap { $0 }.joined(separator: " ")
        )
        let albums = results.albums + albumResults.albums
        guard let album = albums.first(where: {
            normalized($0.title) == normalized(albumTitle)
                && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtist)
        }) else { return nil }
        let albumTracks = try await appleMusicCatalogSearch.albumTracks(album.id)
        return appleMusicDestination(
            for: permalink,
            results: AppleMusicCatalogSearchResults(
                tracks: results.tracks + albumResults.tracks + albumTracks,
                artists: results.artists + albumResults.artists,
                albums: albums,
                playlists: results.playlists
            )
        )
    }

    private func resolveArtist(
        _ permalink: EnsemblePermalink,
        sourceKeys: Set<String>
    ) async throws -> NavigationCoordinator.Destination? {
        let artists = try await libraryRepository.findArtistsByName(
            permalink.title,
            sourceCompositeKeys: sourceKeys
        )
        .map(Artist.init(from:))
        .filter { normalized($0.name) == normalized(permalink.title) }

        guard !artists.isEmpty else { return nil }
        let displayArtist = DisplayArtist.group(
            artists,
            preferences: mergingPreferences()
        ).sorted { $0.id < $1.id }[0]
        if displayArtist.isMerged {
            return .displayArtist(id: displayArtist.id)
        }
        let artist = displayArtist.primaryArtist
        return .artist(id: artist.id, sourceKey: artist.sourceCompositeKey)
    }

    private func resolveAlbum(
        _ permalink: EnsemblePermalink,
        sourceKeys: Set<String>
    ) async throws -> NavigationCoordinator.Destination? {
        let albums = try await libraryRepository.findAlbumsByTitle(
            permalink.title,
            sourceCompositeKeys: sourceKeys
        )
        .map(Album.init(from:))
        .filter {
            normalized($0.title) == normalized(permalink.title)
                && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtist)
        }

        return albumDestination(permalink, albums: albums)
    }

    private func albumDestination(
        _ permalink: EnsemblePermalink,
        albums: [Album]
    ) -> NavigationCoordinator.Destination? {

        guard let album = best(albums, sourceKey: \.sourceCompositeKey, score: { album in
            var score = 0
            if matches(permalink.artistName, album.artistName ?? album.albumArtist) { score += 8 }
            if permalink.year != nil, permalink.year == album.year { score += 4 }
            return score
        }) else {
            return nil
        }
        let displayAlbum = DisplayAlbum.group(albums, preferences: mergingPreferences())
            .first { $0.albums.contains(where: { $0.sourceScopedID == album.sourceScopedID }) }
            ?? .single(album)
        return .albumDetail(displayAlbum)
    }

    private func resolveRemoteAlbum(
        _ permalink: EnsemblePermalink,
        sourceKeys: Set<String>,
        enableLibrary: Bool = false,
        onLibraryEnabled: ((String) -> Void)? = nil
    ) async throws -> NavigationCoordinator.Destination? {
        guard let accountManager, let visibilityStore else { return nil }
        let orderedKeys = sourceKeys.sorted {
            let lhsRank = mergingPreferences().rank(for: $0)
            let rhsRank = mergingPreferences().rank(for: $1)
            return lhsRank == rhsRank ? $0 < $1 : lhsRank < rhsRank
        }
        for sourceKey in orderedKeys {
            try Task.checkCancellation()
            guard let identity = MediaSourceIdentity.parse(sourceKey), identity.sourceType == .plex,
                  let libraryId = identity.libraryId,
                  let client = accountManager.makeAPIClient(accountId: identity.accountId, serverId: identity.serverId)
            else { continue }
            let revision = accountManager.sourceConfigurationRevision(forSourceKey: sourceKey)
            let albums: [Album]
            do {
                albums = try await client.searchAlbums(query: permalink.title, sectionKey: libraryId)
                    .map { Album(from: $0, sourceKey: sourceKey) }
                    .filter {
                        normalized($0.title) == normalized(permalink.title)
                            && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtist)
                    }
            } catch {
                try Task.checkCancellation()
                EnsembleLogger.error("PERMALINK: Plex album lookup failed: \(error.localizedDescription)")
                continue
            }
            try Task.checkCancellation()
            guard accountManager.sourceConfigurationRevision(forSourceKey: sourceKey) == revision,
                  !visibilityStore.effectiveHiddenSourceCompositeKeys(enabledSourceCompositeKeys: [sourceKey]).contains(sourceKey),
                  let destination = albumDestination(permalink, albums: albums)
            else { continue }

            if enableLibrary {
                guard let library = accountManager.plexAccounts.first(where: { $0.id == identity.accountId })?
                    .servers.first(where: { $0.id == identity.serverId })?
                    .libraries.first(where: { $0.key == libraryId }),
                      accountManager.setLibraryEnabled(
                        accountId: identity.accountId,
                        serverId: identity.serverId,
                        libraryKey: libraryId,
                        isEnabled: true
                      )
                else { continue }
                onLibraryEnabled?(library.title)
            } else if !enabledSourceKeys().contains(sourceKey) {
                continue
            }
            EnsembleLogger.info("PERMALINK: resolved album directly from Plex enabledLibrary=\(enableLibrary)")
            return destination
        }
        return nil
    }

    private func resolveTrack(
        _ permalink: EnsemblePermalink,
        sourceKeys: Set<String>
    ) async throws -> NavigationCoordinator.Destination? {
        let tracks = try await libraryRepository.findTracksByTitle(
            permalink.title,
            sourceCompositeKeys: sourceKeys
        )
        .map(Track.init(from:))
        .filter {
            normalized($0.title) == normalized(permalink.title)
                && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtistName)
        }

        guard let track = best(tracks, sourceKey: \.sourceCompositeKey, score: { track in
            var score = 0
            if matches(permalink.artistName, track.artistName ?? track.albumArtistName) { score += 8 }
            if matches(permalink.albumTitle, track.albumName) { score += 6 }
            if let duration = permalink.duration, abs(duration - track.duration) <= 2 { score += 4 }
            if permalink.trackNumber != nil, permalink.trackNumber == track.trackNumber { score += 2 }
            if permalink.discNumber != nil, permalink.discNumber == track.discNumber { score += 1 }
            return score
        }) else {
            return nil
        }
        return .song(id: track.id, sourceKey: track.sourceCompositeKey)
    }

    private func resolvePlaylist(
        _ permalink: EnsemblePermalink,
        sourceKeys: Set<String>
    ) async throws -> NavigationCoordinator.Destination? {
        let playlists = try await playlistRepository.findPlaylistsByTitle(
            permalink.title,
            sourceCompositeKeys: sourceKeys
        )
        .map(Playlist.init(from:))
        .filter {
            normalized($0.title) == normalized(permalink.title)
                && (permalink.isSmartPlaylist == nil || $0.isSmart == permalink.isSmartPlaylist)
        }
        let orderedPlaylists = mergingPreferences().ordered(playlists, sourceKey: \.sourceCompositeKey)

        guard let first = orderedPlaylists.first else { return nil }
        if orderedPlaylists.count > 1 {
            return .mergedPlaylist(title: first.title, isSmart: first.isSmart)
        }
        return .playlist(id: first.id, sourceKey: first.sourceCompositeKey)
    }

    private func appleMusicDestination(
        for permalink: EnsemblePermalink,
        results: AppleMusicCatalogSearchResults
    ) -> NavigationCoordinator.Destination? {
        switch permalink.kind {
        case .artist:
            return results.artists
                .first { normalized($0.name) == normalized(permalink.title) }
                .map { .artistDetail($0) }
        case .album:
            return best(
                results.albums.filter {
                    normalized($0.title) == normalized(permalink.title)
                        && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtist)
                },
                sourceKey: \.sourceCompositeKey,
                score: { album in
                    var score = 0
                    if matches(permalink.artistName, album.artistName ?? album.albumArtist) { score += 8 }
                    if permalink.year != nil, permalink.year == album.year { score += 4 }
                    return score
                }
            ).map { .albumDetail(.single($0)) }
        case .track:
            guard let track = best(
                results.tracks.filter {
                    normalized($0.title) == normalized(permalink.title)
                        && hasCompatibleArtist(permalink.artistName, $0.artistName ?? $0.albumArtistName)
                },
                sourceKey: \.sourceCompositeKey,
                score: { track in
                    var score = 0
                    if matches(permalink.artistName, track.artistName ?? track.albumArtistName) { score += 8 }
                    if matches(permalink.albumTitle, track.albumName) { score += 6 }
                    if let duration = permalink.duration, abs(duration - track.duration) <= 2 { score += 4 }
                    if permalink.trackNumber != nil, permalink.trackNumber == track.trackNumber { score += 2 }
                    if permalink.discNumber != nil, permalink.discNumber == track.discNumber { score += 1 }
                    return score
                }
            ), let album = results.albums.first(where: {
                $0.id == track.albumRatingKey
                    || (normalized($0.title) == normalized(track.albumName ?? "")
                        && normalized($0.artistName ?? $0.albumArtist ?? "")
                            == normalized(track.artistName ?? track.albumArtistName ?? ""))
            }) else { return nil }
            return .albumDetail(.single(album), selectedTrackId: track.playbackIdentity)
        case .playlist:
            return results.playlists.first {
                normalized($0.title) == normalized(permalink.title)
                    && (permalink.isSmartPlaylist == nil || $0.isSmart == permalink.isSmartPlaylist)
            }.map { .playlistDetail($0) }
        }
    }

    private func best<T>(
        _ candidates: [T],
        sourceKey: (T) -> String?,
        score: (T) -> Int
    ) -> T? where T: Identifiable, T.ID == String {
        let preferences = mergingPreferences()
        return candidates
            .map { (candidate: $0, score: score($0)) }
            .sorted {
                let lhsRank = preferences.rank(for: sourceKey($0.candidate))
                let rhsRank = preferences.rank(for: sourceKey($1.candidate))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.id.localizedCaseInsensitiveCompare($1.candidate.id) == .orderedAscending
            }
            .first?
            .candidate
    }

    private func matches(_ expected: String?, _ candidate: String?) -> Bool {
        guard let expected, let candidate else { return false }
        return normalized(expected) == normalized(candidate)
    }

    private func hasCompatibleArtist(_ expected: String?, _ candidate: String?) -> Bool {
        expected == nil || matches(expected, candidate)
    }

    private func normalized(_ value: String) -> String {
        SiriPhraseNormalizer.basic(value)
    }

    private func playlistSourceKeys(from librarySourceKeys: Set<String>) -> Set<String> {
        librarySourceKeys.reduce(into: librarySourceKeys) { result, sourceKey in
            if let serverKey = MediaSourceIdentity.serverSourceKey(from: sourceKey) {
                result.insert(serverKey)
            }
        }
    }
}
