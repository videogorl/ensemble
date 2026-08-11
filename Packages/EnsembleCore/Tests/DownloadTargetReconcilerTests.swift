import CoreData
import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence

@MainActor
final class DownloadTargetReconcilerTests: XCTestCase {
    private final class LibraryRepositoryMock: LibraryRepositoryProtocol, @unchecked Sendable {
        var tracksBySource: [String: [CDTrack]] = [:]
        var tracksByAlbum: [String: [CDTrack]] = [:]
        var tracksByArtist: [String: [CDTrack]] = [:]
        var favoriteTracks: [CDTrack] = []

        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
        func fetchTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] { tracksBySource[sourceCompositeKey] ?? [] }
        func fetchSiriEligibleTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { tracksByAlbum[albumRatingKey] ?? [] }
        func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { tracksByAlbum["\(sourceCompositeKey)|\(albumRatingKey)"] ?? [] }
        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { tracksByArtist[artistRatingKey] ?? [] }
        func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { tracksByArtist["\(sourceCompositeKey)|\(artistRatingKey)"] ?? [] }
        func fetchFavoriteTracks() async throws -> [CDTrack] { favoriteTracks }
        func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? { nil }
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDTrack { fatalError() }
        func fetchGenres() async throws -> [CDGenre] { [] }
        func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { fatalError() }
        func searchTracks(query: String) async throws -> [CDTrack] { [] }
        func searchArtists(query: String) async throws -> [CDArtist] { [] }
        func searchAlbums(query: String) async throws -> [CDAlbum] { [] }
        func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] { [] }
        func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] { [] }
        func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] { [] }
        func fetchMusicSources() async throws -> [CDMusicSource] { [] }
        func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { fatalError() }
        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
        func deleteAllData(forSourceCompositeKey: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String : Date] { [:] }
        func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String : Date] { [:] }
        func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String : Date] { [:] }
        func fetchTrackRatings(forSource sourceKey: String) async throws -> [String : Int16] { [:] }
        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {}
        func drainTrackReparentInfo() -> [TrackReparentInfo] { [] }
        func deleteMusicSource(compositeKey: String) async throws {}
        func deleteAll() async throws {}
        func save() async throws {}
        func refreshObject(_ object: NSManagedObject, mergeChanges: Bool) async {}
    }

    private final class PlaylistRepositoryMock: PlaylistRepositoryProtocol, @unchecked Sendable {
        var playlists: [String: CDPlaylist] = [:]

        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { playlists[ratingKey] }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
            playlists["\(sourceCompositeKey ?? "nil")|\(ratingKey)"] ?? playlists[ratingKey]
        }
        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { fatalError() }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String : Date] { [:] }
    }

    private final class DownloadManagerMock: DownloadManagerProtocol, @unchecked Sendable {
        var batchCreateCalls: [([OfflineTrackReference], String)] = []
        var deletedReferences: [OfflineTrackReference] = []

        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String : CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String, quality: String) async throws -> CDDownload { fatalError() }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int {
            batchCreateCalls.append((references, quality))
            return references.count
        }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {}
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws {
            deletedReferences.append(
                OfflineTrackReference(
                    trackRatingKey: trackRatingKey,
                    trackSourceCompositeKey: sourceCompositeKey
                )
            )
        }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private final class TargetRepositoryMock: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        var previousReferencesByTarget: [String: [OfflineTrackReference]] = [:]
        var membershipCounts: [OfflineTrackReference: Int] = [:]
        var replacedMemberships: [String: [OfflineTrackReference]] = [:]

        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { [] }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { nil }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget { fatalError() }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {}
        func deleteTarget(key: String) async throws {}
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws {}
        func deleteAllTargets() async throws {}
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] {
            previousReferencesByTarget[targetKey] ?? []
        }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {
            replacedMemberships[targetKey] = trackReferences
        }
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { (membershipCounts[reference] ?? 0) > 0 }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int { membershipCounts[reference] ?? 0 }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { [] }
        func totalTrackDurationMs() async throws -> Int64 { 0 }
    }

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    func testReconcileLibraryTargetDeduplicatesReferencesAndDeletesOrphans() async throws {
        let libraryRepository = LibraryRepositoryMock()
        let playlistRepository = PlaylistRepositoryMock()
        let downloadManager = DownloadManagerMock()
        let targetRepository = TargetRepositoryMock()

        let sourceKey = "plex:account:server:library"
        let duplicateA = makeTrack(ratingKey: "a", sourceCompositeKey: sourceKey)
        let duplicateB = makeTrack(ratingKey: "a", sourceCompositeKey: sourceKey)
        let unique = makeTrack(ratingKey: "b", sourceCompositeKey: sourceKey)
        libraryRepository.tracksBySource[sourceKey] = [duplicateA, duplicateB, unique]

        let removed = OfflineTrackReference(trackRatingKey: "old", trackSourceCompositeKey: sourceKey)
        targetRepository.previousReferencesByTarget["target"] = [removed]
        targetRepository.membershipCounts[removed] = 0
        var clearedLyrics: [OfflineTrackReference] = []

        let reconciler = DownloadTargetReconciler(
            dependencies: .init(
                targetRepository: targetRepository,
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                downloadManager: downloadManager,
                currentDownloadQuality: { "high" },
                clearLyricsCaches: { clearedLyrics.append(contentsOf: $0) }
            )
        )

        let result = try await reconciler.reconcileTarget(
            .init(key: "target", kind: .library, ratingKey: nil, sourceCompositeKey: sourceKey)
        )

        XCTAssertEqual(result, .init(trackReferenceCount: 2, newPendingCount: 2, downloadQuality: "high"))
        XCTAssertEqual(
            targetRepository.replacedMemberships["target"],
            [
                OfflineTrackReference(trackRatingKey: "a", trackSourceCompositeKey: sourceKey),
                OfflineTrackReference(trackRatingKey: "b", trackSourceCompositeKey: sourceKey)
            ]
        )
        XCTAssertEqual(downloadManager.deletedReferences, [removed])
        XCTAssertEqual(clearedLyrics, [removed])
    }

    func testReconcileUnchangedTargetSkipsMembershipReplacementAndCleanup() async throws {
        let libraryRepository = LibraryRepositoryMock()
        let playlistRepository = PlaylistRepositoryMock()
        let downloadManager = DownloadManagerMock()
        let targetRepository = TargetRepositoryMock()
        let sourceKey = "plex:account:server:library"
        let reference = OfflineTrackReference(
            trackRatingKey: "track",
            trackSourceCompositeKey: sourceKey
        )
        libraryRepository.tracksBySource[sourceKey] = [
            makeTrack(ratingKey: reference.trackRatingKey, sourceCompositeKey: sourceKey)
        ]
        targetRepository.previousReferencesByTarget["target"] = [reference]

        let reconciler = DownloadTargetReconciler(
            dependencies: .init(
                targetRepository: targetRepository,
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                downloadManager: downloadManager,
                currentDownloadQuality: { "high" },
                clearLyricsCaches: { _ in }
            )
        )

        let result = try await reconciler.reconcileTarget(
            .init(key: "target", kind: .library, ratingKey: nil, sourceCompositeKey: sourceKey)
        )

        XCTAssertEqual(result, .init(trackReferenceCount: 1, newPendingCount: 1, downloadQuality: "high"))
        XCTAssertTrue(targetRepository.replacedMemberships.isEmpty)
        XCTAssertEqual(downloadManager.batchCreateCalls.first?.0, [reference])
        XCTAssertTrue(downloadManager.deletedReferences.isEmpty)
    }

    func testReconcilePlaylistTargetUsesPlaylistTracks() async throws {
        let libraryRepository = LibraryRepositoryMock()
        let playlistRepository = PlaylistRepositoryMock()
        let downloadManager = DownloadManagerMock()
        let targetRepository = TargetRepositoryMock()

        let sourceKey = "plex:account:server"
        let playlist = CDPlaylist(context: context)
        let first = makeTrack(ratingKey: "1", sourceCompositeKey: sourceKey)
        let second = makeTrack(ratingKey: "2", sourceCompositeKey: sourceKey)
        let playlistTrackOne = CDPlaylistTrack(context: context)
        playlistTrackOne.track = first
        playlistTrackOne.order = 0
        let playlistTrackTwo = CDPlaylistTrack(context: context)
        playlistTrackTwo.track = second
        playlistTrackTwo.order = 1
        playlist.playlistTracks = NSSet(array: [playlistTrackOne, playlistTrackTwo])
        playlistRepository.playlists["\(sourceKey)|playlist"] = playlist

        let reconciler = DownloadTargetReconciler(
            dependencies: .init(
                targetRepository: targetRepository,
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                downloadManager: downloadManager,
                currentDownloadQuality: { "original" },
                clearLyricsCaches: { _ in }
            )
        )

        let result = try await reconciler.reconcileTarget(
            .init(key: "playlist-target", kind: .playlist, ratingKey: "playlist", sourceCompositeKey: sourceKey)
        )

        XCTAssertEqual(result.trackReferenceCount, 2)
        XCTAssertEqual(
            targetRepository.replacedMemberships["playlist-target"],
            [
                OfflineTrackReference(trackRatingKey: "1", trackSourceCompositeKey: sourceKey),
                OfflineTrackReference(trackRatingKey: "2", trackSourceCompositeKey: sourceKey)
            ]
        )
    }

    func testReconcileFavoritesExcludesAppleMusicAndRemovesItsStaleMembership() async throws {
        let libraryRepository = LibraryRepositoryMock()
        let playlistRepository = PlaylistRepositoryMock()
        let downloadManager = DownloadManagerMock()
        let targetRepository = TargetRepositoryMock()
        let appleSource = MusicSourceIdentifier.appleMusic.compositeKey
        let plexSource = "plex:account:server:library"
        let staleAppleReference = OfflineTrackReference(
            trackRatingKey: "apple",
            trackSourceCompositeKey: appleSource
        )

        libraryRepository.favoriteTracks = [
            makeTrack(ratingKey: "plex", sourceCompositeKey: plexSource),
            makeTrack(ratingKey: "apple", sourceCompositeKey: appleSource)
        ]
        targetRepository.previousReferencesByTarget["favorites"] = [staleAppleReference]
        var clearedLyrics: [OfflineTrackReference] = []

        let reconciler = DownloadTargetReconciler(
            dependencies: .init(
                targetRepository: targetRepository,
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                downloadManager: downloadManager,
                currentDownloadQuality: { "high" },
                clearLyricsCaches: { clearedLyrics.append(contentsOf: $0) }
            )
        )

        let result = try await reconciler.reconcileTarget(
            .init(key: "favorites", kind: .favorites, ratingKey: nil, sourceCompositeKey: nil)
        )

        let plexReference = OfflineTrackReference(
            trackRatingKey: "plex",
            trackSourceCompositeKey: plexSource
        )
        XCTAssertEqual(result.trackReferenceCount, 1)
        XCTAssertEqual(targetRepository.replacedMemberships["favorites"], [plexReference])
        XCTAssertEqual(downloadManager.batchCreateCalls.first?.0, [plexReference])
        XCTAssertEqual(downloadManager.deletedReferences, [staleAppleReference])
        XCTAssertEqual(clearedLyrics, [staleAppleReference])
    }

    func testReconcilePlaylistKeepsOnlyDownloadableTracksFromTargetServer() async throws {
        let libraryRepository = LibraryRepositoryMock()
        let playlistRepository = PlaylistRepositoryMock()
        let downloadManager = DownloadManagerMock()
        let targetRepository = TargetRepositoryMock()
        let targetSource = "plex:account:server"
        let matchingSource = "plex:account:server:music"

        let playlist = CDPlaylist(context: context)
        let tracks = [
            makeTrack(ratingKey: "matching", sourceCompositeKey: matchingSource),
            makeTrack(ratingKey: "other-plex", sourceCompositeKey: "plex:account:other:music"),
            makeTrack(
                ratingKey: "apple",
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
            )
        ]
        playlist.playlistTracks = NSSet(array: tracks.enumerated().map { index, track in
            let membership = CDPlaylistTrack(context: context)
            membership.track = track
            membership.order = Int32(index)
            return membership
        })
        playlistRepository.playlists["\(targetSource)|playlist"] = playlist

        let reconciler = DownloadTargetReconciler(
            dependencies: .init(
                targetRepository: targetRepository,
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                downloadManager: downloadManager,
                currentDownloadQuality: { "original" },
                clearLyricsCaches: { _ in }
            )
        )

        let result = try await reconciler.reconcileTarget(
            .init(
                key: "playlist-target",
                kind: .playlist,
                ratingKey: "playlist",
                sourceCompositeKey: targetSource
            )
        )

        let matchingReference = OfflineTrackReference(
            trackRatingKey: "matching",
            trackSourceCompositeKey: matchingSource
        )
        XCTAssertEqual(result.trackReferenceCount, 1)
        XCTAssertEqual(targetRepository.replacedMemberships["playlist-target"], [matchingReference])
        XCTAssertEqual(downloadManager.batchCreateCalls.first?.0, [matchingReference])
    }

    private func makeTrack(ratingKey: String, sourceCompositeKey: String) -> CDTrack {
        let track = CDTrack(context: context)
        track.ratingKey = ratingKey
        track.sourceCompositeKey = sourceCompositeKey
        track.title = "Track \(ratingKey)"
        return track
    }
}
