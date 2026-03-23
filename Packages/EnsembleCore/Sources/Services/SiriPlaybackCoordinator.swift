import EnsemblePersistence
import Foundation

/// Resolved playback request used by Siri execution entry points.
public struct SiriPlaybackRequest: Sendable, Equatable {
    public let entityID: String
    public let sourceCompositeKey: String?
    public let displayName: String?
    public let artistHint: String?

    public init(entityID: String, sourceCompositeKey: String? = nil, displayName: String? = nil, artistHint: String? = nil) {
        self.entityID = entityID
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
        self.artistHint = artistHint
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
    private static let appNameSuffixes = [" ensemble music", " ensemble"]
    private static let trailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    private static let leadingMediaTypePrefixes = [
        "the playlist ",
        "playlist ",
        "the album ",
        "album ",
        "the artist ",
        "artist ",
        "the song ",
        "song ",
        "the track ",
        "track "
    ]

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
        #if DEBUG
        EnsembleLogger.debug("Siri playback coordinator received activity type: \(userActivity.activityType)")
        #endif
        guard userActivity.activityType == SiriPlaybackActivityCodec.activityType,
              let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo) else {
            #if DEBUG
            EnsembleLogger.debug("Siri playback coordinator rejected activity (type/payload mismatch)")
            #endif
            return false
        }

        do {
            #if DEBUG
            EnsembleLogger.debug("Siri playback coordinator executing payload kind=\(payload.kind.rawValue), entity=\(payload.entityID)")
            #endif
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

        #if DEBUG
        EnsembleLogger.debug("Siri payload schema=\(payload.schemaVersion), source=\(payload.sourceCompositeKey ?? "nil"), display=\(payload.displayName ?? "nil")")
        #endif

        let request = SiriPlaybackRequest(
            entityID: payload.entityID,
            sourceCompositeKey: payload.sourceCompositeKey,
            displayName: payload.displayName,
            artistHint: payload.artistHint
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

        await playbackService.shufflePlay(tracks: playableTracks)
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
        if let direct = try await libraryRepository.fetchTrack(ratingKey: request.entityID) {
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

        let fuzzyPool = try await libraryRepository.fetchSiriEligibleTracks()
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
        if let direct = try await libraryRepository.fetchAlbum(ratingKey: request.entityID) {
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

        let fuzzyPool = try await libraryRepository.fetchAlbums()
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
        if let direct = try await libraryRepository.fetchArtist(ratingKey: request.entityID) {
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
            from: candidates,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { _ in nil }
        ) {
            return resolved
        }

        let fuzzyPool = try await playlistRepository.fetchPlaylists()
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

    private func normalizedQueryVariants(for value: String?) -> [String] {
        guard let base = normalize(value), !base.isEmpty else { return [] }

        var variants = Set<String>()
        variants.insert(base)
        variants.insert(strippingLeadingMediaTypePrefix(from: base))
        variants.insert(trimTrailingConnectorWords(in: base))
        variants.insert(strippingLeadingMediaTypePrefix(from: trimTrailingConnectorWords(in: base)))

        for suffix in Self.appNameSuffixes where base.hasSuffix(suffix) {
            let trimmed = base.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            variants.insert(trimTrailingConnectorWords(in: trimmed))
            variants.insert(strippingLeadingMediaTypePrefix(from: trimTrailingConnectorWords(in: trimmed)))
        }

        return variants
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private func bestQueryVariant(for value: String?) -> String? {
        normalizedQueryVariants(for: value).first
    }

    private func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, Self.trailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private func strippingLeadingMediaTypePrefix(from value: String) -> String {
        for prefix in Self.leadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return value
    }

    private func matchScore(queries: [String], candidate: String) -> Double {
        queries.reduce(0) { bestScore, query in
            max(bestScore, matchScore(query: query, candidate: candidate))
        }
    }

    private func matchScore(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.84 }
        if candidate.contains(query) || query.contains(candidate) { return 0.7 }

        var score = 0.0
        let overlap = tokenOverlapScore(query: query, candidate: candidate)
        if overlap >= 0.67 {
            score = max(score, 0.45 + overlap * 0.35)
        }

        let similarity = normalizedEditSimilarity(lhs: query, rhs: candidate)
        if similarity >= 0.66 {
            score = max(score, 0.35 + similarity * 0.4)
        }

        return score
    }

    private func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        let referenceCount = max(queryTokens.count, candidateTokens.count)
        return Double(overlap) / Double(referenceCount)
    }

    private func normalizedEditSimilarity(lhs: String, rhs: String) -> Double {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        guard !lhsChars.isEmpty, !rhsChars.isEmpty else { return 0 }

        var previous = Array(0...rhsChars.count)
        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhsChars.count + 1)

            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsChar == rhsChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }

            previous = current
        }

        let distance = previous.last ?? max(lhsChars.count, rhsChars.count)
        let normalizer = max(lhsChars.count, rhsChars.count)
        return 1 - (Double(distance) / Double(normalizer))
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
