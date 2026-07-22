import Foundation

/// Stable media reference used by drag/drop and other cross-surface workflows.
public struct MediaDropItemReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case track
        case album
        case playlist
    }

    public let kind: Kind
    public let id: String
    public let sourceKey: String?
    public let title: String
    public let isSmartPlaylist: Bool?

    public init(
        kind: Kind,
        id: String,
        sourceKey: String?,
        title: String,
        isSmartPlaylist: Bool? = nil
    ) {
        self.kind = kind
        self.id = id
        self.sourceKey = sourceKey
        self.title = title
        self.isSmartPlaylist = isSmartPlaylist
    }
}

/// Resolves stable media references against currently cached domain objects.
public struct MediaTrackResolver {
    private let tracks: [Track]
    private let albums: [Album]
    private let playlists: [Playlist]

    public init(tracks: [Track], albums: [Album], playlists: [Playlist]) {
        self.tracks = tracks
        self.albums = albums
        self.playlists = playlists
    }

    public func track(for reference: MediaDropItemReference) -> Track? {
        uniqueMatch(in: tracks, id: reference.id, sourceKey: reference.sourceKey) { track in
            (track.id, track.sourceCompositeKey)
        }
    }

    public func album(for reference: MediaDropItemReference) -> Album? {
        uniqueMatch(in: albums, id: reference.id, sourceKey: reference.sourceKey) { album in
            (album.id, album.sourceCompositeKey)
        }
    }

    public func playlist(for reference: MediaDropItemReference) -> Playlist? {
        uniqueMatch(in: playlists, id: reference.id, sourceKey: reference.sourceKey) { playlist in
            (playlist.id, playlist.sourceCompositeKey)
        }
    }

    public func playlist(id: String, sourceKey: String?) -> Playlist? {
        uniqueMatch(in: playlists, id: id, sourceKey: sourceKey) { playlist in
            (playlist.id, playlist.sourceCompositeKey)
        }
    }

    private func uniqueMatch<T>(
        in values: [T],
        id: String,
        sourceKey: String?,
        identity: (T) -> (id: String, sourceKey: String?)
    ) -> T? {
        let matches = values.filter { value in
            let candidate = identity(value)
            return Self.referenceMatches(
                id: id,
                sourceKey: sourceKey,
                candidateID: candidate.id,
                candidateSourceKey: candidate.sourceKey
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func referenceMatches(
        id: String,
        sourceKey: String?,
        candidateID: String,
        candidateSourceKey: String?
    ) -> Bool {
        guard candidateID == id else { return false }
        guard let sourceKey = normalizedSourceKey(sourceKey) else { return true }
        return normalizedSourceKey(candidateSourceKey) == sourceKey
    }

    public static func normalizedSourceKey(_ sourceKey: String?) -> String? {
        let trimmed = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public static func normalizedServerSourceKey(_ sourceKey: String?) -> String? {
        guard let normalized = normalizedSourceKey(sourceKey) else { return nil }
        return MediaSourceIdentity.serverSourceKey(from: normalized) ?? normalized
    }
}

/// Target playlist reference for copy/add drop operations.
public struct PlaylistDropTargetReference: Equatable, Sendable {
    public let id: String
    public let sourceKey: String?
    public let title: String
    public let isSmart: Bool
    public let isMerged: Bool

    public init(
        id: String,
        sourceKey: String?,
        title: String,
        isSmart: Bool,
        isMerged: Bool
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.title = title
        self.isSmart = isSmart
        self.isMerged = isMerged
    }
}

public struct PlaylistDropResolution: Equatable, Sendable {
    public let targetPlaylist: Playlist
    public let tracks: [Track]

    public init(targetPlaylist: Playlist, tracks: [Track]) {
        self.targetPlaylist = targetPlaylist
        self.tracks = tracks
    }
}

public enum PlaylistDropResolutionError: Error, Equatable, Sendable {
    case mergedTarget(title: String)
    case unresolvedTarget(title: String)
    case smartTarget(title: String)
    case unresolvedItem(title: String)
    case smartSource(title: String)
    case crossSource(itemTitle: String, playlistTitle: String)
    case alreadyContainsSelection(playlistTitle: String)
    case emptyDrop
}

/// Resolves media drag references into the concrete tracks that should be copied
/// into a destination playlist. UI owns provider loading and toasts; this type
/// owns mutation policy, source compatibility, expansion, and dedupe.
public struct PlaylistDropResolver {
    private let playlistActionService: PlaylistActionService

    public init(playlistActionService: PlaylistActionService = PlaylistActionService()) {
        self.playlistActionService = playlistActionService
    }

    /// Returns whether the destination can handle the referenced media using
    /// source information and any cached direct-track membership available.
    public func canAccept(
        references: [MediaDropItemReference],
        target: PlaylistDropTargetReference,
        existingTrackIDs: Set<String>?
    ) -> Bool {
        guard !target.isSmart,
              !target.isMerged,
              !references.isEmpty,
              MediaTrackResolver.normalizedServerSourceKey(target.sourceKey) != nil,
              references.allSatisfy({ reference in
                  reference.isSmartPlaylist != true && (
                      reference.kind == .track && MediaTrackResolver.normalizedServerSourceKey(reference.sourceKey) == nil ||
                      isSourceCompatible(reference.sourceKey, with: target.sourceKey)
                  )
              }) else {
            return false
        }

        guard let existingTrackIDs,
              references.allSatisfy({ $0.kind == .track }) else {
            return true
        }
        return references.contains { !existingTrackIDs.contains($0.id) }
    }

    /// Resolves a drop against the first compatible concrete destination.
    /// Merged UI rows pass their constituent playlists in display order.
    @MainActor
    public func resolve(
        references: [MediaDropItemReference],
        targets: [PlaylistDropTargetReference],
        tracks cachedTracks: [Track],
        albums cachedAlbums: [Album],
        playlists cachedPlaylists: [Playlist],
        loadAlbumTracks: (Album) async -> [Track],
        loadPlaylistTracks: (Playlist) async -> [Track]
    ) async throws -> PlaylistDropResolution {
        let compatibleTargets = targets.filter {
            canAccept(references: references, target: $0, existingTrackIDs: nil)
        }

        guard !compatibleTargets.isEmpty else {
            guard let target = targets.first else {
                throw PlaylistDropResolutionError.emptyDrop
            }
            return try await resolve(
                references: references,
                target: target,
                tracks: cachedTracks,
                albums: cachedAlbums,
                playlists: cachedPlaylists,
                loadAlbumTracks: loadAlbumTracks,
                loadPlaylistTracks: loadPlaylistTracks
            )
        }

        var firstError: Error?
        for target in compatibleTargets {
            do {
                return try await resolve(
                    references: references,
                    target: target,
                    tracks: cachedTracks,
                    albums: cachedAlbums,
                    playlists: cachedPlaylists,
                    loadAlbumTracks: loadAlbumTracks,
                    loadPlaylistTracks: loadPlaylistTracks
                )
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? PlaylistDropResolutionError.emptyDrop
    }

    @MainActor
    public func resolve(
        references: [MediaDropItemReference],
        target: PlaylistDropTargetReference,
        tracks cachedTracks: [Track],
        albums cachedAlbums: [Album],
        playlists cachedPlaylists: [Playlist],
        loadAlbumTracks: (Album) async -> [Track],
        loadPlaylistTracks: (Playlist) async -> [Track]
    ) async throws -> PlaylistDropResolution {
        guard !target.isMerged else {
            throw PlaylistDropResolutionError.mergedTarget(title: target.title)
        }

        let mediaResolver = MediaTrackResolver(
            tracks: cachedTracks,
            albums: cachedAlbums,
            playlists: cachedPlaylists
        )

        guard let targetPlaylist = mediaResolver.playlist(id: target.id, sourceKey: target.sourceKey) else {
            throw PlaylistDropResolutionError.unresolvedTarget(title: target.title)
        }

        guard !targetPlaylist.isSmart else {
            throw PlaylistDropResolutionError.smartTarget(title: targetPlaylist.title)
        }

        var resolvedTracks: [Track] = []
        for reference in references {
            let tracksForReference = try await resolveTracks(
                for: reference,
                targetPlaylist: targetPlaylist,
                mediaResolver: mediaResolver,
                loadAlbumTracks: loadAlbumTracks,
                loadPlaylistTracks: loadPlaylistTracks
            )
            resolvedTracks.append(contentsOf: tracksForReference)
        }

        let uniqueTracks = uniqueTracksBySourceAndID(resolvedTracks)
        guard !uniqueTracks.isEmpty else {
            throw PlaylistDropResolutionError.emptyDrop
        }

        let compatibleTracks = playlistActionService.tracks(
            uniqueTracks,
            compatibleWithServerSourceKey: targetPlaylist.sourceCompositeKey
        )
        guard compatibleTracks.count == uniqueTracks.count else {
            let rejected = uniqueTracks.first { candidate in
                !compatibleTracks.contains { tracksMatchByServerAndID($0, candidate) }
            }
            throw PlaylistDropResolutionError.crossSource(
                itemTitle: rejected?.title ?? "That item",
                playlistTitle: targetPlaylist.title
            )
        }

        let existingTracks = await loadPlaylistTracks(targetPlaylist)
        let newTracks = playlistActionService.tracks(compatibleTracks, excluding: existingTracks)
        guard !newTracks.isEmpty else {
            throw PlaylistDropResolutionError.alreadyContainsSelection(playlistTitle: targetPlaylist.title)
        }

        return PlaylistDropResolution(targetPlaylist: targetPlaylist, tracks: newTracks)
    }

    @MainActor
    private func resolveTracks(
        for reference: MediaDropItemReference,
        targetPlaylist: Playlist,
        mediaResolver: MediaTrackResolver,
        loadAlbumTracks: (Album) async -> [Track],
        loadPlaylistTracks: (Playlist) async -> [Track]
    ) async throws -> [Track] {
        switch reference.kind {
        case .track:
            return [
                mediaResolver.track(for: reference) ??
                Track(id: reference.id, key: "", title: reference.title, sourceCompositeKey: reference.sourceKey)
            ]

        case .album:
            guard let album = mediaResolver.album(for: reference) else {
                throw PlaylistDropResolutionError.unresolvedItem(title: reference.title)
            }
            guard isSourceCompatible(album.sourceCompositeKey, with: targetPlaylist.sourceCompositeKey) else {
                throw PlaylistDropResolutionError.crossSource(
                    itemTitle: album.title,
                    playlistTitle: targetPlaylist.title
                )
            }

            let tracks = await loadAlbumTracks(album)
            guard !tracks.isEmpty else {
                throw PlaylistDropResolutionError.unresolvedItem(title: album.title)
            }
            return tracks

        case .playlist:
            guard reference.isSmartPlaylist != true else {
                throw PlaylistDropResolutionError.smartSource(title: reference.title)
            }
            guard let playlist = mediaResolver.playlist(for: reference) else {
                throw PlaylistDropResolutionError.unresolvedItem(title: reference.title)
            }
            guard !playlist.isSmart else {
                throw PlaylistDropResolutionError.smartSource(title: playlist.title)
            }
            guard isSourceCompatible(playlist.sourceCompositeKey, with: targetPlaylist.sourceCompositeKey) else {
                throw PlaylistDropResolutionError.crossSource(
                    itemTitle: playlist.title,
                    playlistTitle: targetPlaylist.title
                )
            }

            let tracks = await loadPlaylistTracks(playlist)
            guard !tracks.isEmpty else {
                throw PlaylistDropResolutionError.unresolvedItem(title: playlist.title)
            }
            return tracks
        }
    }

    private func isSourceCompatible(_ itemSourceKey: String?, with targetSourceKey: String?) -> Bool {
        guard let targetServerKey = MediaTrackResolver.normalizedServerSourceKey(targetSourceKey) else {
            return true
        }
        return MediaTrackResolver.normalizedServerSourceKey(itemSourceKey) == targetServerKey
    }

    private func uniqueTracksBySourceAndID(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            let key = "\(MediaTrackResolver.normalizedSourceKey(track.sourceCompositeKey) ?? "")|\(track.id)"
            return seen.insert(key).inserted
        }
    }

    private func tracksMatchByServerAndID(_ lhs: Track, _ rhs: Track) -> Bool {
        guard lhs.id == rhs.id else { return false }
        let lhsServer = MediaTrackResolver.normalizedServerSourceKey(lhs.sourceCompositeKey)
        let rhsServer = MediaTrackResolver.normalizedServerSourceKey(rhs.sourceCompositeKey)
        return lhsServer == nil || rhsServer == nil || lhsServer == rhsServer
    }
}
