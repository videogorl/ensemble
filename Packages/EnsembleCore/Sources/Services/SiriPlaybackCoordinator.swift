import EnsembleAPI
import EnsembleDomain
import EnsemblePersistence
import EnsembleSiriShared
import EnsembleSupport
import Foundation

/// Resolved playback request used by Siri execution entry points.
public struct SiriPlaybackRequest: Sendable, Equatable {
    public let entityID: String
    public let sourceCompositeKey: String?
    public let displayName: String?
    public let artistHint: String?
    public let shuffle: Bool

    public init(
        entityID: String,
        sourceCompositeKey: String? = nil,
        displayName: String? = nil,
        artistHint: String? = nil,
        shuffle: Bool = false
    ) {
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
    case playbackFailed(String)

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
        case let .playbackFailed(message):
            return message
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
    private let hiddenMediaStore: HiddenMediaStore
    private let visibilityStore: LibraryVisibilityStore
    private let mergingPreferences: @MainActor () -> EnsembleMergingPreferences

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        playbackService: PlaybackServiceProtocol,
        hiddenMediaStore: HiddenMediaStore? = nil,
        visibilityStore: LibraryVisibilityStore? = nil,
        mergingPreferences: @escaping @MainActor () -> EnsembleMergingPreferences = { .default }
    ) {
        self.visibilityStore = visibilityStore ?? .shared
        self.mergingPreferences = mergingPreferences
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.playbackService = playbackService
        self.hiddenMediaStore = hiddenMediaStore ?? .shared
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

        EnsembleLogger.debug("Siri payload schema=\(payload.schemaVersion) kind=\(payload.kind.rawValue) hasSource=\(payload.sourceCompositeKey != nil) hasDisplayName=\(payload.displayName != nil)")

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
        try await play(.track, request: request)
    }

    /// Resolves an album and queues all playable tracks from track 1.
    public func executePlayAlbum(request: SiriPlaybackRequest) async throws {
        try await play(.album, request: request)
    }

    /// Resolves an artist and queues all playable tracks in shuffled order.
    public func executePlayArtist(request: SiriPlaybackRequest) async throws {
        try await play(.artist, request: request)
    }

    /// Resolves a playlist and queues tracks using saved playlist ordering.
    public func executePlayPlaylist(request: SiriPlaybackRequest) async throws {
        try await play(.playlist, request: request)
    }

    /// Adds a track, album, artist or playlist after the current item or at the end of the queue.
    /// Returns the number of tracks added.
    @discardableResult
    public func enqueue(
        kind: SiriMediaKind,
        request: SiriPlaybackRequest,
        playNext: Bool
    ) async throws -> Int {
        let media = try await resolveMedia(kind: kind, request: request, mergesSamePlaylists: true)
        try Task.checkCancellation()
        if playNext {
            playbackService.playNext(media.tracks)
        } else {
            playbackService.playLast(media.tracks)
        }
        return media.tracks.count
    }

    /// Plays every playable track in the enabled libraries, as the Songs screen's Shuffle does.
    /// Rows are read from the enabled sources only, in bounded batches.
    public func playLibrary(shuffle: Bool) async throws {
        let enabledSourceKeys = visibleLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else { throw SiriPlaybackCoordinatorError.noEnabledSources }
        let tracks = try await libraryRepository.mapTracks(forSources: enabledSourceKeys, batchSize: 500) {
            Track(from: $0)
        }
        try await play(tracks, shuffle: shuffle, enabledSourceKeys: enabledSourceKeys, name: "Library")
    }

    /// Plays the favourite tracks of every enabled library, as the Favorites screen does.
    public func playFavorites(shuffle: Bool) async throws {
        let enabledSourceKeys = visibleLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else { throw SiriPlaybackCoordinatorError.noEnabledSources }
        let tracks = try await libraryRepository.fetchFavoriteTracks().map(Track.init(from:))
        try await play(tracks, shuffle: shuffle, enabledSourceKeys: enabledSourceKeys, name: "Favorites")
    }

    /// Plays tracks a caller already gathered for a library collection (a genre, a mood, recently added).
    public func playCollection(_ tracks: [Track], name: String, shuffle: Bool) async throws {
        let enabledSourceKeys = visibleLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else { throw SiriPlaybackCoordinatorError.noEnabledSources }
        try await play(tracks, shuffle: shuffle, enabledSourceKeys: enabledSourceKeys, name: name)
    }

    /// The playable tracks of a track, album, artist or playlist, for actions that add them elsewhere.
    public func resolveTracks(kind: SiriMediaKind, request: SiriPlaybackRequest) async throws -> [Track] {
        try await resolveMedia(kind: kind, request: request).tracks
    }

    /// Songs, albums and artists (or only `kind`) in enabled, visible sources whose names match `query`, read from the
    /// full store. The Siri index holds a capped slice of each kind, so a Shortcuts picker adds these to the index's
    /// own candidates and ranks them together. Unranked and bounded: a query under two characters finds nothing, each
    /// lookup keeps at most ten times `limit` rows that are not hidden (exact names first, then prefix, contains, then
    /// every word of the query, so "AC/DC" finds "ac dc"), and songs the title lookup misses are scored in paged
    /// batches keeping the best ten times `limit`. Playlists are not capped, so none return.
    public func libraryCandidates(kind: SiriMediaKind?, matching query: String, limit: Int) async throws -> [SiriMediaIndexItem] {
        let sourceKeys = visibleLibrarySourceKeys()
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, limit > 0, !sourceKeys.isEmpty else { return [] }
        let fetchCap = limit * 10
        let hidden = hiddenMediaStore.snapshot
        var items: [SiriMediaIndexItem] = []
        for current in [SiriMediaKind.track, .album, .artist] where kind == nil || kind == current {
            switch current {
            case .track:
                var tracks = try await libraryRepository.findTracksByTitle(
                    query, sourceCompositeKeys: sourceKeys, limit: fetchCap, isEligible: { !hidden.isHidden(Track(from: $0)) }
                ).map(SiriMediaIndexStore.indexItem(for:))
                if Self.rank(tracks, kind: .track, query: query).isEmpty {
                    // The title lookup compares text, so what it cannot tell apart ("Kim & Jessie") can miss it.
                    let variants = SiriPhraseNormalizer.queryVariants(for: query)
                    let best = BestMatches(capacity: fetchCap)
                    _ = try await libraryRepository.mapTracks(forSources: sourceKeys, batchSize: 500) { track -> Int? in
                        let score = SiriMatchScorer.scoreMatch(queries: variants, candidate: SiriPhraseNormalizer.basic(track.title))
                        guard score >= 0.66, !hidden.isHidden(Track(from: track)) else { return nil }
                        best.offer(SiriMediaIndexStore.indexItem(for: track), score: score)
                        return nil
                    }
                    tracks = best.items
                }
                items += tracks
            case .album:
                items += try await libraryRepository.findAlbumsByTitle(
                    query, sourceCompositeKeys: sourceKeys, limit: fetchCap, isEligible: { !hidden.isHidden(Album(from: $0)) }
                ).map(SiriMediaIndexStore.indexItem(for:))
            case .artist:
                items += try await libraryRepository.findArtistsByName(
                    query, sourceCompositeKeys: sourceKeys, limit: fetchCap, isEligible: { !hidden.isHidden(Artist(from: $0)) }
                ).map(SiriMediaIndexStore.indexItem(for:))
            case .playlist:
                continue
            }
            try Task.checkCancellation()
        }
        return items
    }

    /// The best `capacity` offers by score, so a scan of a large library holds a bounded list.
    private final class BestMatches: @unchecked Sendable {
        private let capacity: Int
        private let lock = NSLock()
        private var offers: [(item: SiriMediaIndexItem, score: Double)] = []

        init(capacity: Int) { self.capacity = capacity }

        var items: [SiriMediaIndexItem] { lock.withLock { offers.map(\.item) } }

        func offer(_ item: SiriMediaIndexItem, score: Double) {
            lock.withLock {
                guard offers.count < capacity || score > offers[offers.count - 1].score else { return }
                let index = offers.firstIndex { $0.score < score } ?? offers.count
                offers.insert((item, score), at: index)
                if offers.count > capacity { offers.removeLast() }
            }
        }
    }

    /// The index item for a saved song, album or artist reference the capped index no longer holds. Nil when the
    /// item is gone, hidden, or in a source that is not enabled and visible.
    public func storedItem(kind: SiriMediaKind, id: String, sourceCompositeKey: String?) async throws -> SiriMediaIndexItem? {
        guard let sourceCompositeKey, visibleLibrarySourceKeys().contains(sourceCompositeKey) else { return nil }
        let hidden = hiddenMediaStore.snapshot
        switch kind {
        case .track:
            return try await libraryRepository.fetchTrack(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
                .flatMap { hidden.isHidden(Track(from: $0)) ? nil : SiriMediaIndexStore.indexItem(for: $0) }
        case .album:
            return try await libraryRepository.fetchAlbum(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
                .flatMap { hidden.isHidden(Album(from: $0)) ? nil : SiriMediaIndexStore.indexItem(for: $0) }
        case .artist:
            return try await libraryRepository.fetchArtist(ratingKey: id, sourceCompositeKey: sourceCompositeKey)
                .flatMap { hidden.isHidden(Artist(from: $0)) ? nil : SiriMediaIndexStore.indexItem(for: $0) }
        case .playlist:
            return nil
        }
    }

    private static func rank(_ items: [SiriMediaIndexItem], kind: SiriMediaKind, query: String) -> [SiriMediaIndexItem] {
        SiriMediaIndexResolver.rankCandidates(
            for: query,
            requestedKinds: [kind],
            index: SiriMediaIndex(items: items),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        ).map(\.item)
    }

    /// Plays a track with Autoplay on, which is how the app starts a track radio.
    public func startTrackRadio(request: SiriPlaybackRequest) async throws {
        let media = try await resolveMedia(kind: .track, request: request)
        guard let track = media.tracks.first else { return }
        await playbackService.play(track: track, context: media.context)
        try throwIfPlaybackFailed()
        guard playbackService.currentTrack?.sourceScopedID == track.sourceScopedID,
              !playbackService.isAutoplayEnabled else { return }
        playbackService.toggleAutoplay()
    }

    private struct ResolvedMedia {
        let tracks: [Track]
        let context: PlaybackStartContext
    }

    private func play(_ kind: SiriMediaKind, request: SiriPlaybackRequest) async throws {
        let media = try await resolveMedia(kind: kind, request: request, mergesSamePlaylists: true)
        try Task.checkCancellation()
        if kind == .track, let track = media.tracks.first {
            await playbackService.play(track: track, context: media.context)
        } else if request.shuffle {
            await playbackService.shufflePlay(
                tracks: kind == .playlist ? media.tracks : orderedArtistShuffleTracks(media.tracks),
                context: media.context
            )
        } else {
            await playbackService.play(tracks: media.tracks, startingAt: 0, context: media.context)
        }
        try throwIfPlaybackFailed()
    }

    /// `PlaybackService` reports a failed start through its state and returns normally.
    private func throwIfPlaybackFailed() throws {
        if case let .failed(message) = playbackService.playbackState {
            throw SiriPlaybackCoordinatorError.playbackFailed(message)
        }
    }

    private func play(
        _ tracks: [Track],
        shuffle: Bool,
        enabledSourceKeys: Set<String>,
        name: String
    ) async throws {
        let playable = tracks.filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
        guard !playable.isEmpty else { throw SiriPlaybackCoordinatorError.noPlayableTracks(.track) }
        let context = PlaybackStartContext(origin: .appShortcut, source: .unknown)
        EnsembleLogger.debug("Siri playback coordinator playing \(name) tracks=\(playable.count) shuffle=\(shuffle)")
        if shuffle {
            await playbackService.shufflePlay(tracks: playable, context: context)
        } else {
            await playbackService.play(tracks: playable, startingAt: 0, context: context)
        }
        try throwIfPlaybackFailed()
    }

    /// Resolves a request to its playable tracks and the start context describing the item.
    private func resolveMedia(
        kind: SiriMediaKind,
        request: SiriPlaybackRequest,
        mergesSamePlaylists: Bool = false
    ) async throws -> ResolvedMedia {
        let enabledSourceKeys = visibleLibrarySourceKeys()
        guard !enabledSourceKeys.isEmpty else {
            throw SiriPlaybackCoordinatorError.noEnabledSources
        }

        let tracks: [Track]
        let context: PlaybackStartContext
        switch kind {
        case .track:
            guard let resolved = try await resolveTrack(request: request, enabledSourceKeys: enabledSourceKeys) else {
                throw SiriPlaybackCoordinatorError.mediaNotFound(.track)
            }
            tracks = [Track(from: resolved)].filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
            context = playbackContext(
                kind: .track,
                id: resolved.ratingKey,
                sourceCompositeKey: resolved.sourceCompositeKey,
                displayName: resolved.title,
                secondaryText: resolved.artistName
            )
        case .album:
            guard let album = try await resolveAlbum(request: request, enabledSourceKeys: enabledSourceKeys) else {
                throw SiriPlaybackCoordinatorError.mediaNotFound(.album)
            }
            tracks = try await playableTracksForAlbum(
                album: album, request: request, enabledSourceKeys: enabledSourceKeys
            )
            context = playbackContext(
                kind: .album,
                id: album.ratingKey,
                sourceCompositeKey: album.sourceCompositeKey,
                displayName: album.title,
                secondaryText: album.artistName
            )
        case .artist:
            guard let artist = try await resolveArtist(request: request, enabledSourceKeys: enabledSourceKeys) else {
                throw SiriPlaybackCoordinatorError.mediaNotFound(.artist)
            }
            tracks = try await playableTracksForArtist(
                artist: artist, request: request, enabledSourceKeys: enabledSourceKeys
            )
            context = playbackContext(
                kind: .artist,
                id: artist.ratingKey,
                sourceCompositeKey: artist.sourceCompositeKey,
                displayName: artist.name,
                secondaryText: nil
            )
        case .playlist:
            let playlistSourceKeys = playlistSearchSourceKeys(from: enabledSourceKeys)
            guard let playlist = try await resolvePlaylist(
                request: request,
                playlistSearchSourceKeys: playlistSourceKeys
            ) else {
                throw SiriPlaybackCoordinatorError.mediaNotFound(.playlist)
            }
            // Plex playlists of one name on several servers are one playlist in the app, so they play as one.
            let constituents = mergesSamePlaylists
                ? try await displayedConstituents(of: playlist)
                : [playlist]
            guard !constituents.isEmpty else { throw SiriPlaybackCoordinatorError.mediaNotFound(.playlist) }
            // Only the named playlist alone is held to the request's source; a group is whatever the screen shows.
            let requestSource = constituents.count == 1 && constituents[0] === playlist ? request.sourceCompositeKey : nil
            // Memberships, as the playlist screen reads them: an Apple Music playlist can hold catalog songs
            // that are not library rows, and those still play.
            tracks = PlexPlaylistMergeRules.interleaved(constituents.map { constituent in
                constituent.playlistItemsArray
                    .map { PlaylistItem(from: $0) }
                    .filter(\.isAvailable)
                    .map(\.track)
                    .filter { sourceMatches(requestSource: requestSource, candidateSource: $0.sourceCompositeKey) }
                    .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
            })
            context = playbackContext(
                kind: .playlist,
                id: playlist.ratingKey,
                sourceCompositeKey: playlist.sourceCompositeKey,
                displayName: playlist.title,
                secondaryText: nil
            )
        }

        guard !tracks.isEmpty else {
            throw SiriPlaybackCoordinatorError.noPlayableTracks(kind)
        }
        return ResolvedMedia(tracks: tracks, context: context)
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
        if let sourceCompositeKey = request.sourceCompositeKey,
           let direct = try await libraryRepository.fetchTrack(
               ratingKey: request.entityID,
               sourceCompositeKey: sourceCompositeKey
           )
        {
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
        let prioritized = preferByArtist(candidates, hint: request.artistHint, artist: { $0.artistName })

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

        // The title lookup compares raw text, so punctuation ("Kim & Jessie") can miss it. Score normalised titles
        // across the whole library in bounded batches, keeping only the near matches, then load only the winner.
        let queryVariants = normalizedQueryVariants(for: request.displayName)
        guard !queryVariants.isEmpty else { return nil }
        let stubs = try await libraryRepository.mapTracks(forSources: enabledSourceKeys, batchSize: 500) { track -> TrackStub? in
            guard SiriMatchScorer.scoreMatch(queries: queryVariants, candidate: SiriPhraseNormalizer.basic(track.title)) >= 0.66 else {
                return nil
            }
            return TrackStub(
                ratingKey: track.ratingKey,
                sourceCompositeKey: track.sourceCompositeKey,
                title: track.title,
                artistName: track.artistName,
                lastPlayed: track.lastPlayed,
                playCount: Int(track.playCount)
            )
        }
        try Task.checkCancellation()
        let fuzzy = preferByArtist(
            fuzzyCandidates(
                from: stubs,
                request: request,
                allowedSourceKeys: enabledSourceKeys,
                name: { $0.title },
                source: { $0.sourceCompositeKey }
            ),
            hint: request.artistHint,
            artist: { $0.artistName }
        )
        guard let best = choosePreferredCandidate(
            from: fuzzy,
            requestSource: request.sourceCompositeKey,
            requestDisplayName: request.displayName,
            name: { $0.title },
            source: { $0.sourceCompositeKey },
            lastPlayed: { $0.lastPlayed },
            playCount: { $0.playCount }
        ) else { return nil }
        return try await libraryRepository.fetchTrack(ratingKey: best.ratingKey, sourceCompositeKey: best.sourceCompositeKey)
    }

    private struct TrackStub: Sendable {
        let ratingKey: String
        let sourceCompositeKey: String?
        let title: String
        let artistName: String?
        let lastPlayed: Date?
        let playCount: Int
    }

    /// Reorders candidates so those by the artist hint appear first.
    private func preferByArtist<T>(_ items: [T], hint: String?, artist: (T) -> String?) -> [T] {
        guard let hint, !hint.isEmpty else { return items }
        let normalizedHint = hint.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let (matching, rest) = items.reduce(into: ([T](), [T]())) { result, item in
            if let name = artist(item)?.lowercased(), name.contains(normalizedHint) || normalizedHint.contains(name) {
                result.0.append(item)
            } else {
                result.1.append(item)
            }
        }
        return matching + rest
    }

    private func resolveAlbum(
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> CDAlbum? {
        if let sourceCompositeKey = request.sourceCompositeKey,
           let direct = try await libraryRepository.fetchAlbum(
               ratingKey: request.entityID,
               sourceCompositeKey: sourceCompositeKey
           )
        {
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
        if let sourceCompositeKey = request.sourceCompositeKey,
           let direct = try await libraryRepository.fetchArtist(
               ratingKey: request.entityID,
               sourceCompositeKey: sourceCompositeKey
           )
        {
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
        if let sourceCompositeKey = request.sourceCompositeKey,
           let direct = try await playlistRepository.fetchPlaylist(
               ratingKey: request.entityID,
               sourceCompositeKey: sourceCompositeKey
           )
        {
            return direct
        }

        if let favorites = try await resolveFavoritesPlaylistIfNeeded(
            request: request,
            playlistSearchSourceKeys: playlistSearchSourceKeys
        ) {
            return favorites
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

    /// The playlists the playlist screen shows: its hidden-media and hidden-source rules, with their stored rows.
    private func visiblePlaylists() async throws -> (visible: [Playlist], stored: [String: CDPlaylist]) {
        let isSourceVisible = visibilityStore.playlistSourceVisibility(in: accountManager.sourceConfigurationSnapshot)
        var storedBySourceID: [String: CDPlaylist] = [:]
        var visible: [Playlist] = []
        for stored in try await playlistRepository.fetchPlaylists() {
            let candidate = Playlist(from: stored)
            guard isSourceVisible(candidate.sourceCompositeKey), !hiddenMediaStore.snapshot.isHidden(candidate) else { continue }
            storedBySourceID[candidate.sourceScopedID] = stored
            visible.append(candidate)
        }
        return (visible, storedBySourceID)
    }

    /// The playlists the playlist screen shows for this one, in its order (`DisplayPlaylist.displayedGroup`: the same
    /// grouping, merge setting, hidden-media and hidden-source rules). Empty when only hidden copies remain; a hidden
    /// copy is never played.
    private func displayedConstituents(of playlist: CDPlaylist) async throws -> [CDPlaylist] {
        let (visible, storedBySourceID) = try await visiblePlaylists()
        guard let group = DisplayPlaylist.displayedGroup(
            for: Playlist(from: playlist), among: visible, preferences: mergingPreferences()
        ) else { return [] }
        return group.playlists.compactMap { storedBySourceID[$0.sourceScopedID] }
    }

    /// The visible playlist a spoken name stands for: the exact title among the playlists the screen shows, on
    /// `source` when several servers share it.
    public func visiblePlaylist(named name: String, preferringSource source: String?) async throws -> CDPlaylist? {
        let title = PlexPlaylistMergeRules.normalizedTitle(name)
        let (visible, stored) = try await visiblePlaylists()
        let matches = visible.filter { PlexPlaylistMergeRules.normalizedTitle($0.title) == title }
        return (matches.first { $0.sourceCompositeKey == source } ?? matches.first).flatMap { stored[$0.sourceScopedID] }
    }

    /// The playlist "add these tracks to `playlist`" lands on, by the Add to Playlist sheet's rule: for a merged group
    /// with merging on, the group's copy on the tracks' own server. Nil when that server has no copy in the group.
    public func addTarget(for playlist: Playlist, tracks: [Track]) async throws -> Playlist? {
        try await PlaylistActionService().addTarget(
            for: playlist,
            tracks: tracks,
            currentTrack: nil,
            among: visiblePlaylists().visible,
            preferences: mergingPreferences()
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
                sourceMatches(requestSource: request.sourceCompositeKey, candidateSource: $0.sourceCompositeKey) &&
                Self.favoritesPlaylistNames.contains(normalize($0.title) ?? "")
        }
    }

    private func playableTracksForAlbum(
        album: CDAlbum,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        guard let sourceKey = request.sourceCompositeKey ?? album.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else { return [] }
        return try await libraryRepository.fetchTracks(
            forAlbum: album.ratingKey,
            sourceCompositeKey: sourceKey
        )
            .map(Track.init(from:))
            .filter { isPlayable(track: $0, enabledSourceKeys: enabledSourceKeys) }
    }

    private func playableTracksForArtist(
        artist: CDArtist,
        request: SiriPlaybackRequest,
        enabledSourceKeys: Set<String>
    ) async throws -> [Track] {
        guard let sourceKey = request.sourceCompositeKey ?? artist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else { return [] }
        return try await libraryRepository.fetchTracks(
            forArtist: artist.ratingKey,
            sourceCompositeKey: sourceKey
        )
            .map(Track.init(from:))
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

    /// The libraries that are enabled and shown under the active visibility profile and Focus filter: the only ones a
    /// search, a saved reference or playback may read from.
    private func visibleLibrarySourceKeys() -> Set<String> {
        let isVisible = visibilityStore.playlistSourceVisibility(in: accountManager.sourceConfigurationSnapshot)
        return SystemMediaSourceScope.enabledLibraryKeys(for: accountManager.enabledSources()).filter(isVisible)
    }

    private func isPlayable(track: Track, enabledSourceKeys: Set<String>) -> Bool {
        guard let sourceCompositeKey = track.sourceCompositeKey else { return false }
        return enabledSourceKeys.contains(sourceCompositeKey) && !hiddenMediaStore.snapshot.isHidden(track)
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
        guard let identity = MediaSourceIdentity.parse(sourceCompositeKey) else { return false }
        return identity.isServerScoped && identity.sourceType.capabilities.playlistsAreServerScoped
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
        let pool = requestSource == nil ? candidates : scopedCandidates
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
