import CoreData
import EnsembleAPI
@testable import EnsembleCore
@testable import EnsemblePersistence
import XCTest

@MainActor
final class MergedArtistDetailViewModelTests: XCTestCase {
    private enum MockError: Error {
        case unimplemented
    }

    private final class LibraryRepositorySpy: LibraryRepositoryProtocol, @unchecked Sendable {
        var albumsByArtistSource: [String: [CDAlbum]] = [:]
        var tracksByArtistSource: [String: [CDTrack]] = [:]
        var albumFetches: [(artistRatingKey: String, sourceCompositeKey: String)] = []
        var trackFetches: [(artistRatingKey: String, sourceCompositeKey: String)] = []

        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
        func fetchAlbums(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDAlbum] {
            albumFetches.append((artistRatingKey, sourceCompositeKey))
            return albumsByArtistSource[Self.key(artistRatingKey, sourceCompositeKey)] ?? []
        }
        func fetchTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchSiriEligibleTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
            trackFetches.append((artistRatingKey, sourceCompositeKey))
            return tracksByArtistSource[Self.key(artistRatingKey, sourceCompositeKey)] ?? []
        }
        func fetchFavoriteTracks() async throws -> [CDTrack] { [] }
        func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? { nil }
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDTrack { throw MockError.unimplemented }
        func fetchGenres() async throws -> [CDGenre] { [] }
        func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { throw MockError.unimplemented }
        func searchTracks<Value: Sendable>(query: String, map: @escaping @Sendable ([CDTrack]) -> [Value]) async throws -> [Value] { [] }
        func searchArtists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDArtist]) -> [Value]) async throws -> [Value] { [] }
        func searchAlbums<Value: Sendable>(query: String, map: @escaping @Sendable ([CDAlbum]) -> [Value]) async throws -> [Value] { [] }
        func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] { [] }
        func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] { [] }
        func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] { [] }
        func fetchMusicSources() async throws -> [CDMusicSource] { [] }
        func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { throw MockError.unimplemented }
        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
        func deleteAllData(forSourceCompositeKey: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] { [:] }
        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {}
        func drainTrackReparentInfo() -> [TrackReparentInfo] { [] }

        static func key(_ artistRatingKey: String, _ sourceCompositeKey: String) -> String {
            "\(sourceCompositeKey)||\(artistRatingKey)"
        }
    }

    private final class PlaylistRepositoryMock: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
        func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw MockError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    }

    private final class ArtworkDownloadManagerMock: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private actor ArtistDetailProvider: MusicSourceSyncProvider, MusicSourceDetailProviding {
        let sourceIdentifier: MusicSourceIdentifier
        let albums: [Album]
        private var artistAlbumRequests = 0

        init(sourceIdentifier: MusicSourceIdentifier, albums: [Album]) {
            self.sourceIdentifier = sourceIdentifier
            self.albums = albums
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            LibrarySyncResult()
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            LibrarySyncResult()
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            PlaylistSyncResult()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            PlaylistSyncResult()
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }

        func getArtistAlbums(artistKey: String) async throws -> [Album] {
            artistAlbumRequests += 1
            return albums
        }

        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }

        func requestCount() -> Int {
            artistAlbumRequests
        }
    }

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    override func tearDown() {
        context.rollback()
        super.tearDown()
    }

    func testLoadKeepsSameNameAndSameRatingKeyArtistsSourceScoped() async throws {
        let sharedSubscriberSource = "plex:subscriber:server:3"
        let sharedFreeSource = "plex:free:server:3"
        let testLibrarySource = "plex:free:server:1"

        let artists = [
            Artist(id: "11617", key: "/library/metadata/11617", name: "AJR", sourceCompositeKey: sharedSubscriberSource),
            Artist(id: "11617", key: "/library/metadata/11617", name: "AJR", sourceCompositeKey: sharedFreeSource),
            Artist(id: "1", key: "/library/metadata/1", name: "AJR", sourceCompositeKey: testLibrarySource)
        ]
        let displayArtist = DisplayArtist.group(artists).first!
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key("11617", sharedSubscriberSource)] = [
            makeAlbum(ratingKey: "200", title: "The Maybe Man", sourceCompositeKey: sharedSubscriberSource)
        ]
        repository.albumsByArtistSource[LibraryRepositorySpy.key("11617", sharedFreeSource)] = [
            makeAlbum(ratingKey: "200", title: "The Maybe Man", sourceCompositeKey: sharedFreeSource)
        ]
        repository.albumsByArtistSource[LibraryRepositorySpy.key("1", testLibrarySource)] = [
            makeAlbum(ratingKey: "2", title: "The Maybe Man", sourceCompositeKey: testLibrarySource)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key("11617", sharedSubscriberSource)] = [
            makeTrack(ratingKey: "7551", title: "Maybe Man", sourceCompositeKey: sharedSubscriberSource)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key("11617", sharedFreeSource)] = [
            makeTrack(ratingKey: "7551", title: "Maybe Man", sourceCompositeKey: sharedFreeSource)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key("1", testLibrarySource)] = [
            makeTrack(ratingKey: "147", title: "Maybe Man", sourceCompositeKey: testLibrarySource)
        ]

        let accountManager = makeAccountManager()
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: displayArtist,
            libraryRepository: repository,
            syncCoordinator: makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository),
            accountManager: accountManager
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.sourceSections.map(\.id), [
            "\(sharedSubscriberSource)||11617",
            "\(sharedFreeSource)||11617",
            "\(testLibrarySource)||1"
        ])
        XCTAssertEqual(viewModel.sourceSections.map { $0.tracks.map(\.sourceScopedID) }, [
            ["\(sharedSubscriberSource)||7551"],
            ["\(sharedFreeSource)||7551"],
            ["\(testLibrarySource)||147"]
        ])
        XCTAssertEqual(viewModel.sourceSections.map(\.sourceTitle), [
            "Music",
            "Music",
            "Music+Test"
        ])
        XCTAssertEqual(viewModel.sourceSections.map(\.sourceSubtitle), [
            "Subscriber Server · felicity@nysics.com",
            "Free Server · felicity+test@nysics.com",
            "Free Server · felicity+test@nysics.com"
        ])
        XCTAssertEqual(repository.albumFetches.map { "\($0.artistRatingKey)|\($0.sourceCompositeKey)" }, [
            "11617|\(sharedSubscriberSource)",
            "11617|\(sharedFreeSource)",
            "1|\(testLibrarySource)"
        ])
        XCTAssertEqual(repository.trackFetches.map { "\($0.artistRatingKey)|\($0.sourceCompositeKey)" }, [
            "11617|\(sharedSubscriberSource)",
            "11617|\(sharedFreeSource)",
            "1|\(testLibrarySource)"
        ])
    }

    func testFavoritedTracksStaySourceScopedForMergedArtistSections() async throws {
        let sharedSubscriberSource = "plex:subscriber:server:3"
        let sharedFreeSource = "plex:free:server:3"
        let artists = [
            Artist(id: "11617", key: "/library/metadata/11617", name: "AJR", sourceCompositeKey: sharedSubscriberSource),
            Artist(id: "11617", key: "/library/metadata/11617", name: "AJR", sourceCompositeKey: sharedFreeSource)
        ]
        let displayArtist = DisplayArtist.group(artists).first!
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key("11617", sharedSubscriberSource)] = [
            makeAlbum(ratingKey: "200", title: "The Maybe Man", sourceCompositeKey: sharedSubscriberSource)
        ]
        repository.albumsByArtistSource[LibraryRepositorySpy.key("11617", sharedFreeSource)] = [
            makeAlbum(ratingKey: "200", title: "The Maybe Man", sourceCompositeKey: sharedFreeSource)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key("11617", sharedSubscriberSource)] = [
            makeTrack(ratingKey: "7551", title: "Maybe Man", sourceCompositeKey: sharedSubscriberSource, rating: 10),
            makeTrack(ratingKey: "7552", title: "Ordinaryish People", sourceCompositeKey: sharedSubscriberSource, rating: 6)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key("11617", sharedFreeSource)] = [
            makeTrack(ratingKey: "7551", title: "Maybe Man", sourceCompositeKey: sharedFreeSource, rating: 8)
        ]

        let accountManager = makeAccountManager()
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: displayArtist,
            libraryRepository: repository,
            syncCoordinator: makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository),
            accountManager: accountManager
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.favoritedTracks.map(\.sourceScopedID), [
            "\(sharedSubscriberSource)||7551",
            "\(sharedFreeSource)||7551"
        ])
        XCTAssertEqual(viewModel.displaySnapshot.favoritedTracks.map(\.sourceScopedID), [
            "\(sharedSubscriberSource)||7551",
            "\(sharedFreeSource)||7551"
        ])

        viewModel.filterOptions.searchText = "Ordinaryish"

        XCTAssertEqual(viewModel.displaySnapshot.filteredTracks.map(\.sourceScopedID), [
            "\(sharedSubscriberSource)||7552"
        ])
    }

    func testHidingLoadedAlbumRemovesItFromMergedArtistSnapshots() async throws {
        let source = "plex:subscriber:server:3"
        let otherSource = "plex:free:server:3"
        let artists = [
            Artist(id: "11617", key: "/library/metadata/11617", name: "Janelle Monáe", sourceCompositeKey: source),
            Artist(id: "42", key: "/library/metadata/42", name: "Janelle Monáe", sourceCompositeKey: otherSource)
        ]
        let displayArtist = DisplayArtist.group(artists).first!
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key(artists[0].id, source)] = [
            makeAlbum(ratingKey: "200", title: "The ArchAndroid", sourceCompositeKey: source)
        ]
        repository.albumsByArtistSource[LibraryRepositorySpy.key(artists[1].id, otherSource)] = [
            makeAlbum(ratingKey: "300", title: "Dirty Computer", sourceCompositeKey: otherSource)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key(artists[0].id, source)] = [
            makeTrack(ratingKey: "201", title: "Suite II Overture", sourceCompositeKey: source)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key(artists[1].id, otherSource)] = [
            makeTrack(ratingKey: "301", title: "Make Me Feel", sourceCompositeKey: otherSource)
        ]
        let accountManager = makeAccountManager()
        let suiteName = "MergedArtistDetailViewModelTests.hidden.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hiddenMediaStore = HiddenMediaStore(defaults: defaults)
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: displayArtist,
            libraryRepository: repository,
            syncCoordinator: makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository),
            accountManager: accountManager,
            hiddenMediaStore: hiddenMediaStore
        )

        await viewModel.load()
        XCTAssertEqual(viewModel.filteredAlbums.map(\.id), ["200", "300"])

        hiddenMediaStore.setHidden(
            true,
            identity: HiddenMediaIdentity(kind: .album, itemID: "200", sourceCompositeKey: source)
        )
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(viewModel.filteredAlbums.map(\.sourceScopedID), ["\(otherSource)||300"])
    }

    func testArtistDetailDisplaySnapshotCachesFilteredReleaseAndFavoriteCollections() {
        var filterOptions = FilterOptions()
        filterOptions.searchText = "maybe"
        filterOptions.sortBy = AlbumSortOption.title.rawValue
        filterOptions.sortDirection = .descending

        let snapshot = ArtistDetailDisplaySnapshot(
            albums: [
                Album(id: "album", key: "/library/metadata/album", title: "Maybe Album", sourceCompositeKey: "source", releaseFormat: .album),
                Album(id: "album-2", key: "/library/metadata/album-2", title: "Maybe Better Album", sourceCompositeKey: "source", releaseFormat: .album),
                Album(id: "single", key: "/library/metadata/single", title: "Maybe Single", sourceCompositeKey: "source", releaseFormat: .single),
                Album(id: "other", key: "/library/metadata/other", title: "Other", sourceCompositeKey: "source", releaseFormat: .album)
            ],
            tracks: [
                Track(id: "1", key: "/library/metadata/1", title: "Maybe Man", duration: 180, rating: 10, genres: ["Pop"], sourceCompositeKey: "source"),
                Track(id: "2", key: "/library/metadata/2", title: "Other Song", duration: 200, rating: 6, genres: ["Rock"], sourceCompositeKey: "source")
            ],
            filterOptions: filterOptions
        )

        XCTAssertEqual(snapshot.filteredAlbums.map(\.id), ["single", "album-2", "album"])
        XCTAssertEqual(snapshot.studioAlbums.map(\.id), ["album-2", "album"])
        XCTAssertEqual(snapshot.singlesAndEPs.map(\.id), ["single"])
        XCTAssertEqual(snapshot.filteredTracks.map(\.id), ["1"])
        XCTAssertEqual(snapshot.favoritedTracks.map(\.id), ["1"])
        XCTAssertEqual(snapshot.availableGenres, ["Pop", "Rock"])
        XCTAssertEqual(snapshot.trackCount, 1)
    }

    func testAppleMusicArtistUsesProviderNameInsteadOfUnknownLibrary() async throws {
        let source = MusicSourceIdentifier.appleMusic.compositeKey
        let artist = Artist(id: "apple-artist:ajr", key: "apple-artist:ajr", name: "AJR", sourceCompositeKey: source)
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key(artist.id, source)] = [
            makeAlbum(ratingKey: "apple-album", title: "The Maybe Man", sourceCompositeKey: source)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key(artist.id, source)] = [
            makeTrack(ratingKey: "apple-song", title: "Maybe Man", sourceCompositeKey: source)
        ]
        let accountManager = makeAccountManager()
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: DisplayArtist.group([artist]).first!,
            libraryRepository: repository,
            syncCoordinator: makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository),
            accountManager: accountManager
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.sourceSections.first?.sourceTitle, "Apple Music")
        XCTAssertEqual(viewModel.sourceSections.first?.sourceSubtitle, "Apple Music · This Device")
    }

    func testAppleMusicArtistUsesOnlyCachedLibraryAlbumsWhenOnline() async throws {
        let source = MusicSourceIdentifier.appleMusic
        let artist = Artist(
            id: "apple-artist:ajr",
            key: "apple-artist:ajr",
            name: "AJR",
            sourceCompositeKey: source.compositeKey
        )
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key(artist.id, source.compositeKey)] = [
            makeAlbum(ratingKey: "library-album", title: "The Maybe Man", sourceCompositeKey: source.compositeKey)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key(artist.id, source.compositeKey)] = [
            makeTrack(ratingKey: "library-song", title: "Maybe Man", sourceCompositeKey: source.compositeKey)
        ]
        let accountManager = makeAccountManager()
        let coordinator = makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository)
        let provider = ArtistDetailProvider(
            sourceIdentifier: source,
            albums: [
                Album(
                    id: "catalog-album",
                    key: "catalog-album",
                    title: "Catalog Only",
                    sourceCompositeKey: source.compositeKey
                )
            ]
        )
        coordinator.setSyncProvidersForTesting([source.compositeKey: provider])
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: DisplayArtist.group([artist]).first!,
            libraryRepository: repository,
            syncCoordinator: coordinator,
            accountManager: accountManager
        )

        await viewModel.load()

        let requestCount = await provider.requestCount()
        XCTAssertEqual(viewModel.albums.map(\.id), ["library-album"])
        XCTAssertEqual(requestCount, 0)
    }

    func testPlexArtistStillMergesRemoteAlbumSupplementWhenOnline() async throws {
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "subscriber",
            serverId: "server",
            libraryId: "3"
        )
        let artist = Artist(
            id: "11617",
            key: "/library/metadata/11617",
            name: "AJR",
            sourceCompositeKey: source.compositeKey
        )
        let repository = LibraryRepositorySpy()
        repository.albumsByArtistSource[LibraryRepositorySpy.key(artist.id, source.compositeKey)] = [
            makeAlbum(ratingKey: "library-album", title: "The Maybe Man", sourceCompositeKey: source.compositeKey)
        ]
        repository.tracksByArtistSource[LibraryRepositorySpy.key(artist.id, source.compositeKey)] = [
            makeTrack(ratingKey: "library-song", title: "Maybe Man", sourceCompositeKey: source.compositeKey)
        ]
        let accountManager = makeAccountManager()
        let coordinator = makeSyncCoordinator(accountManager: accountManager, libraryRepository: repository)
        let provider = ArtistDetailProvider(
            sourceIdentifier: source,
            albums: [
                Album(
                    id: "remote-album",
                    key: "/library/metadata/remote-album",
                    title: "Server Supplement",
                    sourceCompositeKey: source.compositeKey
                )
            ]
        )
        coordinator.setSyncProvidersForTesting([source.compositeKey: provider])
        let viewModel = MergedArtistDetailViewModel(
            displayArtist: DisplayArtist.group([artist]).first!,
            libraryRepository: repository,
            syncCoordinator: coordinator,
            accountManager: accountManager
        )

        await viewModel.load()

        let requestCount = await provider.requestCount()
        XCTAssertEqual(Set(viewModel.albums.map(\.id)), ["library-album", "remote-album"])
        XCTAssertEqual(requestCount, 1)
    }

    func testArtistDetailAlbumCollectionsMergeReleaseMetadataAndSortDeterministically() {
        let sourceA = "plex:account:server:1"
        let sourceB = "plex:account:server:2"
        let local = [
            Album(id: "1", key: "/library/metadata/1", title: "Beta", year: 2021, sourceCompositeKey: sourceA),
            Album(id: "2", key: "/library/metadata/2", title: "Alpha", year: 2021, sourceCompositeKey: sourceA),
            Album(id: "1", key: "/library/metadata/1", title: "Beta", year: 2021, sourceCompositeKey: sourceB)
        ]
        let remote = [
            Album(id: "1", key: "/library/metadata/1", title: "Beta", year: 2021, sourceCompositeKey: sourceA, releaseFormat: .album),
            Album(id: "2", key: "/library/metadata/2", title: "Alpha", year: 2021, sourceCompositeKey: sourceA),
            Album(id: "3", key: "/library/metadata/3", title: "Gamma", year: 2023, sourceCompositeKey: sourceA)
        ]

        let merged = ArtistDetailAlbumCollections.merged(local: local, remote: remote)

        XCTAssertEqual(merged.map(\.sourceScopedID), [
            "\(sourceA)||3",
            "\(sourceA)||2",
            "\(sourceA)||1",
            "\(sourceB)||1"
        ])
        XCTAssertEqual(merged.first { $0.sourceScopedID == "\(sourceA)||1" }?.releaseFormat, .album)
        XCTAssertNil(merged.first { $0.sourceScopedID == "\(sourceA)||2" }?.releaseFormat)
    }

    private func makeAlbum(ratingKey: String, title: String, sourceCompositeKey: String) -> CDAlbum {
        let album = CDAlbum(context: context)
        album.ratingKey = ratingKey
        album.key = "/library/metadata/\(ratingKey)"
        album.title = title
        album.artistName = "AJR"
        album.trackCount = 1
        album.sourceCompositeKey = sourceCompositeKey
        return album
    }

    private func makeTrack(
        ratingKey: String,
        title: String,
        sourceCompositeKey: String,
        rating: Int16 = 0
    ) -> CDTrack {
        let track = CDTrack(context: context)
        track.ratingKey = ratingKey
        track.key = "/library/metadata/\(ratingKey)"
        track.title = title
        track.artistName = "AJR"
        track.albumName = "The Maybe Man"
        track.duration = 180_000
        track.rating = rating
        track.sourceCompositeKey = sourceCompositeKey
        return track
    }

    private func makeAccountManager() -> AccountManager {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(PlexAccountConfig(
            id: "subscriber",
            email: "felicity@nysics.com",
            authToken: "subscriber-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Subscriber Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        manager.addPlexAccount(PlexAccountConfig(
            id: "free",
            email: "felicity+test@nysics.com",
            authToken: "free-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Free Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true),
                        PlexLibraryConfig(id: "1", key: "1", title: "Music+Test", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        return manager
    }

    private func makeSyncCoordinator(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol
    ) -> SyncCoordinator {
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.merged-artist.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        return SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: PlaylistRepositoryMock(),
            artworkDownloadManager: ArtworkDownloadManagerMock(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
    }
}
