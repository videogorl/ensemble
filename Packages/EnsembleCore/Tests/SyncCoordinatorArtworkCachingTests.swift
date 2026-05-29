import EnsembleAPI
import EnsemblePersistence
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EnsembleCore

@MainActor
final class SyncCoordinatorArtworkCachingTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        struct DownloadRecord {
            let url: URL
            let identity: ArtworkIdentity
        }

        let localArtworkPath: String?
        private(set) var downloadedRecords: [DownloadRecord] = []

        init(localArtworkPath: String? = nil) {
            self.localArtworkPath = localArtworkPath
        }

        var downloadedIdentities: [ArtworkIdentity] {
            downloadedRecords.map(\.identity)
        }

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { localArtworkPath }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { localArtworkPath }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { localArtworkPath }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}

        func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws {
            downloadedRecords.append(DownloadRecord(url: url, identity: identity))
        }

        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class RecordingSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
        struct ArtworkRequest: Equatable {
            let path: String?
            let size: Int
        }

        let sourceIdentifier: MusicSourceIdentifier
        private(set) var artworkRequests: [ArtworkRequest] = []

        init(sourceIdentifier: MusicSourceIdentifier) {
            self.sourceIdentifier = sourceIdentifier
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            return LibrarySyncResult(changedArtists: 1, changedAlbums: 1)
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            return LibrarySyncResult()
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1)
            return PlaylistSyncResult(changedPlaylists: 1)
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1)
            return PlaylistSyncResult()
        }

        func getStreamURL(
            for trackRatingKey: String,
            trackStreamKey: String?,
            quality: StreamingQuality,
            metadataDurationSeconds: Double?
        ) async throws -> StreamResolution {
            throw TestError.unimplemented
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? {
            artworkRequests.append(ArtworkRequest(path: path, size: size))
            return URL(string: "https://example.com\(path ?? "/artwork").jpg")
        }

        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    private enum TestError: Error {
        case unimplemented
    }

    func testFullSyncCachesDetailSizedArtworkBeforeDetailNavigationNeedsIt() async throws {
        let undersizedArtworkURL = try makeTemporaryJPEG(width: 500, height: 500)
        defer { try? FileManager.default.removeItem(at: undersizedArtworkURL) }

        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "library-1"
        )
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let artworkDownloadManager = RecordingArtworkDownloadManager(localArtworkPath: undersizedArtworkURL.path)
        let coordinator = makeCoordinator(
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager
        )
        let provider = RecordingSyncProvider(sourceIdentifier: source)
        coordinator.setSyncProvidersForTesting([source.compositeKey: provider])

        let modified = Date(timeIntervalSince1970: 1_000)
        _ = try await libraryRepository.upsertArtist(
            ratingKey: "artist-1",
            key: "/library/metadata/artist-1",
            name: "Artist",
            summary: nil,
            thumbPath: "/library/metadata/artist-1/thumb",
            artPath: nil,
            dateAdded: nil,
            dateModified: modified,
            sourceCompositeKey: source.compositeKey
        )
        _ = try await libraryRepository.upsertAlbum(
            ratingKey: "album-1",
            key: "/library/metadata/album-1",
            title: "Album",
            artistName: "Artist",
            albumArtist: "Artist",
            artistRatingKey: "artist-1",
            summary: nil,
            thumbPath: "/library/metadata/album-1/thumb",
            artPath: nil,
            year: nil,
            trackCount: nil,
            dateAdded: nil,
            dateModified: modified,
            rating: nil,
            genreNames: nil,
            sourceCompositeKey: source.compositeKey
        )
        _ = try await playlistRepository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist",
            summary: nil,
            compositePath: "/playlists/playlist-1/composite",
            isSmart: false,
            duration: nil,
            trackCount: nil,
            dateAdded: nil,
            dateModified: modified,
            lastPlayed: nil,
            sourceCompositeKey: MediaSourceIdentity.serverSourceKey(for: source)
        )

        await coordinator.syncAll()

        XCTAssertTrue(provider.artworkRequests.allSatisfy { $0.size == SyncCoordinator.fullSizeArtworkCacheDimension })
        XCTAssertTrue(provider.artworkRequests.contains(.init(path: "/library/metadata/album-1/thumb", size: ArtworkSize.detail.rawValue)))
        XCTAssertTrue(provider.artworkRequests.contains(.init(path: "/library/metadata/artist-1/thumb", size: ArtworkSize.detail.rawValue)))
        XCTAssertTrue(provider.artworkRequests.contains(.init(path: "/playlists/playlist-1/composite", size: ArtworkSize.detail.rawValue)))
        XCTAssertTrue(artworkDownloadManager.downloadedRecords.allSatisfy { $0.url.host == "example.com" })
        XCTAssertTrue(artworkDownloadManager.downloadedIdentities.contains {
            $0.ratingKey == "album-1"
                && $0.type == .album
                && $0.requestedPixelDimension == ArtworkSize.detail.rawValue
        })
        XCTAssertTrue(artworkDownloadManager.downloadedIdentities.contains {
            $0.ratingKey == "artist-1"
                && $0.type == .artist
                && $0.requestedPixelDimension == ArtworkSize.detail.rawValue
        })
        XCTAssertTrue(artworkDownloadManager.downloadedIdentities.contains {
            $0.ratingKey == "playlist-1"
                && $0.type == .playlist
                && $0.requestedPixelDimension == ArtworkSize.detail.rawValue
        })
    }

    private func makeCoordinator(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        artworkDownloadManager: ArtworkDownloadManagerProtocol
    ) -> SyncCoordinator {
        let accountManager = AccountManager(keychain: TestKeychain())
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.artwork-cache.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        coordinator.healthCheckRunnerForTesting = { _, _ in
            ServerHealthChecker.CheckSummary(checkedCount: 0, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}
        return coordinator
    }

    private func makeTemporaryJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.context
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestImageError.image
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.destination
        }
        return url
    }

    private enum TestImageError: Error {
        case context
        case image
        case destination
    }
}
