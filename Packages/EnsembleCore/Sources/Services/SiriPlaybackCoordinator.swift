import EnsemblePersistence
import Foundation

/// Resolved playback request used by Siri execution entry points.
public struct SiriPlaybackRequest: Sendable, Equatable {
    public let entityID: String
    public let sourceCompositeKey: String?
    public let displayName: String?

    public init(entityID: String, sourceCompositeKey: String? = nil, displayName: String? = nil) {
        self.entityID = entityID
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
    }
}

/// User-facing error mapping for Siri in-app playback execution.
public enum SiriPlaybackCoordinatorError: Error, LocalizedError, Equatable {
    case unsupportedPayloadVersion(Int)
    case noEnabledSources
    case mediaNotFound(SiriMediaKind)
    case noPlayableTracks(SiriMediaKind)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPayloadVersion(let version):
            return "Unsupported Siri request version (\(version))."
        case .noEnabledSources:
            return "No enabled music sources are available."
        case .mediaNotFound(let kind):
            return "\(kind.rawValue.capitalized) could not be found."
        case .noPlayableTracks(let kind):
            return "No playable tracks were found for this \(kind.rawValue)."
        }
    }
}

/// Executes Siri media play requests inside the main app process.
@MainActor
public final class SiriPlaybackCoordinator {
    private let accountManager: AccountManager
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let playbackService: PlaybackServiceProtocol

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        playbackService: PlaybackServiceProtocol
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.playbackService = playbackService
    }

    /// Decodes and executes a Siri payload routed through NSUserActivity.
    @discardableResult
    public func handle(userActivity: NSUserActivity) async -> Bool {
        guard userActivity.activityType == SiriPlaybackActivityCodec.activityType,
              let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) else {
            return false
        }

        do {
            try await execute(payload: payload)
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Siri playback handling failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Executes a versioned Siri payload by media kind.
    public func execute(payload: SiriPlaybackRequestPayload) async throws {
        guard payload.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion else {
            throw SiriPlaybackCoordinatorError.unsupportedPayloadVersion(payload.schemaVersion)
        }

        let request = SiriPlaybackRequest(
            entityID: payload.entityID,
            sourceCompositeKey: payload.sourceCompositeKey,
            displayName: payload.displayName
        )

        switch payload.kind {
        case .track:
            try await executePlayTrack(request: request)
        case .album:
            try await executePlayAlbum(request: request)
        case .artist:
            try await executePlayArtist(request: request)
        case .playlist:
            try await executePlayPlaylist(request: request)
        }
    }

    /// Resolves and plays a single track.
    public func executePlayTrack(request: SiriPlaybackRequest) async throws {
        let enabledSourceKeys = enabledLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else {
            throw SiriPlaybackCoordinatorError.noEnabledSources
        }

        guard let resolved = try await resolveTrack(
            request: request,
            enabledSourceKeys: enabledSourceKeys
        ) else {
            throw SiriPlaybackCoordinatorError.mediaNotFound(.track)
        }

        let track = Track(from: resolved)
        guard isPlayable(track: track, enabledSourceKeys: enabledSourceKeys) else {
            throw SiriPlaybackCoordinatorError.noPlayableTracks(.track)
        }

        await playbackService.play(track: track)
    }

    /// Resolves an album and queues all playable tracks from track 1.
    public func executePlayAlbum(request: SiriPlaybackRequest) async throws {
        let enabledSourceKeys = enabledLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else {
            throw SiriPlaybackCoordinatorError.noEnabledSources
        }

        guard let resolvedAlbum = try await resolveAlbum(
            request: request,
            enabledSourceKeys: enabledSourceKeys
        ) else {
            throw SiriPlaybackCoordinatorError.mediaNotFound(.album)
        }

        let playableTracks = try await playableTracksForAlbum(
            album: resolvedAlbum,
            request: request,
            enabledSourceKeys: enabledSourceKeys
        )
        guard !playableTracks.isEmpty else {
            throw SiriPlaybackCoordinatorError.noPlayableTracks(.album)
        }

        await playbackService.play(tracks: playableTracks, startingAt: 0)
    }

    /// Resolves an artist and queues all playable tracks in deterministic order.
    public func executePlayArtist(request: SiriPlaybackRequest) async throws {
        let enabledSourceKeys = enabledLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else {
            throw SiriPlaybackCoordinatorError.noEnabledSources
        }

        guard let resolvedArtist = try await resolveArtist(
            request: request,
            enabledSourceKeys: enabledSourceKeys
        ) else {
            throw SiriPlaybackCoordinatorError.mediaNotFound(.artist)
        }

        let playableTracks = try await playableTracksForArtist(
            artist: resolvedArtist,
            request: request,
            enabledSourceKeys: enabledSourceKeys
        )
        guard !playableTracks.isEmpty else {
            throw SiriPlaybackCoordinatorError.noPlayableTracks(.artist)
        }

        await playbackService.play(tracks: playableTracks, startingAt: 0)
    }

    /// Resolves a playlist and queues tracks using saved playlist ordering.
    public func executePlayPlaylist(request: SiriPlaybackRequest) async throws {
        let enabledSourceKeys = enabledLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else {
            throw SiriPlaybackCoordinatorError.noEnabledSources
        }

        let playlistSourceKeys = playlistSearchSourceKeys(from: enabledSourceKeys)

        let playlist = try await resolvePlaylist(
            request: request,
            playlistSearchSourceKeys: playlistSourceKeys
        )

        guard let playlist else {
            throw SiriPlaybackCoordinatorError.mediaNotFound(.playlist)
        }

        let playableTracks = playlist.tracksArray
            .map(Track.init(from:))
            .filter { sourceMatches(requestSource: request.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) }
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }

        guard !playableTracks.isEmpty else {
            throw SiriPlaybackCoordinatorError.noPlayableTracks(.playlist)
        }

        await playbackService.play(tracks: playableTracks, startingAt: 0)
    }

    private func resolveTrack(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDTrack? {
        let tracks = try await libraryRepository.fetchTracks()
        var candidates = tracks.filter { $0.ratingKey == request.entityID }

        if candidates.isEmpty, let displayName = trimmedNonEmpty(request.displayName) {
            candidates = try await libraryRepository.findTracksByTitle(
                displayName,
                sourceCompositeKeys: enabledSourceKeys
            )
        }

        return choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { Int($0.playCount) }
        )
    }

    private func resolveAlbum(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDAlbum? {
        let albums = try await libraryRepository.fetchAlbums()
        var candidates = albums.filter { $0.ratingKey == request.entityID }

        if candidates.isEmpty, let displayName = trimmedNonEmpty(request.displayName) {
            candidates = try await libraryRepository.findAlbumsByTitle(
                displayName,
                sourceCompositeKeys: enabledSourceKeys
            )
        }

        return choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { _ in nil },
            playCount: { _ in nil }
        )
    }

    private func resolveArtist(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDArtist? {
        let artists = try await libraryRepository.fetchArtists()
        var candidates = artists.filter { $0.ratingKey == request.entityID }

        if candidates.isEmpty, let displayName = trimmedNonEmpty(request.displayName) {
            candidates = try await libraryRepository.findArtistsByName(
                displayName,
                sourceCompositeKeys: enabledSourceKeys
            )
        }

        return choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.name },
            source: { $0.sourceCompositeKey },
            lastPlayed: { _ in nil },
            playCount: { _ in nil }
        )
    }

    private func resolvePlaylist(
        request: SiriPlaybackRequest,
        playlistSearchSourceKeys: Set<String>
    ) async throws -> CDPlaylist? {
        if let direct = try await playlistRepository.fetchPlaylist(
            ratingKey: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey
        ) {
            return direct
        }

        guard let displayName = trimmedNonEmpty(request.displayName) else {
            return nil
        }

        let candidates = try await playlistRepository.findPlaylistsByTitle(
            displayName,
            sourceCompositeKeys: playlistSearchSourceKeys
        )

        return choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { _ in nil }
        )
    }

    private func playableTracksForAlbum(
        album: CDAlbum,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        let tracks = try await libraryRepository.fetchTracks(forAlbum: album.ratingKey)
            .map(Track.init(from:))
            .filter { sourceMatches(requestSource: request.sourceCompositeKey ?? album.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) }
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
        return tracks
    }

    private func playableTracksForArtist(
        artist: CDArtist,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        let tracks = try await libraryRepository.fetchTracks(forArtist: artist.ratingKey)
            .map(Track.init(from:))
            .filter { sourceMatches(requestSource: request.sourceCompositeKey ?? artist.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) }
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
        return tracks
    }

    private func enabledLibrarySourceKeys() -> Set<String> {
        Set(accountManager.enabledSources().map(\.compositeKey))
    }

    private func isPlayable(track: Track, enabledSourceKeys: Set<String>) -> Bool {
        guard let sourceCompositeKey = track.sourceCompositeKey else { return false }
        return enabledSourceKeys.contains(sourceCompositeKey)
    }

    private func sourceMatches(requestSource: String?, candidateSource: String?) -> Bool {
        guard let requestSource else { return true }
        guard let candidateSource else { return false }

        if candidateSource == requestSource {
            return true
        }

        if isServerSourceKey(requestSource) {
            return candidateSource.hasPrefix("\(requestSource):")
        }

        return false
    }

    private func isServerSourceKey(_ sourceCompositeKey: String) -> Bool {
        sourceCompositeKey.split(separator: ":").count == 3
    }

    private func choosePreferredCandidate<T>(
        from candidates: [T],
        requestSource: String?,
        requestDisplayName: String?,
        name: (T) -> String,
        source: (T) -> String?,
        lastPlayed: (T) -> Date?,
        playCount: (T) -> Int?
    ) -> T? {
        let scopedCandidates = candidates.filter {
            sourceMatches(requestSource: requestSource, candidateSource: source($0))
        }
        let pool = scopedCandidates.isEmpty ? candidates : scopedCandidates
        guard !pool.isEmpty else { return nil }

        let normalizedDisplayName = normalize(requestDisplayName)
        let sorted = pool.sorted { lhs, rhs in
            let lhsName = normalize(name(lhs)) ?? ""
            let rhsName = normalize(name(rhs)) ?? ""

            let lhsExact = normalizedDisplayName != nil && lhsName == normalizedDisplayName
            let rhsExact = normalizedDisplayName != nil && rhsName == normalizedDisplayName
            if lhsExact != rhsExact {
                return lhsExact
            }

            let lhsLastPlayed = lastPlayed(lhs) ?? .distantPast
            let rhsLastPlayed = lastPlayed(rhs) ?? .distantPast
            if lhsLastPlayed != rhsLastPlayed {
                return lhsLastPlayed > rhsLastPlayed
            }

            let lhsPlayCount = playCount(lhs) ?? 0
            let rhsPlayCount = playCount(rhs) ?? 0
            if lhsPlayCount != rhsPlayCount {
                return lhsPlayCount > rhsPlayCount
            }

            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        return sorted.first
    }

    private func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func playlistSearchSourceKeys(from enabledLibrarySourceKeys: Set<String>) -> Set<String> {
        var keys = enabledLibrarySourceKeys

        for libraryKey in enabledLibrarySourceKeys {
            let components = libraryKey.split(separator: ":")
            guard components.count >= 3 else { continue }
            let serverKey = components.prefix(3).joined(separator: ":")
            keys.insert(serverKey)
        }

        return keys
    }
}
