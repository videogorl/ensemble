import EnsembleDomain
import EnsemblePersistence
import EnsembleSiriShared
import Foundation

/// Resolves library-independent Ensemble links against the recipient's enabled local libraries.
@MainActor
public final class EnsemblePermalinkResolver {
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeys: () -> Set<String>
    private let mergingPreferences: () -> EnsembleMergingPreferences

    public init(
        accountManager: AccountManager,
        settingsManager: SettingsManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeys = {
            Set(accountManager.enabledSources().map(\.compositeKey))
        }
        self.mergingPreferences = { settingsManager.mergingPreferences }
    }

    init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        enabledSourceKeys: @escaping () -> Set<String>,
        mergingPreferences: @escaping () -> EnsembleMergingPreferences = { .default }
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeys = enabledSourceKeys
        self.mergingPreferences = mergingPreferences
    }

    /// Returns a typed scene-local navigation destination without starting playback.
    public func resolve(_ permalink: EnsemblePermalink) async throws -> NavigationCoordinator.Destination? {
        let sourceKeys = enabledSourceKeys()
        guard !sourceKeys.isEmpty else { return nil }

        switch permalink.kind {
        case .artist:
            return try await resolveArtist(permalink, sourceKeys: sourceKeys)
        case .album:
            return try await resolveAlbum(permalink, sourceKeys: sourceKeys)
        case .track:
            return try await resolveTrack(permalink, sourceKeys: sourceKeys)
        case .playlist:
            return try await resolvePlaylist(permalink, sourceKeys: playlistSourceKeys(from: sourceKeys))
        }
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
        .filter { normalized($0.title) == normalized(permalink.title) }

        guard let album = best(albums, sourceKey: \.sourceCompositeKey, score: { album in
            var score = 0
            if matches(permalink.artistName, album.artistName ?? album.albumArtist) { score += 8 }
            if permalink.year != nil, permalink.year == album.year { score += 4 }
            return score
        }) else {
            return nil
        }
        return .album(id: album.id, sourceKey: album.sourceCompositeKey)
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
        .filter { normalized($0.title) == normalized(permalink.title) }

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

    private func best<T>(
        _ candidates: [T],
        sourceKey: (T) -> String?,
        score: (T) -> Int
    ) -> T? where T: Identifiable, T.ID == String {
        let preferences = mergingPreferences()
        return candidates
            .map { (candidate: $0, score: score($0)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let lhsRank = preferences.rank(for: sourceKey($0.candidate))
                let rhsRank = preferences.rank(for: sourceKey($1.candidate))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return $0.candidate.id.localizedCaseInsensitiveCompare($1.candidate.id) == .orderedAscending
            }
            .first?
            .candidate
    }

    private func matches(_ expected: String?, _ candidate: String?) -> Bool {
        guard let expected, let candidate else { return false }
        return normalized(expected) == normalized(candidate)
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
