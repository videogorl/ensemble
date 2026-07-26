import EnsemblePersistence
import EnsembleSiriShared
import Foundation

/// Resolved playback request used by Siri execution entry points.
public struct SiriPlaybackRequest: Sendable, Equatable {
    public let entityID: String
    public let sourceCompositeKey: String?
    public let displayName: String?
    public let artistHint: String?
    public let shuffle: Bool

    public init(entityID: String, sourceCompositeKey: String? = nil, displayName: String? = nil, artistHint: String? = nil, shuffle: Bool = false) {
        self.entityID = entityID
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
        self.artistHint = artistHint
        self.shuffle = shuffle
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
        case let .unsupportedPayloadVersion(version):
            return "Unsupported Siri request version (\(version))."
        case .noEnabledSources:
            return "No enabled music sources are available."
        case let .mediaNotFound(kind):
            return "\(kind.rawValue.capitalized) could not be found."
        case let .noPlayableTracks(kind):
            return "No playable tracks were found for this \(kind.rawValue)."
        }
    }
}

/// Executes Siri media play requests inside the main app process.
@MainActor
public final class SiriPlaybackCoordinator {
    private static let favoritesPlaylistNames: Set<String> = ["favorites", "favourites"]

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
        EnsembleLogger.debug("Siri playback coordinator received activity type: \(userActivity.activityType)")
        guard userActivity.activityType == SiriPlaybackActivityCodec.activityType,
              let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo)
        else {
            EnsembleLogger.debug("Siri playback coordinator rejected activity (type/payload mismatch)")
            return false
        }

        do {
            EnsembleLogger.debug("Siri playback coordinator executing payload kind=\(payload.kind.rawValue), entity=\(payload.entityID)")
            try await execute(payload: payload)
            return true
        } catch {
            EnsembleLogger.debug("Siri playback handling failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Executes a versioned Siri payload by media kind.
    public func execute(payload: SiriPlaybackRequestPayload) async throws {
        guard payload.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion else {
            throw SiriPlaybackCoordinatorError.unsupportedPayloadVersion(payload.schemaVersion)
        }

        EnsembleLogger.debug("Siri payload schema=\(payload.schemaVersion), source=\(payload.sourceCompositeKey ?? "nil"), display=\(payload.displayName ?? "nil")")

        let request = SiriPlaybackRequest(
            entityID: payload.entityID,
            sourceCompositeKey: payload.sourceCompositeKey,
            displayName: payload.displayName,
            artistHint: payload.artistHint,
            shuffle: payload.shuffle ?? false
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

        await playbackService.play(
            track: track,
            context: playbackContext(
                kind: .track,
                id: resolved.ratingKey,
                sourceCompositeKey: resolved.sourceCompositeKey,
                displayName: resolved.title,
                secondaryText: resolved.artistName
            )
        )
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

        if request.shuffle {
            await playbackService.shufflePlay(
                tracks: orderedArtistShuffleTracks(playableTracks),
                context: playbackContext(
                    kind: .album,
                    id: resolvedAlbum.ratingKey,
                    sourceCompositeKey: resolvedAlbum.sourceCompositeKey,
                    displayName: resolvedAlbum.title,
                    secondaryText: resolvedAlbum.artistName
                )
            )
        } else {
            await playbackService.play(
                tracks: playableTracks,
                startingAt: 0,
                context: playbackContext(
                    kind: .album,
                    id: resolvedAlbum.ratingKey,
                    sourceCompositeKey: resolvedAlbum.sourceCompositeKey,
                    displayName: resolvedAlbum.title,
                    secondaryText: resolvedAlbum.artistName
                )
            )
        }
    }

    /// Resolves an artist and queues all playable tracks in shuffled order.
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

        if request.shuffle {
            await playbackService.shufflePlay(
                tracks: orderedArtistShuffleTracks(playableTracks),
                context: playbackContext(
                    kind: .artist,
                    id: resolvedArtist.ratingKey,
                    sourceCompositeKey: resolvedArtist.sourceCompositeKey,
                    displayName: resolvedArtist.name,
                    secondaryText: nil
                )
            )
        } else {
            await playbackService.play(
                tracks: playableTracks,
                startingAt: 0,
                context: playbackContext(
                    kind: .artist,
                    id: resolvedArtist.ratingKey,
                    sourceCompositeKey: resolvedArtist.sourceCompositeKey,
                    displayName: resolvedArtist.name,
                    secondaryText: nil
                )
            )
        }
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

        if request.shuffle {
            await playbackService.shufflePlay(
                tracks: playableTracks,
                context: playbackContext(
                    kind: .playlist,
                    id: playlist.ratingKey,
                    sourceCompositeKey: playlist.sourceCompositeKey,
                    displayName: playlist.title,
                    secondaryText: nil
                )
            )
        } else {
            await playbackService.play(
                tracks: playableTracks,
                startingAt: 0,
                context: playbackContext(
                    kind: .playlist,
                    id: playlist.ratingKey,
                    sourceCompositeKey: playlist.sourceCompositeKey,
                    displayName: playlist.title,
                    secondaryText: nil
                )
            )
        }
    }

    private func playbackContext(
        kind: SiriMediaKind,
        id: String,
        sourceCompositeKey: String?,
        displayName: String,
        secondaryText: String?
    ) -> PlaybackStartContext {
        PlaybackStartContext(
            origin: .siri,
            source: PlaybackStartSource(kind: kind),
            reference: SystemMediaReference(
                kind: kind,
                id: id,
                sourceCompositeKey: sourceCompositeKey,
                displayName: displayName,
                secondaryText: secondaryText
            )
        )
    }

    private func resolveTrack(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDTrack? {
        if let direct = try await libraryRepository.fetchTrack(
            ratingKey: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey
        ) {
            return direct
        }

        guard let displayName = bestQueryVariant(for: request.displayName) else {
            return nil
        }

        let candidates = try await libraryRepository.findTracksByTitle(
            displayName,
            sourceCompositeKeys: enabledSourceKeys
        )

        // When artistHint is available, prefer tracks by that artist
        let prioritized = preferByArtist(candidates, hint: request.artistHint)

        if let resolved = choosePreferredCandidate(
            from: prioritized,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { Int($0.playCount) }
        ) {
            return resolved
        }

        let fuzzyPool = try Array(await libraryRepository.fetchSiriEligibleTracks().prefix(800))
        let fuzzyCandidates = fuzzyCandidates(
            from: fuzzyPool,
            request: request,
            allowedSourceKeys: enabledSourceKeys,
            name: { $0.title },
            source: { $0.sourceCompositeKey }
        )
        let prioritizedFuzzy = preferByArtist(fuzzyCandidates, hint: request.artistHint)
        return choosePreferredCandidate(
            from: prioritizedFuzzy,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { Int($0.playCount) }
        )
    }

    /// Reorders tracks so those matching the artist hint appear first.
    private func preferByArtist(_ tracks: [CDTrack], hint: String?) -> [CDTrack] {
        guard let hint, !hint.isEmpty else { return tracks }
        let normalizedHint = hint.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let (matching, rest) = tracks.reduce(into: ([CDTrack](), [CDTrack]())) { result, track in
            if let artist = track.artistName?.lowercased(), artist.contains(normalizedHint) || normalizedHint.contains(artist) {
                result.0.append(track)
            } else {
                result.1.append(track)
            }
        }
        return matching + rest
    }

    private func resolveAlbum(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDAlbum? {
        if let direct = try await libraryRepository.fetchAlbum(
            ratingKey: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey
        ) {
            return direct
        }

        guard let displayName = bestQueryVariant(for: request.displayName) else {
            return nil
        }

        let candidates = try await libraryRepository.findAlbumsByTitle(
            displayName,
            sourceCompositeKeys: enabledSourceKeys
        )

        if let resolved = choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { _ in nil },
            playCount: { _ in nil }
        ) {
            return resolved
        }

        let fuzzyPool = try Array(await libraryRepository.fetchAlbums().prefix(800))
        let fuzzyMatches = fuzzyCandidates(
            from: fuzzyPool,
            request: request,
            allowedSourceKeys: enabledSourceKeys,
            name: { $0.title },
            source: { $0.sourceCompositeKey }
        )
        return choosePreferredCandidate(
            from: fuzzyMatches,
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
        if let direct = try await libraryRepository.fetchArtist(
            ratingKey: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey
        ) {
            return direct
        }

        guard let displayName = bestQueryVariant(for: request.displayName) else {
            return nil
        }

        let candidates = try await libraryRepository.findArtistsByName(
            displayName,
            sourceCompositeKeys: enabledSourceKeys
        )

        if let resolved = choosePreferredCandidate(
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.name },
            source: { $0.sourceCompositeKey },
            lastPlayed: { _ in nil },
            playCount: { _ in nil }
        ) {
            return resolved
        }

        let fuzzyPool = try await libraryRepository.fetchArtists()
        let fuzzyMatches = fuzzyCandidates(
            from: fuzzyPool,
            request: request,
            allowedSourceKeys: enabledSourceKeys,
            name: { $0.name },
            source: { $0.sourceCompositeKey }
        )
        return choosePreferredCandidate(
            from: fuzzyMatches,
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
        if let favorites = try await resolveFavoritesPlaylistIfNeeded(
            request: request,
            playlistSearchSourceKeys: playlistSearchSourceKeys
        ) {
            return favorites
        }

        if let direct = try await playlistRepository.fetchPlaylist(
            ratingKey: request.entityID,
            sourceCompositeKey: request.sourceCompositeKey
        ) {
            return direct
        }

        guard let displayName = bestQueryVariant(for: request.displayName) else {
            return nil
        }

        let candidates = try await playlistRepository.findPlaylistsByTitle(
            displayName,
            sourceCompositeKeys: playlistSearchSourceKeys
        )

        if let resolved = choosePreferredCandidate(
            from: prioritizeExactPlaylistMatches(candidates, displayName: displayName),
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { _ in nil }
        ) {
            return resolved
        }

        let fuzzyPool = try Array(await playlistRepository.fetchPlaylists().prefix(600))
        let fuzzyMatches = fuzzyCandidates(
            from: fuzzyPool,
            request: request,
            allowedSourceKeys: playlistSearchSourceKeys,
            name: { $0.title },
            source: { $0.sourceCompositeKey }
        )
        return choosePreferredCandidate(
            from: fuzzyMatches,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { _ in nil }
        )
    }

    private func prioritizeExactPlaylistMatches(
        _ playlists: [CDPlaylist],
        displayName: String
    ) -> [CDPlaylist] {
        guard let normalizedDisplayName = normalize(displayName), !normalizedDisplayName.isEmpty else {
            return playlists
        }
        let (exact, rest) = playlists.reduce(into: ([CDPlaylist](), [CDPlaylist]())) { result, playlist in
            if normalize(playlist.title) == normalizedDisplayName {
                result.0.append(playlist)
            } else {
                result.1.append(playlist)
            }
        }
        return exact + rest
    }

    private func resolveFavoritesPlaylistIfNeeded(
        request: SiriPlaybackRequest,
        playlistSearchSourceKeys: Set<String>
    ) async throws -> CDPlaylist? {
        guard let displayName = bestQueryVariant(for: request.displayName) else { return nil }
        guard let normalizedDisplayName = normalize(displayName),
              Self.favoritesPlaylistNames.contains(normalizedDisplayName) else { return nil }

        return try await playlistRepository.fetchPlaylists().first {
            $0.isSmart &&
                playlistSearchSourceKeys.contains($0.sourceCompositeKey ?? "") &&
                Self.favoritesPlaylistNames.contains(normalize($0.title) ?? "")
        }
    }

    private func playableTracksForAlbum(
        album: CDAlbum,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        return try await libraryRepository.fetchTracks(forAlbum: album.ratingKey)
            .map(Track.init(from:))
            .filter { sourceMatches(requestSource: request.sourceCompositeKey ?? album.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) }
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
    }

    private func playableTracksForArtist(
        artist: CDArtist,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        return try await libraryRepository.fetchTracks(forArtist: artist.ratingKey)
            .map(Track.init(from:))
            .filter { sourceMatches(requestSource: request.sourceCompositeKey ?? artist.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) }
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
    }

    private func orderedArtistShuffleTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            if lhs.albumName == rhs.albumName {
                if lhs.discNumber == rhs.discNumber {
                    return lhs.trackNumber < rhs.trackNumber
                }
                return lhs.discNumber < rhs.discNumber
            }
            return (lhs.albumName ?? lhs.title) < (rhs.albumName ?? rhs.title)
        }
    }

    private func enabledLibrarySourceKeys() -> Set<String> {
        Set(accountManager.enabledSources().filter { $0.type == .plex }.map(\.compositeKey))
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
        MediaSourceIdentity.parse(sourceCompositeKey)?.isServerScoped == true
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

        let normalizedDisplayNameVariants = normalizedQueryVariants(for: requestDisplayName)
        let sorted = pool.sorted { lhs, rhs in
            let lhsName = normalize(name(lhs)) ?? ""
            let rhsName = normalize(name(rhs)) ?? ""

            let lhsScore = matchScore(queries: normalizedDisplayNameVariants, candidate: lhsName)
            let rhsScore = matchScore(queries: normalizedDisplayNameVariants, candidate: rhsName)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
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

    private func fuzzyCandidates<T>(
        from candidates: [T],
        request: SiriPlaybackRequest,
        allowedSourceKeys: Set<String>,
        name: (T) -> String,
        source: (T) -> String?
    ) -> [T] {
        let queryVariants = normalizedQueryVariants(for: request.displayName)
        guard !queryVariants.isEmpty else { return [] }

        let scoredCandidates: [(candidate: T, score: Double)] = candidates.compactMap { candidate in
            guard let sourceKey = source(candidate), allowedSourceKeys.contains(sourceKey) else {
                return nil
            }
            guard sourceMatches(requestSource: request.sourceCompositeKey, candidateSource: sourceKey) else {
                return nil
            }

            let candidateName = normalize(name(candidate)) ?? ""
            let score = matchScore(queries: queryVariants, candidate: candidateName)
            guard score >= 0.66 else { return nil }
            return (candidate, score)
        }

        return scoredCandidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                let lhsName = normalize(name(lhs.candidate)) ?? ""
                let rhsName = normalize(name(rhs.candidate)) ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            .map(\.candidate)
    }

    private func normalize(_ value: String?) -> String? {
        SiriPhraseNormalizer.basic(value)
    }

    private func normalizedQueryVariants(for value: String?) -> [String] {
        SiriPhraseNormalizer.queryVariants(for: value)
    }

    private func bestQueryVariant(for value: String?) -> String? {
        SiriPhraseNormalizer.bestQueryVariant(for: value)
    }

    private func matchScore(queries: [String], candidate: String) -> Double {
        SiriMatchScorer.scoreMatch(queries: queries, candidate: candidate)
    }

    private func playlistSearchSourceKeys(from enabledLibrarySourceKeys: Set<String>) -> Set<String> {
        var keys = enabledLibrarySourceKeys

        for libraryKey in enabledLibrarySourceKeys {
            if let serverKey = MediaSourceIdentity.serverSourceKey(from: libraryKey) {
                keys.insert(serverKey)
            }
        }

        return keys
    }
}
