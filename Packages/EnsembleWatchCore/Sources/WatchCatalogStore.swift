import CoreData
import EnsembleDomain
import EnsemblePersistence
import EnsemblePlex
import Foundation

public final class WatchCatalogStore: @unchecked Sendable {
    private static let snapshotID = "ensemble.watch.catalog"
    private static let pinsHubID = "ensemble.watch.pins"
    private static let recentHubID = "ensemble.watch.recent"

    private let defaults: UserDefaults
    private let coreDataStack: CoreDataStack
    private let selectedLibraryKey = "ensemble.watch.selectedLibraries"
    private let libraryFlagsKey = "ensemble.watch.libraryFlags"

    public convenience init() {
        self.init(defaults: .standard, coreDataStack: .shared)
    }

    public convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, coreDataStack: .shared)
    }

    public init(defaults: UserDefaults, coreDataStack: CoreDataStack) {
        self.defaults = defaults
        self.coreDataStack = coreDataStack
    }

    public func loadSnapshot() async throws -> EnsemblePlexCatalogSnapshot? {
        try await coreDataStack.performBackgroundContext { context in
            try Self.loadSnapshot(in: context, homeOnly: false)
        }
    }

    public func loadHomeSnapshot() async throws -> EnsemblePlexCatalogSnapshot? {
        try await coreDataStack.performBackgroundContext { context in
            try Self.loadSnapshot(in: context, homeOnly: true)
        }
    }

    public func saveSnapshot(
        _ snapshot: EnsemblePlexCatalogSnapshot,
        libraries: [EnsemblePlexLibrary] = []
    ) async throws {
        let descriptors = Self.sourceDescriptors(snapshot: snapshot, libraries: libraries)
        try await coreDataStack.performBackgroundContext { context in
            let state = try Self.upsertSnapshotState(snapshot, in: context)
            let sources = try Self.upsertSources(descriptors, fetchedAt: snapshot.fetchedAt, in: context)
            let artists = try Self.upsertArtists(snapshot.artists, sources: sources, fetchedAt: snapshot.fetchedAt, in: context)
            let albums = try Self.upsertAlbums(
                snapshot.albums,
                artists: artists,
                sources: sources,
                fetchedAt: snapshot.fetchedAt,
                in: context
            )
            try Self.upsertTracks(
                snapshot.tracks,
                albums: albums,
                sources: sources,
                fetchedAt: snapshot.fetchedAt,
                in: context
            )
            try Self.upsertPlaylists(
                snapshot.playlists,
                sources: sources,
                fetchedAt: snapshot.fetchedAt,
                in: context
            )
            try Self.replaceGenres(
                snapshot.genres,
                activeSourceKeys: Set(descriptors.filter { !$0.libraryID.isEmpty }.map(\.compositeKey)),
                sources: sources,
                in: context
            )
            Self.replaceHomeHubs(on: state, pins: snapshot.pins, recent: snapshot.recentlyAdded, in: context)
            try context.save()
        }
    }

    public func savePins(_ pins: [EnsembleMediaSummary]) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDHomeFeedSnapshot.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", Self.snapshotID)
            request.fetchLimit = 1
            guard let state = try context.fetch(request).first else { return }
            Self.replaceHub(id: Self.pinsHubID, title: "Pins", order: 0, items: pins, on: state, in: context)
            try context.save()
        }
    }

    public func loadSelectedLibraryKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: selectedLibraryKey) ?? [])
    }

    public func saveSelectedLibraryKeys(_ keys: Set<String>) {
        defaults.set(Array(keys).sorted(), forKey: selectedLibraryKey)
    }

    public func loadLibraryFlags() -> [String: Bool] {
        loadLibraryFlagEntries().mapValues(\.isEnabled)
    }

    public func saveLibraryFlags(_ flags: [String: Bool]) {
        let current = loadLibraryFlagEntries()
        let now = Date().timeIntervalSince1970
        let entries = flags.reduce(into: [String: EnsembleLibraryFlagEntry]()) { result, element in
            if let existing = current[element.key],
               existing.isEnabled == element.value,
               existing.updatedAt != nil {
                result[element.key] = existing
            } else {
                result[element.key] = EnsembleLibraryFlagEntry(
                    key: element.key,
                    isEnabled: element.value,
                    updatedAt: now
                )
            }
        }
        saveLibraryFlagEntries(entries)
    }

    public func loadLibraryFlagEntries() -> [String: EnsembleLibraryFlagEntry] {
        guard let data = defaults.data(forKey: libraryFlagsKey) else { return [:] }
        return EnsembleLibraryFlagPolicy.decodedEntries(from: data) ?? [:]
    }

    public func saveLibraryFlagEntries(_ entries: [String: EnsembleLibraryFlagEntry]) {
        let sortedEntries = entries.values.sorted { $0.key < $1.key }
        guard let data = try? JSONEncoder().encode(sortedEntries) else { return }
        defaults.set(data, forKey: libraryFlagsKey)
    }
}

private extension WatchCatalogStore {
    struct SourceDescriptor {
        let compositeKey: String
        let accountID: String
        let serverID: String
        let libraryID: String
        let title: String?
    }

    static func loadSnapshot(
        in context: NSManagedObjectContext,
        homeOnly: Bool
    ) throws -> EnsemblePlexCatalogSnapshot? {
        let stateRequest = CDHomeFeedSnapshot.fetchRequest()
        stateRequest.predicate = NSPredicate(format: "id == %@", snapshotID)
        stateRequest.fetchLimit = 1
        guard let state = try context.fetch(stateRequest).first,
              let fetchedAt = state.fetchedAt else {
            return nil
        }

        let sourceRequest = CDMusicSource.fetchRequest()
        sourceRequest.predicate = NSPredicate(format: "lastSyncedAt >= %@", fetchedAt as NSDate)
        let sources = try context.fetch(sourceRequest)
        let libraries = sources
            .filter { !$0.libraryId.isEmpty }
            .map {
                EnsembleLibraryReference(
                    id: $0.libraryId,
                    key: $0.libraryId,
                    title: $0.displayName ?? "Music",
                    isEnabled: true
                )
            }
            .sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
            }

        let hubs = Dictionary(uniqueKeysWithValues: state.hubsArray.map { ($0.id, $0) })
        let pins = try summaries(from: hubs[pinsHubID]?.itemsArray ?? [], in: context)
        let recent = try summaries(from: hubs[recentHubID]?.itemsArray ?? [], in: context)
        guard !homeOnly else {
            return EnsemblePlexCatalogSnapshot(
                fetchedAt: fetchedAt,
                libraries: libraries,
                pins: pins,
                albums: [],
                artists: [],
                playlists: [],
                recentlyAdded: recent
            )
        }

        let currentPredicate = NSPredicate(format: "updatedAt >= %@", fetchedAt as NSDate)
        let artistRequest = CDArtist.fetchRequest()
        artistRequest.predicate = currentPredicate
        let artists = try context.fetch(artistRequest).map(summary).sorted(by: titleAscending)

        let albumRequest = CDAlbum.fetchRequest()
        albumRequest.predicate = currentPredicate
        albumRequest.relationshipKeyPathsForPrefetching = ["artist"]
        let albums = try context.fetch(albumRequest).map(summary).sorted(by: titleAscending)

        let playlistRequest = CDPlaylist.fetchRequest()
        playlistRequest.predicate = currentPredicate
        let playlists = try context.fetch(playlistRequest).map(summary).sorted(by: titleAscending)

        let trackRequest = CDTrack.fetchRequest()
        trackRequest.predicate = currentPredicate
        trackRequest.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        let tracks = try context.fetch(trackRequest).map(track)

        let sourceKeys = Set(sources.map(\.compositeKey))
        let genreRequest = CDGenre.fetchRequest()
        genreRequest.predicate = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceKeys))
        let genres = try context.fetch(genreRequest).compactMap { genre -> EnsembleGenreSummary? in
            guard let sourceKey = genre.sourceCompositeKey else { return nil }
            return EnsembleGenreSummary(id: genre.ratingKey ?? genre.key, title: genre.title, sourceKey: sourceKey)
        }

        return EnsemblePlexCatalogSnapshot(
            fetchedAt: fetchedAt,
            libraries: libraries,
            pins: pins,
            albums: albums,
            artists: artists,
            playlists: playlists,
            recentlyAdded: recent,
            tracks: tracks,
            genres: genres
        )
    }

    static func summaries(
        from items: [CDHubItem],
        in context: NSManagedObjectContext
    ) throws -> [EnsembleMediaSummary] {
        let ids = Array(Set(items.map(\.id)))
        guard !ids.isEmpty else { return [] }

        let artistRequest = CDArtist.fetchRequest()
        artistRequest.predicate = NSPredicate(format: "ratingKey IN %@", ids)
        let artists = Dictionary(uniqueKeysWithValues: try context.fetch(artistRequest).compactMap { artist in
            artist.sourceCompositeKey.map { (identity(id: artist.ratingKey, sourceKey: $0), summary(artist)) }
        })

        let albumRequest = CDAlbum.fetchRequest()
        albumRequest.predicate = NSPredicate(format: "ratingKey IN %@", ids)
        albumRequest.relationshipKeyPathsForPrefetching = ["artist"]
        let albums = Dictionary(uniqueKeysWithValues: try context.fetch(albumRequest).compactMap { album in
            album.sourceCompositeKey.map { (identity(id: album.ratingKey, sourceKey: $0), summary(album)) }
        })

        let playlistRequest = CDPlaylist.fetchRequest()
        playlistRequest.predicate = NSPredicate(format: "ratingKey IN %@", ids)
        let playlists = Dictionary(uniqueKeysWithValues: try context.fetch(playlistRequest).compactMap { playlist in
            playlist.sourceCompositeKey.map { (identity(id: playlist.ratingKey, sourceKey: $0), summary(playlist)) }
        })

        let trackRequest = CDTrack.fetchRequest()
        trackRequest.predicate = NSPredicate(format: "ratingKey IN %@", ids)
        trackRequest.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        let tracks = Dictionary(uniqueKeysWithValues: try context.fetch(trackRequest).compactMap { storedTrack in
            storedTrack.sourceCompositeKey.map {
                (identity(id: storedTrack.ratingKey, sourceKey: $0), track(storedTrack).summary)
            }
        })

        return items.map { item in
            let key = identity(id: item.id, sourceKey: item.sourceCompositeKey)
            return artists[key] ?? albums[key] ?? playlists[key] ?? tracks[key] ?? EnsembleMediaSummary(
                id: item.id,
                kind: EnsembleMediaKind(rawValue: item.type) ?? .album,
                title: item.title,
                subtitle: item.subtitle,
                artworkPath: item.thumbPath,
                sourceKey: item.sourceCompositeKey
            )
        }
    }

    static func upsertSnapshotState(
        _ snapshot: EnsemblePlexCatalogSnapshot,
        in context: NSManagedObjectContext
    ) throws -> CDHomeFeedSnapshot {
        let request = CDHomeFeedSnapshot.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", snapshotID)
        request.fetchLimit = 1
        let state = try context.fetch(request).first ?? CDHomeFeedSnapshot(context: context)
        state.id = snapshotID
        state.createdAt = state.createdAt ?? Date()
        state.fetchedAt = snapshot.fetchedAt
        state.sourceName = "Ensemble Watch"
        state.freshnessState = "fresh"
        state.schemaVersion = 1
        state.isLastGood = true
        return state
    }

    static func upsertSources(
        _ descriptors: [SourceDescriptor],
        fetchedAt: Date,
        in context: NSManagedObjectContext
    ) throws -> [String: CDMusicSource] {
        let existing = try context.fetch(CDMusicSource.fetchRequest())
        var sources = Dictionary(uniqueKeysWithValues: existing.map { ($0.compositeKey, $0) })
        for descriptor in descriptors {
            let source = sources[descriptor.compositeKey] ?? CDMusicSource(context: context)
            source.compositeKey = descriptor.compositeKey
            source.type = "plex"
            source.accountId = descriptor.accountID
            source.serverId = descriptor.serverID
            source.libraryId = descriptor.libraryID
            source.displayName = descriptor.title
            source.lastSyncedAt = fetchedAt
            sources[descriptor.compositeKey] = source
        }
        return sources
    }

    static func upsertArtists(
        _ items: [EnsembleMediaSummary],
        sources: [String: CDMusicSource],
        fetchedAt: Date,
        in context: NSManagedObjectContext
    ) throws -> [String: CDArtist] {
        let existing = try context.fetch(CDArtist.fetchRequest())
        var artists = Dictionary(uniqueKeysWithValues: existing.compactMap { artist in
            artist.sourceCompositeKey.map { (identity(id: artist.ratingKey, sourceKey: $0), artist) }
        })
        for item in items {
            let key = identity(item)
            let artist = artists[key] ?? CDArtist(context: context)
            artist.ratingKey = item.id
            artist.key = item.id
            artist.name = item.title
            artist.summary = item.subtitle
            artist.thumbPath = item.artworkPath
            artist.updatedAt = fetchedAt
            artist.sourceCompositeKey = item.sourceKey
            artist.source = sources[item.sourceKey]
            artists[key] = artist
        }
        return artists
    }

    static func upsertAlbums(
        _ items: [EnsembleMediaSummary],
        artists: [String: CDArtist],
        sources: [String: CDMusicSource],
        fetchedAt: Date,
        in context: NSManagedObjectContext
    ) throws -> [String: CDAlbum] {
        let existing = try context.fetch(CDAlbum.fetchRequest())
        var albums = Dictionary(uniqueKeysWithValues: existing.compactMap { album in
            album.sourceCompositeKey.map { (identity(id: album.ratingKey, sourceKey: $0), album) }
        })
        for item in items {
            let key = identity(item)
            let album = albums[key] ?? CDAlbum(context: context)
            album.ratingKey = item.id
            album.key = item.id
            album.title = item.title
            album.artistName = item.subtitle
            album.summary = item.subtitle
            album.thumbPath = item.artworkPath
            album.updatedAt = fetchedAt
            album.sourceCompositeKey = item.sourceKey
            album.source = sources[item.sourceKey]
            album.artist = item.artistID.flatMap { artists[identity(id: $0, sourceKey: item.sourceKey)] }
            albums[key] = album
        }
        return albums
    }

    static func upsertTracks(
        _ items: [EnsembleTrack],
        albums: [String: CDAlbum],
        sources: [String: CDMusicSource],
        fetchedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let existing = try context.fetch(CDTrack.fetchRequest())
        var tracks = Dictionary(uniqueKeysWithValues: existing.compactMap { track in
            track.sourceCompositeKey.map { (identity(id: track.ratingKey, sourceKey: $0), track) }
        })
        for item in items {
            let key = identity(id: item.id, sourceKey: item.sourceKey)
            let track = tracks[key] ?? CDTrack(context: context)
            track.ratingKey = item.id
            track.key = item.id
            track.title = item.title
            track.artistName = item.artistName
            track.albumName = item.albumTitle
            track.trackNumber = Int32(item.trackNumber ?? 0)
            track.discNumber = Int32(item.discNumber ?? 0)
            track.duration = Int64((item.duration * 1_000).rounded())
            track.thumbPath = item.artworkPath
            track.streamKey = item.streamKey
            track.isFavorite = item.isFavorite.map(NSNumber.init(value:))
            track.updatedAt = fetchedAt
            track.sourceCompositeKey = item.sourceKey
            track.source = sources[item.sourceKey]
            track.album = item.albumID.flatMap { albums[identity(id: $0, sourceKey: item.sourceKey)] }
            tracks[key] = track
        }
    }

    static func upsertPlaylists(
        _ items: [EnsembleMediaSummary],
        sources: [String: CDMusicSource],
        fetchedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let existing = try context.fetch(CDPlaylist.fetchRequest())
        var playlists = Dictionary(uniqueKeysWithValues: existing.compactMap { playlist in
            playlist.sourceCompositeKey.map { (identity(id: playlist.ratingKey, sourceKey: $0), playlist) }
        })
        for item in items {
            let key = identity(item)
            let playlist = playlists[key] ?? CDPlaylist(context: context)
            playlist.ratingKey = item.id
            playlist.key = item.id
            playlist.title = item.title
            playlist.summary = item.subtitle
            playlist.compositePath = item.artworkPath
            playlist.isSmart = item.isSmart ?? false
            playlist.updatedAt = fetchedAt
            playlist.sourceCompositeKey = item.sourceKey
            playlist.source = sources[item.sourceKey]
            playlists[key] = playlist
        }
    }

    static func replaceGenres(
        _ items: [EnsembleGenreSummary],
        activeSourceKeys: Set<String>,
        sources: [String: CDMusicSource],
        in context: NSManagedObjectContext
    ) throws {
        let currentKeys = Set(items.map { identity(id: $0.id, sourceKey: $0.sourceKey) })
        let existing = try context.fetch(CDGenre.fetchRequest())
        var genres = Dictionary(uniqueKeysWithValues: existing.compactMap { genre in
            genre.sourceCompositeKey.map {
                (identity(id: genre.ratingKey ?? genre.key, sourceKey: $0), genre)
            }
        })
        for genre in existing where genre.sourceCompositeKey.map(activeSourceKeys.contains) == true {
            let key = identity(id: genre.ratingKey ?? genre.key, sourceKey: genre.sourceCompositeKey ?? "")
            if !currentKeys.contains(key) { context.delete(genre) }
        }
        for item in items {
            let key = identity(id: item.id, sourceKey: item.sourceKey)
            let genre = genres[key] ?? CDGenre(context: context)
            genre.ratingKey = item.id
            genre.key = item.id
            genre.title = item.title
            genre.sourceCompositeKey = item.sourceKey
            genre.source = sources[item.sourceKey]
            genres[key] = genre
        }
    }

    static func replaceHomeHubs(
        on state: CDHomeFeedSnapshot,
        pins: [EnsembleMediaSummary],
        recent: [EnsembleMediaSummary],
        in context: NSManagedObjectContext
    ) {
        for hub in state.hubsArray { context.delete(hub) }
        let pinsHub = makeHub(id: pinsHubID, title: "Pins", order: 0, items: pins, state: state, in: context)
        let recentHub = makeHub(id: recentHubID, title: "Recently Added", order: 1, items: recent, state: state, in: context)
        state.hubs = NSOrderedSet(array: [pinsHub, recentHub])
    }

    static func replaceHub(
        id: String,
        title: String,
        order: Int16,
        items: [EnsembleMediaSummary],
        on state: CDHomeFeedSnapshot,
        in context: NSManagedObjectContext
    ) {
        var hubs = state.hubsArray.filter { $0.id != id }
        state.hubsArray.filter { $0.id == id }.forEach(context.delete)
        hubs.append(makeHub(id: id, title: title, order: order, items: items, state: state, in: context))
        hubs.sort { $0.order < $1.order }
        state.hubs = NSOrderedSet(array: hubs)
    }

    static func makeHub(
        id: String,
        title: String,
        order: Int16,
        items: [EnsembleMediaSummary],
        state: CDHomeFeedSnapshot,
        in context: NSManagedObjectContext
    ) -> CDHub {
        let hub = CDHub(context: context)
        hub.id = id
        hub.title = title
        hub.type = "watch"
        hub.order = order
        hub.snapshot = state
        hub.items = NSOrderedSet(array: items.enumerated().map { index, item in
            let stored = CDHubItem(context: context)
            stored.id = item.id
            stored.type = item.kind.rawValue
            stored.title = item.title
            stored.subtitle = item.subtitle
            stored.thumbPath = item.artworkPath
            stored.sourceCompositeKey = item.sourceKey
            stored.order = Int16(clamping: index)
            stored.hub = hub
            return stored
        })
        return hub
    }

    static func sourceDescriptors(
        snapshot: EnsemblePlexCatalogSnapshot,
        libraries: [EnsemblePlexLibrary]
    ) -> [SourceDescriptor] {
        var descriptors = Dictionary(uniqueKeysWithValues: libraries.map { library in
            let descriptor = SourceDescriptor(
                compositeKey: library.sourceKey,
                accountID: library.server.account.accountId,
                serverID: library.server.id,
                libraryID: library.key,
                title: library.title
            )
            return (descriptor.compositeKey, descriptor)
        })
        let sourceKeys = Set(
            snapshot.pins.map(\.sourceKey)
                + snapshot.albums.map(\.sourceKey)
                + snapshot.artists.map(\.sourceKey)
                + snapshot.playlists.map(\.sourceKey)
                + snapshot.recentlyAdded.map(\.sourceKey)
                + snapshot.tracks.map(\.sourceKey)
                + snapshot.genres.map(\.sourceKey)
        )
        for sourceKey in sourceKeys where descriptors[sourceKey] == nil {
            guard let descriptor = sourceDescriptor(sourceKey, libraries: snapshot.libraries) else { continue }
            descriptors[sourceKey] = descriptor
        }
        return Array(descriptors.values)
    }

    static func sourceDescriptor(
        _ sourceKey: String,
        libraries: [EnsembleLibraryReference]
    ) -> SourceDescriptor? {
        let components = sourceKey.split(separator: ":").map(String.init)
        guard components.count >= 3, components[0] == "plex" else { return nil }
        let libraryID = components.count > 3 ? components[3] : ""
        return SourceDescriptor(
            compositeKey: sourceKey,
            accountID: components[1],
            serverID: components[2],
            libraryID: libraryID,
            title: libraries.first { $0.key == libraryID }?.title
        )
    }

    static func summary(_ artist: CDArtist) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: artist.ratingKey,
            kind: .artist,
            title: artist.name,
            subtitle: artist.summary,
            artworkPath: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey ?? ""
        )
    }

    static func summary(_ album: CDAlbum) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: album.ratingKey,
            kind: .album,
            title: album.title,
            subtitle: album.artistName ?? album.summary,
            artistID: album.artist?.ratingKey,
            artworkPath: album.thumbPath,
            sourceKey: album.sourceCompositeKey ?? ""
        )
    }

    static func summary(_ playlist: CDPlaylist) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: playlist.ratingKey,
            kind: .playlist,
            title: playlist.title,
            subtitle: playlist.summary,
            artworkPath: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey ?? "",
            isSmart: playlist.isSmart
        )
    }

    static func track(_ stored: CDTrack) -> EnsembleTrack {
        EnsembleTrack(
            id: stored.ratingKey,
            title: stored.title,
            artistName: stored.artistName,
            albumID: stored.album?.ratingKey,
            artistID: stored.album?.artist?.ratingKey,
            albumTitle: stored.albumName,
            trackNumber: stored.trackNumber == 0 ? nil : Int(stored.trackNumber),
            discNumber: stored.discNumber == 0 ? nil : Int(stored.discNumber),
            duration: stored.durationSeconds,
            artworkPath: stored.thumbPath,
            streamKey: stored.streamKey,
            sourceKey: stored.sourceCompositeKey ?? "",
            isFavorite: stored.isFavorite?.boolValue
        )
    }

    static func identity(_ item: EnsembleMediaSummary) -> String {
        identity(id: item.id, sourceKey: item.sourceKey)
    }

    static func identity(id: String, sourceKey: String) -> String {
        "\(sourceKey)|\(id)"
    }

    static func titleAscending(_ lhs: EnsembleMediaSummary, _ rhs: EnsembleMediaSummary) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
