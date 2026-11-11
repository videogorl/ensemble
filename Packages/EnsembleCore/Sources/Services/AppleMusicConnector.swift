import Foundation

enum AppleMusicPlaylistItemKind: String, Sendable {
    case catalogSong = "songs"
    case librarySong = "library-songs"
}

struct AppleMusicPlaylistItemReference: Hashable, Sendable {
    let id: String
    let kind: AppleMusicPlaylistItemKind
}

enum AppleMusicPlaylistMutationPolicy {
    static let catalogLookupBatchSize = 25
    static let libraryLookupBatchSize = 100

    static func itemReferences(for tracks: [Track]) throws -> [AppleMusicPlaylistItemReference] {
        try tracks.map { track in
            if let catalogID = track.appleMusicCatalogID {
                return AppleMusicPlaylistItemReference(id: catalogID, kind: .catalogSong)
            }
            if let libraryID = track.appleMusicLibraryID {
                return AppleMusicPlaylistItemReference(id: libraryID, kind: .librarySong)
            }
            throw PlaylistMutationError.invalidSource
        }
    }

    static func itemReference(forResolvedID id: String) -> AppleMusicPlaylistItemReference {
        AppleMusicPlaylistItemReference(
            id: id,
            kind: id.allSatisfy(\.isNumber) ? .catalogSong : .librarySong
        )
    }

    static func uniqueIDs(
        in references: [AppleMusicPlaylistItemReference],
        kind: AppleMusicPlaylistItemKind
    ) -> [String] {
        var seen = Set<String>()
        return references.compactMap { reference in
            guard reference.kind == kind, seen.insert(reference.id).inserted else { return nil }
            return reference.id
        }
    }

    static func batches<T>(_ values: [T], limit: Int) -> [[T]] {
        guard limit > 0 else { return [] }
        return stride(from: 0, to: values.count, by: limit).map { start in
            Array(values[start ..< min(start + limit, values.count)])
        }
    }

    static func libraryFallbackID(
        for track: Track,
        resolvedCatalogIDs: Set<String>
    ) -> String? {
        guard let catalogID = track.appleMusicCatalogID,
              !resolvedCatalogIDs.contains(catalogID)
        else { return nil }
        return track.appleMusicLibraryID
    }

    static func orderedValues<Value>(
        for references: [AppleMusicPlaylistItemReference],
        valuesByReference: [AppleMusicPlaylistItemReference: Value]
    ) throws -> [Value] {
        let values = references.compactMap { valuesByReference[$0] }
        guard values.count == references.count else { throw PlaylistMutationError.invalidSource }
        return values
    }
}

enum AppleMusicTrackKeyPolicy {
    static func playlistTrackKey(itemID: String, isInLibrary: Bool) -> String {
        guard isInLibrary else { return "apple-catalog" }
        if !itemID.isEmpty, itemID.allSatisfy(\.isNumber) {
            return "apple-catalog-library"
        }
        return "apple-library:\(itemID)"
    }
}

struct AppleMusicLibraryRecording: Sendable {
    let isrc: String?
    let title: String
    let artistName: String
    let duration: TimeInterval?
}

enum AppleMusicLibraryAddPolicy {
    static func containsMatchingISRC(
        requested: AppleMusicLibraryRecording,
        libraryCandidates: [AppleMusicLibraryRecording]
    ) -> Bool {
        guard let requestedISRC = normalizedISRC(requested.isrc) else { return false }
        return libraryCandidates.contains {
            normalizedISRC($0.isrc) == requestedISRC
        }
    }

    static func containsEquivalentRecording(
        requested: AppleMusicLibraryRecording,
        libraryCandidates: [AppleMusicLibraryRecording]
    ) -> Bool {
        if containsMatchingISRC(requested: requested, libraryCandidates: libraryCandidates) {
            return true
        }
        if normalizedISRC(requested.isrc) != nil {
            let libraryISRCs = libraryCandidates.compactMap { normalizedISRC($0.isrc) }
            if !libraryISRCs.isEmpty { return false }
        }

        return libraryCandidates.filter { candidate in
            DisplayPlaylist.normalizedTitle(candidate.title)
                == DisplayPlaylist.normalizedTitle(requested.title)
                && DisplayPlaylist.normalizedTitle(candidate.artistName)
                == DisplayPlaylist.normalizedTitle(requested.artistName)
                && durationsMatch(candidate.duration, requested.duration)
        }.count == 1
    }

    static func canConvergeOpaqueFailure(
        domain: String,
        code: Int,
        exactCatalogIDPresent: Bool,
        requested: AppleMusicLibraryRecording,
        libraryCandidates: [AppleMusicLibraryRecording]
    ) -> Bool {
        guard domain == "MPErrorDomain", code == 0 else { return false }
        return exactCatalogIDPresent || containsEquivalentRecording(
            requested: requested,
            libraryCandidates: libraryCandidates
        )
    }

    private static func normalizedISRC(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func durationsMatch(_ first: TimeInterval?, _ second: TimeInterval?) -> Bool {
        guard let first, let second, first > 0, second > 0 else { return false }
        return abs(first - second) < 1
    }
}

#if os(iOS)
import EnsemblePersistence
import MusicKit

@available(iOS 18, *)
public actor AppleMusicConnector:
    MusicSourceConnector,
    MusicSourcePlaybackResolving,
    MusicSourceRatingMutating,
    MusicSourcePlaylistReconciling,
    MusicSourcePlaybackReporting,
    MusicSourceDetailProviding,
    MusicSourceArtistResolving
{
    public nonisolated let sourceIdentifier = MusicSourceIdentifier.appleMusic
    static let librarySongsPath = "/v1/me/library/songs?limit=100&extend=inFavorites&include=albums,artists,catalog"
    static let libraryPlaylistsPath = "/v1/me/library/playlists?limit=100&include=catalog"
    private var catalogIDsByLibraryID: [String: String] = [:]
    private var pendingFavoriteCatalogIDs = Set<String>()

    public init() {}

    public func getHomeHubs(limit: Int) async throws -> [Hub] {
        (try await getHomeHubResult(limit: limit)).hubs
    }

    public func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult {
        async let recentlyAdded = Self.availableHub(kind: .recentlyAdded, named: "Recently Added") {
            try await Self.recentlyAddedHub(limit: limit)
        }
        async let recentlyPlayed = Self.availableHub(kind: .recentlyPlayed, named: "Recently Played") {
            try await Self.recentlyPlayedHub(limit: limit)
        }
        async let mostPlayed = Self.availableHub(kind: .mostPlayed, named: "Most Played") {
            try await Self.mostPlayedHub(limit: limit)
        }
        let results = await [recentlyAdded, recentlyPlayed, mostPlayed]
        return MusicSourceHubFetchResult(
            hubs: results.compactMap(\.hub),
            failedSemanticKinds: Set(results.compactMap(\.failedKind))
        )
    }

    /// Reads the whole library; the coordinator hands the batch to `LibraryWriter`. Apple Music has no
    /// change feed, so a pass that is not due for an inventory returns an empty batch.
    public func fetchLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch {
        let fetch = try await AppleMusicLibraryFetcher(source: MusicKitLibrarySource(connector: self))
            .fetch(plan: plan, pendingFavoriteCatalogIDs: pendingFavoriteCatalogIDs)
        if let catalogIDs = fetch.catalogIDsByLibraryID {
            catalogIDsByLibraryID = catalogIDs
            pendingFavoriteCatalogIDs.subtract(fetch.confirmedFavoriteCatalogIDs)
        }
        return fetch.batch
    }

    private struct MusicKitLibrarySource: AppleMusicLibrarySource {
        let connector: AppleMusicConnector

        func isAuthorized() async -> Bool { MusicAuthorization.currentStatus == .authorized }

        func songs() async throws -> AppleMusicSongList {
            let (songs, total): ([LibrarySong], AppleMusicReportedTotal) = try await connector.fetchPages(path: AppleMusicConnector.librarySongsPath)
            return AppleMusicSongList(songs: songs, reportedTotal: total.value)
        }

        func nativeMetadata() async throws -> NativeLibraryMetadataSnapshot {
            try await AppleMusicConnector.fetchNativeLibraryMetadata()
        }
    }

    // MARK: - Playlist fetch

    /// A playlist as the last list read saw it: the REST resource, MusicKit's, or both.
    private struct ListedPlaylist {
        let rest: LibraryPlaylist?
        let native: MusicKit.Playlist?
    }

    /// The last list read, so the bodies that follow it read the playlists it found.
    private var listedPlaylists: [String: ListedPlaylist] = [:]

    /// Reads the playlist list twice, through the REST API (which reports a total) and through MusicKit.
    /// The list is complete only when `AppleMusicPlaylistInventoryProof` accepts both reads.
    public func fetchPlaylistHeaders() async throws -> PlaylistHeaderList {
        let queryStartedAt = Date()
        guard MusicAuthorization.currentStatus == .authorized else { throw AppleMusicLibraryError.notAuthorized }
        let (libraryPlaylists, restTotal): ([LibraryPlaylist], AppleMusicReportedTotal) = try await fetchPages(path: Self.libraryPlaylistsPath)
        var nativeIDs: [String] = []
        var native: [MusicKit.Playlist] = []
        var offset = 0
        while true {
            try RefreshExecution.checkCancellation()
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            request.offset = offset
            let page = Array(try await request.response().items)
            try RefreshExecution.checkCancellation()
            nativeIDs.append(contentsOf: page.map { String(describing: $0.id) })
            native.append(contentsOf: page)
            guard page.count == request.limit else { break }
            offset += page.count
        }
        guard MusicAuthorization.currentStatus == .authorized else { throw AppleMusicLibraryError.notAuthorized }

        let restByID = Dictionary(libraryPlaylists.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var listed: [String: ListedPlaylist] = [:]
        var headers: [PlaylistUpsertInput] = []
        for playlist in native {
            let id = String(describing: playlist.id)
            guard listed[id] == nil else { continue }
            let rest = restByID[id]
            listed[id] = ListedPlaylist(rest: rest, native: playlist)
            headers.append(Self.playlistInput(
                playlist,
                artworkURL: rest?.attributes.artwork?.url,
                canEdit: rest?.attributes.canEdit == true,
                dateModified: Self.effectivePlaylistModifiedDate(musicKit: playlist.lastModifiedDate, library: rest?.dateModified),
                duration: nil,
                trackCount: nil
            ))
        }
        for playlist in Self.restOnlyPlaylists(libraryPlaylists, excluding: Set(listed.keys)) {
            listed[playlist.id] = ListedPlaylist(rest: playlist, native: nil)
            headers.append(Self.playlistInput(playlist, duration: nil, trackCount: nil))
        }
        listedPlaylists = listed
        return PlaylistHeaderList(
            headers: headers,
            inventory: AppleMusicPlaylistInventoryProof.inventory(
                restIDs: libraryPlaylists.map(\.id), restTotal: restTotal.value, nativeIDs: nativeIDs
            ),
            queryStartedAt: queryStartedAt
        )
    }

    /// Reads each playlist's body: REST first, then MusicKit when REST has none (a shared playlist has
    /// no related resources). A playlist whose read fails, or whose body fails its completeness proof (REST
    /// pages that disagree with their total or with MusicKit), is left out so its stored body and date stay
    /// and the writer reports it unresolved. A failed proof never falls back to MusicKit.
    public func fetchPlaylistBodies(for headers: [PlaylistUpsertInput]) async throws -> [PlaylistEntry] {
        var entries: [PlaylistEntry] = []
        for header in headers {
            try RefreshExecution.checkCancellation()
            guard let listed = listedPlaylists[header.ratingKey] else { continue }
            do {
                let body: PlaylistBody
                if let rest = listed.rest {
                    body = try await AppleMusicPlaylistBodyProof.withNativeFallback {
                        try await restBody(rest, witness: listed.native)
                    } native: { restError in
                        guard let native = listed.native else { throw restError }
                        EnsembleLogger.info(
                            "🎵 Apple Music REST playlist body unavailable; trying MusicKit id=\(header.ratingKey) title=\(header.title) \(Self.requestErrorDetails(restError))"
                        )
                        return try await nativeBody(native)
                    }
                } else if let native = listed.native {
                    body = try await nativeBody(native)
                } else { continue }
                entries.append(PlaylistEntry(header: body.completing(header), body: body.snapshots))
            } catch {
                try RefreshExecution.checkCancellation()
                Self.logPlaylistBodyFailure(id: header.ratingKey, title: header.title, error: error)
            }
        }
        return entries
    }

    public func reconcilePlaylist(
        id: String,
        minimumTrackCount: Int,
        requiredTracks: [Track]
    ) async throws -> PlaylistBatch? {
        let queryStartedAt = Date()
        let playlist = try await libraryPlaylist(id: id)
        let body = try await nativeBody(playlist)
        guard body.snapshots.count >= minimumTrackCount,
              PlaylistActionService().tracks(requiredTracks, excluding: body.tracks).isEmpty
        else { return nil }
        let header = body.completing(Self.playlistInput(
            playlist, artworkURL: nil, canEdit: true, dateModified: playlist.lastModifiedDate, duration: nil, trackCount: nil
        ))
        return PlaylistBatch(entries: [PlaylistEntry(header: header, body: body.snapshots)], queryStartedAt: queryStartedAt)
    }

    public func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        throw AppleMusicSourceError.musicKitPlaybackRequired
    }

    public func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        guard let path else { return nil }
        let resizedPath = path.replacingOccurrences(of: "{w}", with: "\(size)")
            .replacingOccurrences(of: "{h}", with: "\(size)")
        guard let sourceURL = URL(string: resizedPath), sourceURL.scheme == "musicKit" else {
            return URL(string: resizedPath)
        }
        guard let assetPath = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "aat" })?.value else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "is1-ssl.mzstatic.com"
        components.path = "/image/thumb/\(assetPath)/\(size)x\(size)bb.jpg"
        return components.url
    }

    public func rateTrack(
        _ track: Track,
        rating: Int?
    ) async throws -> MusicSourceRatingMutationEffects {
        guard let rating, rating > 0 else { throw AppleMusicSourceError.favoriteRemovalUnsupported }
        guard let catalogID = try await catalogID(for: track) else {
            throw MusicSourceRoutingError.capabilityUnavailable(
                sourceKey: track.sourceCompositeKey ?? sourceIdentifier.compositeKey,
                capability: "favorites for this library-only song"
            )
        }
        try await favorite(catalogID: catalogID)
        return .none
    }

    private func catalogID(for track: Track) async throws -> String? {
        if let catalogID = track.appleMusicCatalogID ?? catalogIDsByLibraryID[track.id] {
            return catalogID
        }
        guard let libraryID = track.appleMusicLibraryID else { return nil }

        let response = try await request(path: try Self.librarySongPath(libraryID: libraryID))
        let catalogID = try Self.catalogID(in: response, libraryID: libraryID)
        if let catalogID {
            catalogIDsByLibraryID[libraryID] = catalogID
        }
        return catalogID
    }

    static func librarySongPath(libraryID: String) throws -> String {
        var components = URLComponents()
        components.path = "/v1/me/library/songs/\(libraryID)"
        components.queryItems = [URLQueryItem(name: "include", value: "catalog")]
        guard let path = components.string else { throw URLError(.badURL) }
        return path
    }

    static func catalogID(in librarySongResponse: Data, libraryID: String) throws -> String? {
        try JSONDecoder().decode(Page<LibrarySong>.self, from: librarySongResponse)
            .data.first(where: { $0.id == libraryID })?.catalogID
    }

    public func favorite(catalogID: String) async throws {
        _ = try await request(path: try Self.favoritePath(catalogID: catalogID), method: "POST")
        pendingFavoriteCatalogIDs.insert(catalogID)
    }

    static func favoritePath(catalogID: String) throws -> String {
        var components = URLComponents()
        components.path = "/v1/me/favorites"
        components.queryItems = [URLQueryItem(name: "ids[songs]", value: catalogID)]
        guard let path = components.string else { throw URLError(.badURL) }
        return path
    }

    static func continuationPath(_ next: String, preservingQueryFrom initial: String) -> String {
        guard var components = URLComponents(string: next),
              let initialItems = URLComponents(string: initial)?.queryItems else { return next }
        let existingNames = Set((components.queryItems ?? []).map(\.name))
        components.queryItems = (components.queryItems ?? []) + initialItems.filter { !existingNames.contains($0.name) }
        return components.string ?? next
    }

    public func addToLibrary(catalogID: String) async throws -> MusicSourceLibraryAddOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        EnsembleLogger.info("Apple Music library mutation started operation=add catalogID=\(catalogID)")

        do {
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(catalogID)
            )
            guard let song = try await request.response().items.first else {
                throw AppleMusicSourceError.catalogSongNotFound
            }

            let outcome = try await addToLibrary(song)
            EnsembleLogger.info(
                "Apple Music library mutation accepted operation=add catalogID=\(catalogID) outcome=\(outcome) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
            )
            return outcome
        } catch {
            let nsError = error as NSError
            EnsembleLogger.error(
                "Apple Music library mutation failed operation=add catalogID=\(catalogID) domain=\(nsError.domain) code=\(nsError.code) authorization=\(MusicAuthorization.currentStatus.rawValue) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
            )
            throw error
        }
    }

    private func addToLibrary(_ song: Song) async throws
        -> MusicSourceLibraryAddOutcome
    {
        if song.libraryAddedDate != nil {
            EnsembleLogger.info(
                "Apple Music library mutation converged operation=add catalogID=\(song.id.rawValue) evidence=libraryAddedDate"
            )
            return .alreadyPresent
        }

        let requested = AppleMusicLibraryRecording(
            isrc: song.isrc,
            title: song.title,
            artistName: song.artistName,
            duration: song.duration
        )
        let initialCandidates = (try? await Self.libraryRecordings(titled: song.title)) ?? []
        if AppleMusicLibraryAddPolicy.containsMatchingISRC(
            requested: requested,
            libraryCandidates: initialCandidates
        ) {
            EnsembleLogger.info(
                "Apple Music library mutation converged operation=add catalogID=\(song.id.rawValue) evidence=preflightISRC"
            )
            return .alreadyPresent
        }

        do {
            try await MusicLibrary.shared.add(song)
            return .added
        } catch let error as MusicLibrary.Error where error == .itemAlreadyAdded {
            EnsembleLogger.info(
                "Apple Music library mutation converged operation=add catalogID=\(song.id.rawValue) evidence=documentedAlreadyAdded"
            )
            return .alreadyPresent
        } catch {
            let nsError = error as NSError
            guard nsError.domain == "MPErrorDomain", nsError.code == 0 else { throw error }
            let exactCatalogIDPresent = (try? await catalogSongIsInLibrary(
                catalogID: song.id.rawValue
            )) == true
            let candidates = exactCatalogIDPresent
                ? []
                : (try? await Self.libraryRecordings(titled: song.title)) ?? []
            guard AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
                domain: nsError.domain,
                code: nsError.code,
                exactCatalogIDPresent: exactCatalogIDPresent,
                requested: requested,
                libraryCandidates: candidates
            ) else { throw error }
            let evidence: String
            if exactCatalogIDPresent {
                evidence = "postFailureCatalogID"
            } else if AppleMusicLibraryAddPolicy.containsMatchingISRC(
                requested: requested,
                libraryCandidates: candidates
            ) {
                evidence = "postFailureISRC"
            } else {
                evidence = "postFailureMetadata"
            }
            EnsembleLogger.info(
                "Apple Music library mutation converged operation=add catalogID=\(song.id.rawValue) evidence=\(evidence)"
            )
            return .alreadyPresent
        }
    }

    private func catalogSongIsInLibrary(catalogID: String) async throws -> Bool {
        let storefront = try await MusicDataRequest.currentCountryCode
        let encodedID = catalogID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? catalogID
        let response = try JSONDecoder().decode(
            Page<LibrarySong.LibraryReference>.self,
            from: try await request(
                path: "/v1/catalog/\(storefront.lowercased())/songs/\(encodedID)/library"
            )
        )
        return !response.data.isEmpty
    }

    private nonisolated static func libraryRecordings(titled title: String) async throws
        -> [AppleMusicLibraryRecording]
    {
        var recordings: [AppleMusicLibraryRecording] = []
        var offset = 0
        while true {
            var request = MusicLibraryRequest<Song>()
            request.limit = 100
            request.offset = offset
            request.filter(matching: \.title, equalTo: title)
            let songs = Array(try await request.response().items)
            recordings.append(contentsOf: songs.map {
                AppleMusicLibraryRecording(
                    isrc: $0.isrc,
                    title: $0.title,
                    artistName: $0.artistName,
                    duration: $0.duration
                )
            })
            guard songs.count == request.limit else { return recordings }
            offset += songs.count
        }
    }

    public func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
        let songs = try await playlistSongs(for: tracks)
        let playlist = try await MusicLibrary.shared.createPlaylist(name: title, items: songs)
        let playlistID = String(describing: playlist.id)
        Playlist.markAppleMusicPlaylistCreated(id: playlistID)
        return Playlist(
            id: playlistID,
            key: playlistID,
            title: title,
            trackCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.duration },
            // The date MusicKit returned, so the next read of an unchanged playlist keeps this row's body.
            dateModified: playlist.lastModifiedDate,
            sourceCompositeKey: sourceIdentifier.compositeKey,
            actionCapabilities: Self.playlistActionCapabilities(
                id: playlistID,
                isSmart: false,
                canEdit: true
            )
        )
    }

    public func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
        let references = try await playlistSongs(for: tracks).map {
            AppleMusicPlaylistMutationPolicy.itemReference(forResolvedID: String(describing: $0.id))
        }
        guard !references.isEmpty else { return 0 }
        let encodedID = playlistID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistID
        _ = try await request(
            path: "/v1/me/library/playlists/\(encodedID)/tracks",
            method: "POST",
            body: ["data": references.map { ["id": $0.id, "type": $0.kind.rawValue] }]
        )
        return references.count
    }

    public func renamePlaylist(_ playlistID: String, title: String) async throws {
        _ = try await MusicLibrary.shared.edit(try await libraryPlaylist(id: playlistID), name: title)
    }

    public func deletePlaylist(_ playlistID: String) async throws {
        throw AppleMusicSourceError.playlistDeletionUnsupported
    }

    public func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
        let playlist = try await libraryPlaylist(id: playlistID)
        let songs = try await playlistSongs(for: tracks)
        _ = try await MusicLibrary.shared.edit(playlist, items: songs)
    }

    public func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
    public func scrobble(ratingKey: String) async throws {}
    public func getAlbumTracks(albumKey: String) async throws -> [Track] {
        var libraryRequest = MusicLibraryRequest<MusicKit.Album>()
        libraryRequest.filter(matching: \.id, equalTo: MusicItemID(albumKey))
        if let libraryAlbum = try await libraryRequest.response().items.first {
            let detailed = try await libraryAlbum.with([.tracks])
            return detailed.tracks?.compactMap { item in
                guard case .song(let song) = item else { return nil }
                return Self.domainTrack(song, key: Self.playlistTrackKey(song))
            } ?? []
        }

        var request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(albumKey))
        request.properties = [.tracks]
        guard let album = try await request.response().items.first else { return [] }
        return album.tracks?.compactMap { item in
            guard case .song(let song) = item else { return nil }
            return Self.domainTrack(song, key: Self.catalogTrackKey(song))
        } ?? []
    }

    public func getArtist(artistKey: String?, name: String?) async throws -> Artist? {
        let artist: MusicKit.Artist?
        if let artistKey, !artistKey.hasPrefix("apple-artist:") {
            let request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(artistKey))
            artist = try await AppleMusicCatalogRequestBoundary.run(timeoutNanoseconds: 15_000_000_000) {
                try await request.response().items.first
            }
        } else if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var request = MusicCatalogSearchRequest(term: name, types: [MusicKit.Artist.self])
            request.limit = 25
            let configuredRequest = request
            let response = try await AppleMusicCatalogRequestBoundary.run(timeoutNanoseconds: 15_000_000_000) {
                try await configuredRequest.response()
            }
            artist = response.artists.first { DisplayArtist.normalizedName($0.name) == DisplayArtist.normalizedName(name) }
        } else {
            return nil
        }
        return artist.map {
            Artist(
                id: $0.id.rawValue,
                key: "apple-catalog",
                name: $0.name,
                thumbPath: $0.artwork?.ensembleResolvableURL(),
                sourceCompositeKey: sourceIdentifier.compositeKey
            )
        }
    }

    public func getArtistAlbums(artistKey: String) async throws -> [Album] {
        if artistKey.hasPrefix("apple-artist:") {
            return []
        }

        var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(artistKey))
        request.properties = [.albums]
        guard let artist = try await request.response().items.first else { return [] }
        var albums = artist.albums ?? []
        while albums.hasNextBatch, let next = try await albums.nextBatch(limit: 100) {
            albums += next
        }
        return albums.map { Self.domainAlbum($0, artistID: artistKey) }
    }

    public func getArtistTracks(artistKey: String) async throws -> [Track] {
        let albums = try await getArtistAlbums(artistKey: artistKey)
        var tracks: [Track] = []
        for album in albums.prefix(20) {
            tracks.append(contentsOf: try await getAlbumTracks(albumKey: album.id))
        }
        return tracks
    }

    public func getCatalogPlaylistTracks(playlistID: String) async throws -> [Track] {
        var request = MusicCatalogResourceRequest<MusicKit.Playlist>(
            matching: \.id,
            equalTo: MusicItemID(playlistID)
        )
        request.properties = [.tracks]
        guard let playlist = try await request.response().items.first else { return [] }
        return playlist.tracks?.compactMap { item in
            guard case .song(let song) = item else { return nil }
            return Self.domainTrack(song, key: Self.catalogTrackKey(song))
        } ?? []
    }

    /// Follows the `next` chain to its end. Any failed page throws, so a result is every page of the
    /// chain; `total` is the API's own count from the first page, when it reports one and no page contradicts it.
    private func fetchPages<Resource: Decodable>(path: String) async throws -> (items: [Resource], total: AppleMusicReportedTotal) {
        let initialPath = path
        var path: String? = path
        var result: [Resource] = []
        var tally = AppleMusicPageTally()
        var fetchedPaths = Set<String>()
        while let current = path {
            try RefreshExecution.checkCancellation()
            guard fetchedPaths.insert(current).inserted else {
                throw AppleMusicSourceError.repeatedPaginationCursor
            }
            let data: Data
            do {
                data = try await request(path: current)
            } catch {
                Self.logDataRequestFailure(path: current, error: error)
                throw error
            }
            let page = try JSONDecoder().decode(Page<Resource>.self, from: data)
            tally.add(itemCount: page.data.count, total: page.meta?.total, hasNext: page.next != nil)
            result.append(contentsOf: page.data)
            path = page.next.map { Self.continuationPath($0, preservingQueryFrom: initialPath) }
        }
        return (result, tally.total)
    }

    private nonisolated static func fetchNativeLibraryMetadata() async throws
        -> NativeLibraryMetadataSnapshot
    {
        let startedAt = Date()
        let songs = try await fetchNativeLibraryItems(Song.self) {
            NativeLibrarySongMetadata(
                itemID: $0.id.rawValue,
                dateAdded: $0.libraryAddedDate,
                lastPlayed: $0.lastPlayedDate,
                playCount: $0.playCount
            )
        }
        return NativeLibraryMetadataSnapshot(
            songs: songs,
            albums: [],
            artists: [],
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        )
    }

    private nonisolated static func fetchNativeLibraryItems<Item, Output>(
        _: Item.Type,
        transform: @Sendable (Item) -> Output
    ) async throws -> [Output]
    where Item: MusicLibraryRequestable, Output: Sendable {
        var result: [Output] = []
        var seenIDs = Set<MusicItemID>()
        var offset = 0
        while true {
            try RefreshExecution.checkCancellation()
            var request = MusicLibraryRequest<Item>()
            request.limit = 100
            request.offset = offset
            let page = Array(try await request.response().items)
            result.append(contentsOf: page.compactMap {
                seenIDs.insert($0.id).inserted ? transform($0) : nil
            })
            guard page.count == request.limit else { break }
            offset += page.count
        }
        return result
    }

    private static func logPlaylistBodyFailure(id: String, title: String, error: Error) {
        EnsembleLogger.error(
            "🎵 Apple Music playlist body failed id=\(id) title=\(title) \(requestErrorDetails(error))"
        )
    }

    private static func logDataRequestFailure(path: String, error: Error) {
        EnsembleLogger.error(
            "🎵 Apple Music data request failed path=\(path) \(requestErrorDetails(error))"
        )
    }

    private static func requestErrorDetails(_ error: Error) -> String {
        guard let requestError = error as? MusicDataRequest.Error else {
            return "type=\(String(reflecting: type(of: error))) message=\(error.localizedDescription)"
        }
        return "status=\(requestError.status) code=\(requestError.code) responseStatus=\(requestError.originalResponse.urlResponse.statusCode) title=\(requestError.title) detail=\(requestError.detailText) source=\(String(describing: requestError.source))"
    }

    private static func domainTrack(_ song: Song, key: String) -> Track {
        Track(
            id: String(describing: song.id),
            key: key,
            title: song.title,
            artistName: song.artistName,
            albumArtistName: song.artistName,
            albumName: song.albumTitle,
            artistRatingKey: song.artistURL?.lastPathComponent,
            trackNumber: song.trackNumber ?? 0,
            discNumber: song.discNumber ?? 1,
            duration: song.duration ?? 0,
            thumbPath: song.artwork?.ensembleResolvableURL(),
            streamKey: song.url?.absoluteString,
            genres: song.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
    }

    private nonisolated static func recentlyAddedHub(limit: Int) async throws -> Hub? {
        var request = MusicLibraryRequest<MusicKit.Album>()
        request.limit = limit
        request.sort(by: \.libraryAddedDate, ascending: false)
        let items = try await request.response().items.map { album in
            let domain = domainAlbum(album)
            return HubItem(
                id: domain.id,
                type: "album",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: domain.year,
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                addedAt: album.libraryAddedDate,
                album: domain
            )
        }
        return hub(id: "music.recent.added", title: "Recently Added", type: "album", items: Array(items))
    }

    private nonisolated static func recentlyPlayedHub(limit: Int) async throws -> Hub? {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = min(limit, 30)
        let items = try await request.response().items.map { song in
            let domain = domainTrack(song, key: catalogTrackKey(song))
            return HubItem(
                id: domain.id,
                type: "track",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                lastViewedAt: song.lastPlayedDate,
                track: domain
            )
        }
        return hub(id: "music.recent.played", title: "Recently Played Music", type: "track", items: Array(items))
    }

    private nonisolated static func mostPlayedHub(limit: Int) async throws -> Hub? {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.sort(by: \.playCount, ascending: false)
        let items = try await request.response().items.compactMap { song -> HubItem? in
            guard let playCount = song.playCount, playCount > 0 else { return nil }
            let domain = domainTrack(song, key: libraryTrackKey(song))
            return HubItem(
                id: domain.id,
                type: "track",
                title: domain.title,
                subtitle: domain.artistName,
                thumbPath: domain.thumbPath,
                year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                lastViewedAt: song.lastPlayedDate,
                viewCount: playCount,
                track: domain
            )
        }
        return hub(id: "music.popular", title: "Most Played", type: "track", items: Array(items))
    }

    nonisolated static func availableHub(
        kind: HubSemanticKind,
        named name: String,
        operation: @Sendable () async throws -> Hub?
    ) async -> (hub: Hub?, failedKind: HubSemanticKind?) {
        do {
            return (try await operation(), nil)
        } catch {
            EnsembleLogger.debug("🎵 Apple Music \(name) hub fetch failed: \(error.localizedDescription)")
            return (nil, kind)
        }
    }

    private nonisolated static func hub(
        id: String,
        title: String,
        type: String,
        items: [HubItem]
    ) -> Hub? {
        guard !items.isEmpty else { return nil }
        return Hub(
            id: "\(MusicSourceIdentifier.appleMusic.compositeKey):\(id)",
            title: title,
            type: type,
            items: items,
            semanticKind: HubSemanticKind.provider(identifier: id, title: title),
            sourceScope: HubSourceScope(source: .appleMusic)
        )
    }

    private static func catalogTrackKey(_ song: Song) -> String {
        song.libraryAddedDate == nil ? "apple-catalog" : "apple-catalog-library"
    }

    private static func libraryTrackKey(_ song: Song) -> String {
        "apple-library:\(song.id)"
    }

    private static func playlistTrackKey(_ song: Song) -> String {
        AppleMusicTrackKeyPolicy.playlistTrackKey(
            itemID: String(describing: song.id),
            isInLibrary: song.libraryAddedDate != nil
        )
    }

    private static func domainAlbum(_ album: MusicKit.Album, artistID: String? = nil) -> Album {
        Album(
            id: String(describing: album.id),
            key: "apple-catalog",
            title: album.title,
            artistName: album.artistName,
            albumArtist: album.artistName,
            artistRatingKey: artistID ?? album.artistURL?.lastPathComponent,
            year: album.releaseDate.map { Calendar.current.component(.year, from: $0) },
            trackCount: album.trackCount,
            thumbPath: album.artwork?.ensembleResolvableURL(),
            genres: album.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            releaseFormat: album.isSingle == true ? .single : .album
        )
    }

    private static func isSmartPlaylist(_ kind: MusicKit.Playlist.Kind?, canEdit: Bool) -> Bool {
        guard !canEdit else { return false }
        return switch kind {
        case .editorial, .external, .personalMix, .replay:
            true
        case .userShared, nil:
            false
        @unknown default:
            true
        }
    }

    static func restOnlyPlaylists(
        _ libraryPlaylists: [LibraryPlaylist],
        excluding musicKitIDs: Set<String>
    ) -> [LibraryPlaylist] {
        var seen = musicKitIDs
        return libraryPlaylists.filter { seen.insert($0.id).inserted }
    }

    private static func isSmartPlaylist(_ playlist: LibraryPlaylist) -> Bool {
        guard playlist.attributes.canEdit != true else { return false }
        switch playlist.catalogPlaylistType {
        case "user-shared":
            return false
        case "editorial", "external", "personal-mix", "replay":
            return true
        default:
            return playlist.attributes.playParams?.globalId?.hasPrefix("pl.u-") != true
        }
    }

    static func effectivePlaylistModifiedDate(musicKit: Date?, library: Date?) -> Date? {
        [musicKit, library].compactMap { $0 }.max()
    }

    private static func playlistInput(
        _ playlist: MusicKit.Playlist,
        artworkURL: String?,
        canEdit: Bool,
        dateModified: Date?,
        duration: Int?,
        trackCount: Int?
    ) -> PlaylistUpsertInput {
        let isSmart = isSmartPlaylist(playlist.kind, canEdit: canEdit)
        let capabilities = playlistActionCapabilities(
            id: String(describing: playlist.id),
            isSmart: isSmart,
            canEdit: canEdit
        )
        return PlaylistUpsertInput(
            ratingKey: String(describing: playlist.id),
            key: String(describing: playlist.id),
            title: playlist.name,
            summary: playlist.standardDescription,
            compositePath: artworkURL ?? playlist.artwork?.ensembleResolvableURL(),
            isSmart: isSmart,
            duration: duration,
            trackCount: trackCount,
            dateAdded: playlist.libraryAddedDate,
            dateModified: dateModified,
            lastPlayed: playlist.lastPlayedDate,
            actionCapabilities: capabilities
        )
    }

    static func playlistInput(
        _ playlist: LibraryPlaylist,
        duration: Int?,
        trackCount: Int?
    ) -> PlaylistUpsertInput {
        let isSmart = isSmartPlaylist(playlist)
        let canEdit = playlist.attributes.canEdit == true
        let title = playlist.attributes.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Playlist"
        let summary = [
            playlist.attributes.description?.standard,
            playlist.attributes.description?.short
        ].compactMap { $0 }.first { !$0.isEmpty }
        return PlaylistUpsertInput(
            ratingKey: playlist.id,
            key: playlist.id,
            title: title,
            summary: summary,
            compositePath: playlist.attributes.artwork?.url,
            isSmart: isSmart,
            duration: duration,
            trackCount: trackCount,
            dateAdded: playlist.dateAdded,
            dateModified: playlist.dateModified,
            lastPlayed: nil,
            actionCapabilities: playlistActionCapabilities(
                id: playlist.id,
                isSmart: isSmart,
                canEdit: canEdit
            )
        )
    }

    static func playlistActionCapabilities(
        id: String,
        isSmart: Bool,
        canEdit: Bool
    ) -> PlaylistActionCapabilities {
        let createdByEnsemble = Playlist.appleMusicPlaylistWasCreatedByEnsemble(id)
        let unavailableReason: String? = if isSmart {
            "Smart playlists are read-only."
        } else if canEdit, !createdByEnsemble {
            "Songs can be added, but Apple only lets Ensemble reorder or rename playlists Ensemble created."
        } else if !canEdit {
            "This Apple Music playlist is read-only."
        } else {
            nil
        }
        return PlaylistActionCapabilities(
            canAddItems: canEdit && !isSmart,
            canRename: canEdit && createdByEnsemble && !isSmart,
            canReorder: canEdit && createdByEnsemble && !isSmart,
            canDelete: false,
            unavailableReason: unavailableReason
        )
    }

    private func playlistSongs(for tracks: [Track]) async throws -> [Song] {
        let references = try AppleMusicPlaylistMutationPolicy.itemReferences(for: tracks)
        var songsByReference: [AppleMusicPlaylistItemReference: Song] = [:]

        let catalogIDs = AppleMusicPlaylistMutationPolicy.uniqueIDs(in: references, kind: .catalogSong)
        for batch in AppleMusicPlaylistMutationPolicy.batches(
            catalogIDs,
            limit: AppleMusicPlaylistMutationPolicy.catalogLookupBatchSize
        ) {
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                memberOf: batch.map { MusicItemID($0) }
            )
            request.limit = batch.count
            for song in try await request.response().items {
                let reference = AppleMusicPlaylistItemReference(
                    id: String(describing: song.id),
                    kind: .catalogSong
                )
                songsByReference[reference] = song
            }
        }

        var fallbackCatalogReferencesByLibraryID: [String: Set<AppleMusicPlaylistItemReference>] = [:]
        let resolvedCatalogIDs = Set(songsByReference.keys.compactMap { reference in
            reference.kind == .catalogSong ? reference.id : nil
        })
        for (track, reference) in zip(tracks, references) {
            guard let libraryID = AppleMusicPlaylistMutationPolicy.libraryFallbackID(
                for: track,
                resolvedCatalogIDs: resolvedCatalogIDs
            ) else { continue }
            fallbackCatalogReferencesByLibraryID[libraryID, default: []].insert(reference)
        }

        var libraryIDs = AppleMusicPlaylistMutationPolicy.uniqueIDs(in: references, kind: .librarySong)
        libraryIDs.append(contentsOf: fallbackCatalogReferencesByLibraryID.keys.filter { !libraryIDs.contains($0) })
        for batch in AppleMusicPlaylistMutationPolicy.batches(
            libraryIDs,
            limit: AppleMusicPlaylistMutationPolicy.libraryLookupBatchSize
        ) {
            var request = MusicLibraryRequest<Song>()
            request.limit = batch.count
            request.filter(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            for song in try await request.response().items {
                let reference = AppleMusicPlaylistItemReference(
                    id: String(describing: song.id),
                    kind: .librarySong
                )
                songsByReference[reference] = song
                for catalogReference in fallbackCatalogReferencesByLibraryID[reference.id] ?? [] {
                    songsByReference[catalogReference] = song
                }
            }
        }

        return try AppleMusicPlaylistMutationPolicy.orderedValues(
            for: references,
            valuesByReference: songsByReference
        )
    }

    private func libraryPlaylist(id: String) async throws -> MusicKit.Playlist {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else {
            throw AppleMusicSourceError.playlistNotFound
        }
        return playlist
    }

    /// One playlist's complete body. `durationMillis` and the song count complete a header that could not
    /// state them.
    private struct PlaylistBody {
        let snapshots: [PlaylistTrackSnapshot]
        let durationMillis: Int
        /// Tracks as the playlist lists them; used to check a mutation's result.
        let tracks: [Track]

        func completing(_ header: PlaylistUpsertInput) -> PlaylistUpsertInput {
            header.replacing(duration: durationMillis, trackCount: snapshots.count)
        }
    }

    /// MusicKit's read of a playlist's songs. Throws `Unproven` unless the whole read arrived:
    /// a playlist whose tracks did not load, or whose further batches did, is not an empty playlist.
    private func nativeBody(_ playlist: MusicKit.Playlist) async throws -> PlaylistBody {
        let sourceKey = sourceIdentifier.compositeKey
        let detailed = try await playlist.with([.tracks])
        var musicTracks = detailed.tracks ?? []
        guard try await AppleMusicPlaylistBodyProof.isCompleteNativeRead(
            tracksLoaded: detailed.tracks != nil,
            hasNextBatch: { musicTracks.hasNextBatch },
            loadNextBatch: {
                guard let next = try await musicTracks.nextBatch(limit: 100), !next.isEmpty else { return false }
                musicTracks += next
                return true
            }
        ) else { throw AppleMusicPlaylistBodyProof.Unproven() }
        let songs = musicTracks.compactMap { track -> Song? in
            guard case .song(let song) = track else { return nil }
            return song
        }
        return PlaylistBody(
            snapshots: songs.map {
                PlaylistTrackSnapshot(
                    ratingKey: String(describing: $0.id),
                    key: Self.playlistTrackKey($0),
                    title: $0.title,
                    artistName: $0.artistName,
                    albumName: $0.albumTitle,
                    duration: $0.duration ?? 0,
                    thumbPath: $0.artwork?.ensembleResolvableURL(),
                    sourceCompositeKey: sourceKey
                )
            },
            durationMillis: Int(songs.reduce(0) { $0 + ($1.duration ?? 0) } * 1000),
            tracks: songs.map { Self.domainTrack($0, key: Self.playlistTrackKey($0)) }
        )
    }

    /// Reads every page of the playlist's tracks. `AppleMusicPlaylistBodyProof` decides whether they are
    /// the whole playlist: a total that disagrees, or pages that contradict each other, throw
    /// `Unproven` (withheld, not retried through MusicKit); with no total, MusicKit's read of the playlist (`witness`) must agree on the song count.
    private func restBody(_ playlist: LibraryPlaylist, witness: MusicKit.Playlist?) async throws -> PlaylistBody {
        let sourceKey = sourceIdentifier.compositeKey
        let encodedID = playlist.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlist.id
        let (fetched, total): ([LibrarySong], AppleMusicReportedTotal) = try await fetchPages(
            path: "/v1/me/library/playlists/\(encodedID)/tracks?limit=100&include=catalog"
        )
        let songs = fetched.filter(\.isSong)
        try await AppleMusicPlaylistBodyProof.verifyREST(
            itemCount: fetched.count, songCount: songs.count, total: total,
            witnessSongCount: {
                guard let witness else { return nil }
                return try await self.nativeBody(witness).snapshots.count
            }
        )
        return PlaylistBody(
            snapshots: songs.map {
                PlaylistTrackSnapshot(
                    ratingKey: $0.id,
                    key: $0.trackKey,
                    title: $0.attributes.name,
                    artistName: $0.attributes.artistName,
                    albumName: $0.attributes.albumName,
                    duration: TimeInterval($0.attributes.durationInMillis ?? 0) / 1000,
                    thumbPath: $0.artworkURL,
                    sourceCompositeKey: sourceKey
                )
            },
            durationMillis: songs.reduce(0) { $0 + ($1.attributes.durationInMillis ?? 0) },
            tracks: []
        )
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let url = path.hasPrefix("http") ? URL(string: path) : URL(string: "https://api.music.apple.com\(path)")
        guard let url else { throw URLError(.badURL) }
        try RefreshExecution.checkCancellation()
        var request = URLRequest(url: url)
        if let remaining = RefreshExecution.remainingTime {
            request.timeoutInterval = max(0.1, min(request.timeoutInterval, remaining))
        }
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await MusicDataRequest(urlRequest: request).response()
        try RefreshExecution.checkCancellation()
        guard (200..<300).contains(response.urlResponse.statusCode) else {
            throw AppleMusicSourceError.http(response.urlResponse.statusCode)
        }
        return response.data
    }
}

@available(iOS 18, *)
struct LibraryPlaylist: Decodable {
    struct DescriptionAttribute: Decodable {
        let standard: String?
        let short: String?
    }

    struct PlayParameters: Decodable {
        let globalId: String?
    }

    struct Attributes: Decodable {
        let canEdit: Bool?
        let artwork: Artwork?
        let name: String?
        let description: DescriptionAttribute?
        let dateAdded: String?
        let lastModifiedDate: String?
        let hasCatalog: Bool?
        let playParams: PlayParameters?
    }

    struct Relationships: Decodable {
        let catalog: Page<CatalogPlaylist>?
    }

    struct CatalogPlaylist: Decodable {
        struct Attributes: Decodable {
            let playlistType: String?
        }

        let attributes: Attributes?
    }

    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    var dateAdded: Date? { attributes.dateAdded.flatMap(Self.date) }
    var dateModified: Date? { attributes.lastModifiedDate.flatMap(Self.date) }
    var catalogPlaylistType: String? { relationships?.catalog?.data.first?.attributes?.playlistType }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value) ?? DateFormatter.appleMusicDay.date(from: value)
    }
}

public enum AppleMusicSourceError: LocalizedError {
    case musicKitPlaybackRequired
    case favoriteRemovalUnsupported
    case playlistDeletionUnsupported
    case playlistNotFound
    case catalogSongNotFound
    case repeatedPaginationCursor
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .musicKitPlaybackRequired: "Apple Music tracks must be played by MusicKit."
        case .favoriteRemovalUnsupported: "Removing Apple Music favorites is unavailable on this device."
        case .playlistDeletionUnsupported: "Delete this Apple Music playlist in the Music app."
        case .playlistNotFound: "The Apple Music playlist could not be found."
        case .catalogSongNotFound: "The Apple Music song could not be found."
        case .repeatedPaginationCursor: "Apple Music returned a repeated library page. Please try again."
        case .http(let status): "Apple Music returned HTTP \(status)."
        }
    }
}
#endif
