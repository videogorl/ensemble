import EnsembleAPI
import EnsembleDomain
import Foundation

public enum EnsemblePlexError: Error, LocalizedError, Equatable {
    case noSyncedCredentials
    case noReachableServer
    case noSelectedLibraries
    case unsupportedStreamResolution

    public var errorDescription: String? {
        switch self {
        case .noSyncedCredentials:
            return "No synced Plex credentials were found."
        case .noReachableServer:
            return "No reachable Plex server was found."
        case .noSelectedLibraries:
            return "No selected music libraries were found."
        case .unsupportedStreamResolution:
            return "This stream format is not supported by the watch player yet."
        }
    }
}

public struct EnsemblePlexPlaylistTarget: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sourceKey: String
    public let isSmart: Bool
    public let updatedAt: Int?

    public init(id: String, title: String, sourceKey: String, isSmart: Bool, updatedAt: Int? = nil) {
        self.id = id
        self.title = title
        self.sourceKey = sourceKey
        self.isSmart = isSmart
        self.updatedAt = updatedAt
    }
}

public enum EnsemblePlexPlaylistMutationError: Error, LocalizedError, Equatable {
    case noCompatibleSource
    case smartPlaylistReadOnly
    case emptySelection
    case invalidTitle
    case createdPlaylistUnavailable

    public var errorDescription: String? {
        switch self {
        case .noCompatibleSource: return "No matching Plex source is available."
        case .smartPlaylistReadOnly: return "Smart playlists are read-only."
        case .emptySelection: return "Select at least one track."
        case .invalidTitle: return "Enter a playlist name."
        case .createdPlaylistUnavailable: return "The new playlist could not be found."
        }
    }
}

public struct EnsemblePlexServer: Equatable, Sendable, Identifiable {
    public let account: EnsembleAccountCredential
    public let id: String
    public let name: String
    public let token: String
    public let url: String
    public let connections: [PlexConnection]
    public let libraries: [EnsembleLibraryReference]

    public init(
        account: EnsembleAccountCredential,
        id: String,
        name: String,
        token: String,
        url: String,
        connections: [PlexConnection],
        libraries: [EnsembleLibraryReference]
    ) {
        self.account = account
        self.id = id
        self.name = name
        self.token = token
        self.url = url
        self.connections = connections
        self.libraries = libraries
    }

    public var sourceKey: String {
        EnsemblePlexSourceKey.buildServer(accountId: account.accountId, serverId: id)
    }

    public static func == (lhs: EnsemblePlexServer, rhs: EnsemblePlexServer) -> Bool {
        lhs.account == rhs.account
            && lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.token == rhs.token
            && lhs.url == rhs.url
            && lhs.libraries == rhs.libraries
    }
}

public struct EnsemblePlexLibrary: Equatable, Sendable, Identifiable {
    public let server: EnsemblePlexServer
    public let id: String
    public let key: String
    public let title: String

    public init(server: EnsemblePlexServer, id: String, key: String, title: String) {
        self.server = server
        self.id = id
        self.key = key
        self.title = title
    }

    public var sourceKey: String {
        EnsemblePlexSourceKey.build(
            accountId: server.account.accountId,
            serverId: server.id,
            libraryKey: key
        )
    }
}

public enum EnsemblePlexSourceKey {
    public static func buildServer(accountId: String, serverId: String) -> String {
        PlexSourceIdentity(type: "plex", accountId: accountId, serverId: serverId).serverSourceKey
    }

    public static func build(accountId: String, serverId: String, libraryKey: String) -> String {
        "\(buildServer(accountId: accountId, serverId: serverId)):\(libraryKey)"
    }
}

public struct EnsemblePlexCatalogSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let libraries: [EnsembleLibraryReference]
    public let pins: [EnsembleMediaSummary]
    public let albums: [EnsembleMediaSummary]
    public let artists: [EnsembleMediaSummary]
    public let playlists: [EnsembleMediaSummary]
    public let recentlyAdded: [EnsembleMediaSummary]
    public let tracks: [EnsembleTrack]
    public let genres: [EnsembleGenreSummary]

    private enum CodingKeys: String, CodingKey {
        case fetchedAt, libraries, pins, albums, artists, playlists, recentlyAdded, tracks, genres
    }

    public init(
        fetchedAt: Date = Date(),
        libraries: [EnsembleLibraryReference],
        pins: [EnsembleMediaSummary],
        albums: [EnsembleMediaSummary],
        artists: [EnsembleMediaSummary],
        playlists: [EnsembleMediaSummary],
        recentlyAdded: [EnsembleMediaSummary],
        tracks: [EnsembleTrack] = [],
        genres: [EnsembleGenreSummary] = []
    ) {
        self.fetchedAt = fetchedAt
        self.libraries = libraries
        self.pins = pins
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.recentlyAdded = recentlyAdded
        self.tracks = tracks
        self.genres = genres
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        libraries = try container.decode([EnsembleLibraryReference].self, forKey: .libraries)
        pins = try container.decode([EnsembleMediaSummary].self, forKey: .pins)
        albums = try container.decode([EnsembleMediaSummary].self, forKey: .albums)
        artists = try container.decode([EnsembleMediaSummary].self, forKey: .artists)
        playlists = try container.decode([EnsembleMediaSummary].self, forKey: .playlists)
        recentlyAdded = try container.decode([EnsembleMediaSummary].self, forKey: .recentlyAdded)
        tracks = try container.decodeIfPresent([EnsembleTrack].self, forKey: .tracks) ?? []
        genres = try container.decodeIfPresent([EnsembleGenreSummary].self, forKey: .genres) ?? []
    }
}

public struct EnsemblePlexCatalogLimits: Equatable, Sendable {
    public let recentlyAdded: Int

    public init(recentlyAdded: Int = 24) {
        self.recentlyAdded = recentlyAdded
    }
}

/// Discovers account/server/library state from either iCloud Keychain hints or
/// a fresh Plex Link token.
public actor EnsemblePlexDiscoveryService {
    private let keychain: KeychainServiceProtocol

    public init(keychain: KeychainServiceProtocol = KeychainService.shared) {
        self.keychain = keychain
    }

    public func loadSyncedCredentials() throws -> [EnsembleAccountCredential] {
        guard let dataString = try keychain.getSynchronizable(KeychainKey.plexAccountsSync),
              let data = dataString.data(using: .utf8) else {
            throw EnsemblePlexError.noSyncedCredentials
        }
        let credentials = try JSONDecoder().decode([EnsembleAccountCredential].self, from: data)
        guard !credentials.isEmpty else { throw EnsemblePlexError.noSyncedCredentials }
        return credentials
    }

    public func saveSyncedCredential(_ credential: EnsembleAccountCredential) throws {
        var credentials = (try? loadSyncedCredentials()) ?? []
        credentials.removeAll { $0.accountId == credential.accountId }
        credentials.append(credential)
        let data = try JSONEncoder().encode(credentials)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try keychain.saveSynchronizable(json, forKey: KeychainKey.plexAccountsSync)
    }

    public func discoverServers(from credentials: [EnsembleAccountCredential]) async throws -> [EnsemblePlexServer] {
        var discovered: [EnsemblePlexServer] = []

        for account in credentials {
            let api = Self.bootstrapClient(token: account.authToken)
            let devices = try await api.getResources(token: account.authToken)
            for device in devices {
                guard let token = device.accessToken ?? account.servers.first(where: { $0.serverId == device.clientIdentifier })?.serverToken,
                      let connection = device.bestConnection else {
                    continue
                }

                let hintedLibraries = account.servers
                    .first(where: { $0.serverId == device.clientIdentifier })?
                    .libraries ?? []

                let client = Self.client(
                    serverId: device.clientIdentifier,
                    serverName: device.name,
                    serverToken: token,
                    url: connection.uri,
                    connections: device.connections,
                    library: nil
                )

                let sections: [PlexLibrarySection]
                do {
                    _ = try await client.refreshConnection()
                    sections = try await client.getLibrarySections()
                } catch {
                    continue
                }
                let activeServerURL = await client.getCurrentServerURL()
                let musicSections = sections.filter(\.isMusicLibrary)
                let libraries = Self.mergeLibraryHints(hintedLibraries, sections: musicSections)

                discovered.append(EnsemblePlexServer(
                    account: account,
                    id: device.clientIdentifier,
                    name: device.name,
                    token: token,
                    url: activeServerURL,
                    connections: device.connections,
                    libraries: libraries
                ))
            }
        }

        guard !discovered.isEmpty else { throw EnsemblePlexError.noReachableServer }
        return discovered
    }

    public func cachedLibraries(
        from credentials: [EnsembleAccountCredential],
        snapshot: EnsemblePlexCatalogSnapshot
    ) async -> [EnsemblePlexLibrary] {
        let sourceKeys = Set(snapshot.watchSourceKeys.compactMap(Self.parseSourceKey))
        guard !sourceKeys.isEmpty else { return [] }

        var libraries: [EnsemblePlexLibrary] = []
        for account in credentials {
            let api = Self.bootstrapClient(token: account.authToken)
            guard let devices = try? await api.getResources(token: account.authToken) else { continue }

            for device in devices {
                let matchedKeys = sourceKeys
                    .filter { $0.accountId == account.accountId && $0.serverId == device.clientIdentifier }
                    .map { $0.libraryKey }
                guard !matchedKeys.isEmpty,
                      let token = device.accessToken ?? account.servers.first(where: { $0.serverId == device.clientIdentifier })?.serverToken,
                      let connection = device.bestConnection else {
                    continue
                }

                let references = matchedKeys.sorted().map { key in
                    EnsembleLibraryReference(
                        id: key,
                        key: key,
                        title: snapshot.libraries.first(where: { $0.key == key })?.title ?? "Music",
                        isEnabled: true
                    )
                }
                let server = EnsemblePlexServer(
                    account: account,
                    id: device.clientIdentifier,
                    name: device.name,
                    token: token,
                    url: connection.uri,
                    connections: device.connections,
                    libraries: references
                )
                libraries.append(contentsOf: references.map {
                    EnsemblePlexLibrary(server: server, id: $0.id, key: $0.key, title: $0.title)
                })
            }
        }
        return libraries
    }

    public func credential(from token: String) async throws -> EnsembleAccountCredential {
        let api = Self.bootstrapClient(token: token)
        let user = try await api.getUserInfo(token: token)
        let devices = try await api.getResources(token: token)
        let serverCredentials = devices.map { device in
            EnsembleServerCredential(
                serverId: device.clientIdentifier,
                serverName: device.name,
                serverToken: device.accessToken ?? token,
                libraries: []
            )
        }

        return EnsembleAccountCredential(
            accountId: user.uuid,
            email: user.email,
            plexUsername: user.username,
            displayTitle: user.title,
            authToken: token,
            servers: serverCredentials
        )
    }

    public static func bootstrapClient(token: String) -> PlexAPIClient {
        PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://plex.tv",
                token: token,
                identifier: "plex-tv",
                name: "Plex"
            ),
            productName: "Ensemble Watch",
            productVersion: "1.0"
        )
    }

    public static func client(for library: EnsemblePlexLibrary) -> PlexAPIClient {
        client(
            serverId: library.server.id,
            serverName: library.server.name,
            serverToken: library.server.token,
            url: library.server.url,
            connections: library.server.connections,
            library: library
        )
    }

    private static func client(
        serverId: String,
        serverName: String,
        serverToken: String,
        url: String,
        connections: [PlexConnection],
        library: EnsemblePlexLibrary?
    ) -> PlexAPIClient {
        let alternativeURLs = connections.map(\.uri).filter { $0 != url }
        let endpoints = connections.map {
            PlexEndpointDescriptor(
                url: $0.uri,
                local: $0.local,
                relay: $0.relay ?? false,
                secure: $0.protocol == "https" || $0.uri.lowercased().hasPrefix("https://")
            )
        }

        let selection = library.map { PlexLibrarySelection(key: $0.key, title: $0.title) }
        return PlexAPIClient(
            connection: PlexServerConnection(
                url: url,
                alternativeURLs: alternativeURLs,
                endpoints: endpoints,
                token: serverToken,
                identifier: serverId,
                name: serverName
            ),
            librarySelection: selection,
            productName: "Ensemble Watch",
            productVersion: "1.0"
        )
    }

    private static func mergeLibraryHints(
        _ hints: [EnsembleLibraryReference],
        sections: [PlexLibrarySection]
    ) -> [EnsembleLibraryReference] {
        if hints.isEmpty {
            return sections.map { section in
                EnsembleLibraryReference(
                    id: section.key,
                    key: section.key,
                    title: section.title,
                    isEnabled: true
                )
            }
        }

        let hintedByKey = Dictionary(uniqueKeysWithValues: hints.map { ($0.key, $0) })
        return sections.map { section in
            if let hint = hintedByKey[section.key] {
                return EnsembleLibraryReference(
                    id: section.key,
                    key: section.key,
                    title: section.title,
                    isEnabled: hint.isEnabled
                )
            }
            return EnsembleLibraryReference(
                id: section.key,
                key: section.key,
                title: section.title,
                isEnabled: false
            )
        }
    }

    private struct SourceComponents: Hashable {
        let accountId: String
        let serverId: String
        let libraryKey: String
    }

    private static func parseSourceKey(_ sourceKey: String) -> SourceComponents? {
        let components = sourceKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 4, components[0] == "plex" else { return nil }
        return SourceComponents(accountId: components[1], serverId: components[2], libraryKey: components[3])
    }
}

private extension EnsemblePlexCatalogSnapshot {
    var watchSourceKeys: [String] {
        (pins + albums + artists + playlists + recentlyAdded).map(\.sourceKey)
    }
}

/// Loads lightweight Plex catalog data for watch browse surfaces.
public actor EnsemblePlexCatalogService {
    private struct RecentlyAddedItem: Sendable {
        let summary: EnsembleMediaSummary
        let addedAt: Int
    }

    public init() {}

    public nonisolated func selectedLibraries(
        from servers: [EnsemblePlexServer],
        fallbackToAllDiscovered: Bool = true
    ) throws -> [EnsemblePlexLibrary] {
        let enabledLibraries = servers.flatMap { server in
            server.libraries
                .filter(\.isEnabled)
                .map { EnsemblePlexLibrary(server: server, id: $0.id, key: $0.key, title: $0.title) }
        }
        if !enabledLibraries.isEmpty {
            return enabledLibraries
        }

        guard fallbackToAllDiscovered else { return [] }

        let discoveredLibraries = servers.flatMap { server in
            server.libraries.map { EnsemblePlexLibrary(server: server, id: $0.id, key: $0.key, title: $0.title) }
        }
        guard !discoveredLibraries.isEmpty else { throw EnsemblePlexError.noSelectedLibraries }
        return discoveredLibraries
    }

    public func refreshSnapshot(
        libraries: [EnsemblePlexLibrary],
        limits: EnsemblePlexCatalogLimits = EnsemblePlexCatalogLimits()
    ) async throws -> EnsemblePlexCatalogSnapshot {
        var libraryRefs: [EnsembleLibraryReference] = []
        var albums: [EnsembleMediaSummary] = []
        var artists: [EnsembleMediaSummary] = []
        var playlists: [EnsembleMediaSummary] = []
        var tracks: [EnsembleTrack] = []
        var genres: [EnsembleGenreSummary] = []
        var recentlyAdded: [RecentlyAddedItem] = []
        var fetchedPlaylistSourceKeys = Set<String>()

        for library in libraries {
            libraryRefs.append(EnsembleLibraryReference(id: library.id, key: library.key, title: library.title, isEnabled: true))
            let client = EnsemblePlexDiscoveryService.client(for: library)

            async let libraryArtists = client.getArtists(sectionKey: library.key)
            async let libraryAlbums = client.getAlbums(sectionKey: library.key)
            async let libraryTracks = client.getTracks(sectionKey: library.key)
            async let libraryGenres = client.getGenres(sectionKey: library.key)
            let shouldFetchPlaylists = fetchedPlaylistSourceKeys.insert(library.server.sourceKey).inserted
            async let serverPlaylists: [PlexPlaylist] = shouldFetchPlaylists ? client.getPlaylists() : []
            async let hubItems = recentlyAddedItems(client: client, library: library, limit: limits.recentlyAdded)

            let sourceKey = library.sourceKey
            let fetchedAlbums = try await libraryAlbums
            let fetchedTracks = try await libraryTracks
            let fetchedGenres = try await libraryGenres
            let mappedArtists = Self.albumArtists(try await libraryArtists, albums: fetchedAlbums)
                .map { $0.watchSummary(sourceKey: sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedAlbums = fetchedAlbums
                .map { $0.watchSummary(sourceKey: sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedPlaylists = try await serverPlaylists
                .map { $0.watchSummary(sourceKey: library.server.sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedRecent = try await hubItems

            artists.append(contentsOf: mappedArtists)
            albums.append(contentsOf: mappedAlbums)
            playlists.append(contentsOf: mappedPlaylists)
            tracks.append(contentsOf: fetchedTracks.map { $0.watchTrack(sourceKey: sourceKey) })
            genres.append(contentsOf: fetchedGenres.map {
                EnsembleGenreSummary(id: $0.id, title: $0.title, sourceKey: sourceKey)
            })
            recentlyAdded.append(contentsOf: mappedRecent)
        }

        return EnsemblePlexCatalogSnapshot(
            libraries: libraryRefs,
            pins: [],
            albums: albums,
            artists: artists,
            playlists: playlists,
            recentlyAdded: recentlyAdded
                .sorted {
                    if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                    return $0.summary.title.localizedStandardCompare($1.summary.title) == .orderedAscending
                }
                .prefix(limits.recentlyAdded)
                .map(\.summary),
            tracks: tracks,
            genres: genres
        )
    }

    static func albumArtists(_ artists: [PlexArtist], albums: [PlexAlbum]) -> [PlexArtist] {
        let albumArtistIDs = Set(albums.compactMap(\.parentRatingKey))
        return artists.filter { albumArtistIDs.contains($0.ratingKey) }
    }

    public func tracks(for item: EnsembleMediaSummary, in libraries: [EnsemblePlexLibrary]) async throws -> [EnsembleTrack] {
        guard let library = Self.library(for: item.sourceKey, in: libraries) else {
            return []
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        let tracks: [PlexTrack]
        switch item.kind {
        case .album:
            tracks = try await client.getAlbumTracks(albumKey: item.id)
        case .artist:
            tracks = try await client.getArtistTracks(artistKey: item.id)
        case .playlist:
            tracks = try await client.getPlaylistTracks(playlistKey: item.id)
        case .track:
            if let track = try await client.getTrack(trackKey: item.id) {
                tracks = [track]
            } else {
                tracks = []
            }
        }
        return tracks.map { $0.watchTrack(sourceKey: item.sourceKey) }
    }

    public func tracks(for genre: EnsembleGenreSummary, in libraries: [EnsemblePlexLibrary]) async throws -> [EnsembleTrack] {
        guard let library = Self.library(for: genre.sourceKey, in: libraries) else { return [] }
        return try await EnsemblePlexDiscoveryService.client(for: library)
            .getTracksByGenre(sectionKey: library.key, genreKey: genre.id)
            .map { $0.watchTrack(sourceKey: genre.sourceKey) }
    }

    public func recommendedTracks(
        for track: EnsembleTrack,
        in libraries: [EnsemblePlexLibrary],
        limit: Int = 10
    ) async throws -> [EnsembleTrack] {
        guard let library = Self.library(for: track.sourceKey, in: libraries),
              let recommendations = try await EnsemblePlexDiscoveryService.client(for: library)
                .getSimilarTracks(ratingKey: track.id, limit: limit) else {
            return []
        }
        return recommendations.map { $0.watchTrack(sourceKey: track.sourceKey) }
    }

    public func playlistTargets(in libraries: [EnsemblePlexLibrary]) async throws -> [EnsemblePlexPlaylistTarget] {
        var targets: [EnsemblePlexPlaylistTarget] = []
        var seenServers = Set<String>()
        for library in libraries where seenServers.insert(library.server.sourceKey).inserted {
            let client = EnsemblePlexDiscoveryService.client(for: library)
            targets.append(contentsOf: try await client.getPlaylists().map {
                EnsemblePlexPlaylistTarget(
                    id: $0.ratingKey,
                    title: $0.title,
                    sourceKey: library.server.sourceKey,
                    isSmart: $0.smart == true,
                    updatedAt: $0.updatedAt
                )
            })
        }
        return targets.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
    }

    @discardableResult
    public func addTracks(
        _ tracks: [EnsembleTrack],
        to playlist: EnsemblePlexPlaylistTarget,
        in libraries: [EnsemblePlexLibrary]
    ) async throws -> Int {
        guard !tracks.isEmpty else { throw EnsemblePlexPlaylistMutationError.emptySelection }
        guard !playlist.isSmart else { throw EnsemblePlexPlaylistMutationError.smartPlaylistReadOnly }
        guard let library = Self.library(for: playlist.sourceKey, in: libraries),
              tracks.allSatisfy({ Self.isTrackCompatible($0, with: playlist.sourceKey) }) else {
            throw EnsemblePlexPlaylistMutationError.noCompatibleSource
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        let existingIDs = Set(try await client.getPlaylistTracks(playlistKey: playlist.id).map(\.ratingKey))
        let newTracks = tracks.filter { !existingIDs.contains($0.id) }
        guard !newTracks.isEmpty else { return 0 }
        try await client.addItemsToPlaylist(
            playlistId: playlist.id,
            trackRatingKeys: newTracks.map(\.id),
            serverIdentifier: library.server.id
        )
        return newTracks.count
    }

    public func createPlaylist(
        title: String,
        tracks: [EnsembleTrack],
        sourceKey: String,
        in libraries: [EnsemblePlexLibrary]
    ) async throws -> EnsemblePlexPlaylistTarget {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw EnsemblePlexPlaylistMutationError.invalidTitle }
        guard !tracks.isEmpty else { throw EnsemblePlexPlaylistMutationError.emptySelection }
        guard let library = Self.library(for: sourceKey, in: libraries),
              tracks.allSatisfy({ Self.isTrackCompatible($0, with: library.server.sourceKey) }) else {
            throw EnsemblePlexPlaylistMutationError.noCompatibleSource
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        try await client.createPlaylist(
            title: trimmedTitle,
            trackRatingKeys: tracks.map(\.id),
            serverIdentifier: library.server.id
        )
        guard let created = try await client.getPlaylists().first(where: { $0.title == trimmedTitle }) else {
            throw EnsemblePlexPlaylistMutationError.createdPlaylistUnavailable
        }
        return EnsemblePlexPlaylistTarget(
            id: created.ratingKey,
            title: created.title,
            sourceKey: library.server.sourceKey,
            isSmart: created.smart == true,
            updatedAt: created.updatedAt
        )
    }

    public func rateTrack(
        _ track: EnsembleTrack,
        rating: Int?,
        in libraries: [EnsemblePlexLibrary]
    ) async throws {
        guard let library = Self.library(for: track.sourceKey, in: libraries) else {
            throw EnsemblePlexPlaylistMutationError.noCompatibleSource
        }
        try await EnsemblePlexDiscoveryService.client(for: library).rateTrack(
            ratingKey: track.id,
            rating: rating
        )
    }

    private static func isTrackCompatible(_ track: EnsembleTrack, with serverSourceKey: String) -> Bool {
        track.sourceKey == serverSourceKey || track.sourceKey.hasPrefix(serverSourceKey + ":")
    }

    public nonisolated func artworkURL(for item: EnsembleMediaSummary, in libraries: [EnsemblePlexLibrary], size: Int = 96) -> URL? {
        guard let artworkPath = item.artworkPath,
              let library = Self.library(for: item.sourceKey, in: libraries) else {
            return nil
        }

        return PlexAPIClient.artworkURL(
            serverURL: library.server.url,
            token: library.server.token,
            path: artworkPath,
            size: size
        )
    }

    public nonisolated func artworkURL(for track: EnsembleTrack, in libraries: [EnsemblePlexLibrary], size: Int = 96) -> URL? {
        guard let artworkPath = track.artworkPath,
              let library = Self.library(for: track.sourceKey, in: libraries) else {
            return nil
        }

        return PlexAPIClient.artworkURL(
            serverURL: library.server.url,
            token: library.server.token,
            path: artworkPath,
            size: size
        )
    }

    public func streamURL(for track: EnsembleTrack, in libraries: [EnsemblePlexLibrary]) async throws -> URL {
        guard let library = Self.library(for: track.sourceKey, in: libraries) else {
            throw EnsemblePlexError.noSelectedLibraries
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        let resolution = try await client.resolveStreamURL(
            ratingKey: track.id,
            trackStreamKey: track.streamKey,
            quality: .original,
            metadataDurationSeconds: track.duration > 0 ? track.duration : nil
        )

        switch resolution {
        case .directStream(let url), .downloadedFile(let url):
            return url
        case .progressiveTranscode:
            throw EnsemblePlexError.unsupportedStreamResolution
        }
    }

    private func recentlyAddedItems(
        client: PlexAPIClient,
        library: EnsemblePlexLibrary,
        limit: Int
    ) async throws -> [RecentlyAddedItem] {
        let hubs = try await client.getHubs(sectionKey: library.key, count: String(limit))
        let sourceKey = library.sourceKey
        let recentHub = hubs.first {
            PlexHubIdentity.normalized($0.hubIdentifier ?? "") == PlexHubIdentity.recentlyAddedMusic
        }
        return (recentHub?.metadata ?? [])
            .compactMap { metadata in
                metadata.watchSummary(sourceKey: sourceKey).map {
                    RecentlyAddedItem(summary: $0, addedAt: metadata.addedAt ?? 0)
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    static func library(
        for sourceKey: String,
        in libraries: [EnsemblePlexLibrary]
    ) -> EnsemblePlexLibrary? {
        libraries.first {
            $0.sourceKey == sourceKey || $0.server.sourceKey == sourceKey
        }
    }
}

private extension PlexArtist {
    func watchSummary(sourceKey: String) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: ratingKey,
            kind: .artist,
            title: title,
            subtitle: nil,
            artworkPath: thumb ?? art,
            sourceKey: sourceKey
        )
    }
}

private extension PlexAlbum {
    func watchSummary(sourceKey: String) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: ratingKey,
            kind: .album,
            title: title,
            subtitle: parentTitle,
            artistID: parentRatingKey,
            artworkPath: thumb ?? art,
            sourceKey: sourceKey
        )
    }
}

private extension PlexPlaylist {
    func watchSummary(sourceKey: String) -> EnsembleMediaSummary {
        let subtitle = leafCount.map { "\($0) tracks" }
        return EnsembleMediaSummary(
            id: ratingKey,
            kind: .playlist,
            title: title,
            subtitle: subtitle,
            artworkPath: composite,
            sourceKey: sourceKey,
            isSmart: smart
        )
    }
}

private extension PlexHubMetadata {
    func watchSummary(sourceKey: String) -> EnsembleMediaSummary? {
        let kind: EnsembleMediaKind
        switch type {
        case "artist": kind = .artist
        case "album": kind = .album
        case "playlist": kind = .playlist
        case "track": kind = .track
        default: return nil
        }

        let subtitle = originalTitle ?? grandparentTitle ?? parentTitle
        return EnsembleMediaSummary(
            id: ratingKey,
            kind: kind,
            title: displayTitle,
            subtitle: subtitle,
            albumID: kind == .track ? parentRatingKey : nil,
            artistID: kind == .album ? parentRatingKey : (kind == .track ? grandparentRatingKey : nil),
            artworkPath: thumb ?? parentThumb ?? grandparentThumb ?? art,
            sourceKey: sourceKey
        )
    }
}

extension PlexTrack {
    func watchTrack(sourceKey: String) -> EnsembleTrack {
        EnsembleTrack(
            id: ratingKey,
            playlistItemID: playlistItemID,
            title: title,
            artistName: originalTitle ?? grandparentTitle,
            albumID: parentRatingKey,
            artistID: grandparentRatingKey,
            albumTitle: parentTitle,
            trackNumber: index,
            discNumber: parentIndex,
            duration: durationSeconds,
            artworkPath: thumb ?? parentThumb ?? grandparentThumb ?? art,
            streamKey: streamURL,
            sourceKey: sourceKey,
            isFavorite: (userRating ?? 0) > 0
        )
    }
}
