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
        "plex:\(accountId):\(serverId)"
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

    public init(
        fetchedAt: Date = Date(),
        libraries: [EnsembleLibraryReference],
        pins: [EnsembleMediaSummary],
        albums: [EnsembleMediaSummary],
        artists: [EnsembleMediaSummary],
        playlists: [EnsembleMediaSummary],
        recentlyAdded: [EnsembleMediaSummary]
    ) {
        self.fetchedAt = fetchedAt
        self.libraries = libraries
        self.pins = pins
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.recentlyAdded = recentlyAdded
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
                      let connection = Self.preferredWatchConnection(for: device) else {
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
                      let connection = Self.preferredWatchConnection(for: device) else {
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

    private static func preferredWatchConnection(for device: PlexDevice) -> PlexConnection? {
        device.connections.first {
            $0.local == false && ($0.relay ?? false) == false && $0.isSecure && !$0.looksLikePrivatePlexDirectHost
        } ?? device.connections.first {
            ($0.relay ?? false) == true && $0.isSecure
        } ?? device.connections.first {
            $0.local == false && $0.isSecure
        } ?? device.bestConnection
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

private extension PlexConnection {
    var isSecure: Bool {
        self.protocol == "https" || uri.lowercased().hasPrefix("https://")
    }

    var looksLikePrivatePlexDirectHost: Bool {
        guard let host = URLComponents(string: uri)?.host?.lowercased() else { return false }
        return WatchPlexConnectionPolicy.looksLikePrivatePlexDirectHost(host)
    }
}

enum WatchPlexConnectionPolicy {
    static func looksLikePrivatePlexDirectHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasPrefix("192-168-")
            || host.hasPrefix("10-")
            || isPrivate172PlexDirectHost(host)
            || host.hasPrefix("fd")
            || host.hasPrefix("fe80-")
            || host.hasPrefix("2601-")
    }

    private static func isPrivate172PlexDirectHost(_ host: String) -> Bool {
        guard host.hasPrefix("172-") else { return false }
        let remainder = host.dropFirst("172-".count)
        let secondOctet = remainder.prefix { $0 != "-" }
        guard let value = Int(secondOctet) else { return false }
        return (16...31).contains(value)
    }
}

/// Loads lightweight Plex catalog data for watch browse surfaces.
public actor EnsemblePlexCatalogService {
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
        var recentlyAdded: [EnsembleMediaSummary] = []
        var fetchedPlaylistSourceKeys = Set<String>()

        for library in libraries {
            libraryRefs.append(EnsembleLibraryReference(id: library.id, key: library.key, title: library.title, isEnabled: true))
            let client = EnsemblePlexDiscoveryService.client(for: library)

            async let libraryArtists = client.getArtists(sectionKey: library.key)
            async let libraryAlbums = client.getAlbums(sectionKey: library.key)
            let shouldFetchPlaylists = fetchedPlaylistSourceKeys.insert(library.server.sourceKey).inserted
            async let serverPlaylists: [PlexPlaylist] = shouldFetchPlaylists ? client.getPlaylists() : []
            async let hubItems = recentlyAddedItems(client: client, library: library, limit: limits.recentlyAdded)

            let sourceKey = library.sourceKey
            let fetchedAlbums = try await libraryAlbums
            let mappedArtists = Self.albumArtists(try await libraryArtists, albums: fetchedAlbums)
                .map { $0.watchSummary(sourceKey: sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedAlbums = fetchedAlbums
                .map { $0.watchSummary(sourceKey: sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedPlaylists = try await serverPlaylists
                .filter(\.isAudioPlaylist)
                .map { $0.watchSummary(sourceKey: library.server.sourceKey) }
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            let mappedRecent = try await hubItems

            artists.append(contentsOf: mappedArtists)
            albums.append(contentsOf: mappedAlbums)
            playlists.append(contentsOf: mappedPlaylists)
            recentlyAdded.append(contentsOf: mappedRecent.prefix(limits.recentlyAdded))
        }

        return EnsemblePlexCatalogSnapshot(
            libraries: libraryRefs,
            pins: [],
            albums: albums,
            artists: artists,
            playlists: playlists,
            recentlyAdded: Array(recentlyAdded.prefix(limits.recentlyAdded))
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

    public func artworkURL(for item: EnsembleMediaSummary, in libraries: [EnsemblePlexLibrary], size: Int = 96) async -> URL? {
        guard let artworkPath = item.artworkPath,
              let library = Self.library(for: item.sourceKey, in: libraries) else {
            return nil
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        return try? await client.getArtworkURL(path: artworkPath, size: size)
    }

    public func artworkURL(for track: EnsembleTrack, in libraries: [EnsemblePlexLibrary], size: Int = 96) async -> URL? {
        guard let artworkPath = track.artworkPath,
              let library = Self.library(for: track.sourceKey, in: libraries) else {
            return nil
        }

        let client = EnsemblePlexDiscoveryService.client(for: library)
        return try? await client.getArtworkURL(path: artworkPath, size: size)
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
    ) async throws -> [EnsembleMediaSummary] {
        let hubs = try await client.getHubs(sectionKey: library.key, count: String(limit))
        let sourceKey = library.sourceKey
        let recentHub = hubs.first {
            let key = "\($0.hubIdentifier ?? "") \($0.title)".lowercased()
            return key.contains("recent")
        }
        return (recentHub?.metadata ?? [])
            .compactMap { $0.watchSummary(sourceKey: sourceKey) }
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
            sourceKey: sourceKey
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
            title: title,
            subtitle: subtitle,
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
            albumTitle: parentTitle,
            trackNumber: index,
            discNumber: parentIndex,
            duration: durationSeconds,
            artworkPath: thumb ?? parentThumb ?? grandparentThumb ?? art,
            streamKey: streamURL,
            sourceKey: sourceKey
        )
    }
}
