import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class LibraryViewModelCacheCleanupTests: XCTestCase {
    private struct FailingSourceCacheCleanup: SourceCacheCleaning {
        struct Failure: Error {}

        func cleanupSource(_ sourceKey: String) async throws -> SourceCacheCleanupResult {
            throw Failure()
        }

        func cleanupAllLibraryData(cachedSourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
            throw Failure()
        }
    }

    private actor CleanupRecorder {
        private var sourceKeys: [String] = []

        func record(_ sourceKey: String) {
            sourceKeys.append(sourceKey)
        }

        func recordedSourceKeys() -> [String] {
            sourceKeys
        }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        private(set) var clearArtworkCacheCallCount = 0

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}

        func clearArtworkCache() async throws {
            clearArtworkCacheCallCount += 1
        }

        func getArtworkCacheSize() async throws -> Int64 {
            0
        }
    }

    func testLoadLibraryPreservesCachedLibraryDataWhenNoAccountsExist() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        try await seedOfflineDownload(harness: harness, sourceKey: sourceKey, trackRatingKey: "track-lib-1")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let persistedSources = try await harness.libraryRepository.fetchMusicSources()
        let persistedTracks = try await harness.libraryRepository.fetchTracks()
        let persistedDownloads = try await harness.downloadManager.fetchDownloads()
        let persistedTargets = try await harness.targetRepository.fetchTargets()
        XCTAssertEqual(Set(persistedSources.map(\.compositeKey)), [sourceKey])
        XCTAssertEqual(Set(persistedTracks.compactMap(\.sourceCompositeKey)), [sourceKey])
        XCTAssertEqual(persistedDownloads.count, 1)
        XCTAssertEqual(persistedTargets.count, 1)
    }

    func testLoadLibraryPreservesCachedLibraryDataWhenConfiguredAccountHasNoEnabledLibraries() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, [sourceKey])

        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(trackSourceKeys, [sourceKey])
    }

    func testLoadLibraryPublishesCachedLibraryWhileCloudSourcesAreRestoring() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        harness.accountManager.setAwaitingCloudSources(true)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, [sourceKey])
    }

    func testLoadLibraryPublishesCachedLibraryWhenCredentialsAreUnavailable() async throws {
        let harness = makeHarness(credentialReadUnavailable: true)
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertEqual(harness.accountManager.credentialLoadState, .unavailable)
        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])
        let persistedSources = try await harness.libraryRepository.fetchMusicSources()
        XCTAssertEqual(Set(persistedSources.map(\.compositeKey)), [sourceKey])
    }

    func testLibraryReloadsWhenCloudSourceRestorationSettles() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        harness.accountManager.setAwaitingCloudSources(true)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])

        harness.accountManager.setAwaitingCloudSources(false)
        try await waitForTrackCount(viewModel: viewModel, expectedCount: 0)
    }

    func testBrowseSnapshotPreservesVisibleTracksUntilEmptySourceStateSettles() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        let readiness = AppReadinessCoordinator(
            accountManager: harness.accountManager,
            syncCoordinator: harness.syncCoordinator
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness, appReadinessCoordinator: readiness)
        await viewModel.loadLibrary()
        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: false
        )
        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertFalse(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)

        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "lib-1",
            isEnabled: false
        ))
        await Task.yield()
        await viewModel.loadLibrary()

        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: true
        )
        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertTrue(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)

        readiness.markBootstrapSettled()
        await viewModel.loadLibrary()
        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [],
            isShowingStaleSnapshot: false
        )

        XCTAssertTrue(viewModel.trackBrowseSnapshot.tracks.isEmpty)
        XCTAssertFalse(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot)
    }

    func testLoadLibraryPreparesFirstBrowseSnapshotBeforeReturning() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), [sourceKey])
        XCTAssertEqual(viewModel.trackBrowseSnapshot.sections.map(\.letter), ["T"])

        try await waitForTrackSnapshot(
            viewModel: viewModel,
            expectedSourceKeys: [sourceKey],
            isShowingStaleSnapshot: false
        )
    }

    func testLoadLibraryPublishesArtistMetadataChangesWithStableIdentity() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let metadataDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await harness.libraryRepository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist-1",
                key: "/library/metadata/artist-1",
                name: "Janelle Mon�e",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: metadataDate
            )
        ], sourceCompositeKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        try await waitForArtistName(viewModel: viewModel, expectedName: "Janelle Mon�e")

        try await harness.libraryRepository.batchUpsertArtists([
            ArtistUpsertInput(
                ratingKey: "artist-1",
                key: "/library/metadata/artist-1",
                name: "Janelle Monáe",
                summary: nil,
                thumbPath: nil,
                artPath: nil,
                dateAdded: nil,
                dateModified: metadataDate
            )
        ], sourceCompositeKey: sourceKey)
        await viewModel.loadLibrary()

        try await waitForArtistName(viewModel: viewModel, expectedName: "Janelle Monáe")
    }

    func testHiddenItemUpdatesLoadedBrowseSnapshot() async throws {
        let harness = makeHarness()
        let firstSource = "plex:account-1:server-1:lib-1"
        let secondSource = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [
                ("lib-1", "Library One", true),
                ("lib-2", "Library Two", true)
            ])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: firstSource)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: secondSource)

        let suiteName = "LibraryViewModelHiddenMediaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hiddenMediaStore = HiddenMediaStore(defaults: defaults)
        let viewModel = makeViewModel(harness: harness, hiddenMediaStore: hiddenMediaStore)
        await viewModel.loadLibrary()
        try await waitForTrackCount(viewModel: viewModel, expectedCount: 2)

        let identity = HiddenMediaIdentity(kind: .track, itemID: "track-lib-1", sourceCompositeKey: firstSource)
        hiddenMediaStore.setHidden(true, identity: identity)
        try await waitForTrackCount(viewModel: viewModel, expectedCount: 1)

        hiddenMediaStore.setHidden(false, identity: identity)
        try await waitForTrackCount(viewModel: viewModel, expectedCount: 2)
    }

    func testLoadLibraryFiltersDisabledSourcesWithoutPurgingTheirCache() async throws {
        let cleanupRecorder = CleanupRecorder()
        let harness = makeHarness { sourceKey in
            await cleanupRecorder.record(sourceKey)
            return 1
        }
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", false)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-2")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(
            Set(viewModel.tracks.compactMap(\.sourceCompositeKey)),
            ["plex:account-1:server-1:lib-1"]
        )

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(
            sourceKeys,
            ["plex:account-1:server-1:lib-1", "plex:account-1:server-1:lib-2"]
        )

        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(
            trackSourceKeys,
            ["plex:account-1:server-1:lib-1", "plex:account-1:server-1:lib-2"]
        )
        let cleanedSourceKeys = await cleanupRecorder.recordedSourceKeys()
        XCTAssertTrue(cleanedSourceKeys.isEmpty)
    }

    func testFinalSourceCleanupNotificationClearsLastGoodLibrarySnapshotAfterPurge() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        harness.syncCoordinator.refreshProviders()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()
        XCTAssertEqual(viewModel.tracks.map(\.sourceCompositeKey), [sourceKey])

        harness.accountManager.removePlexAccount(id: "account-1")
        harness.syncCoordinator.refreshProviders()
        await viewModel.loadLibrary()
        XCTAssertEqual(
            viewModel.tracks.map(\.sourceCompositeKey),
            [sourceKey],
            "The last-good snapshot should remain until explicit cleanup completes"
        )

        await harness.syncCoordinator.cleanupRemovedSource(
            MusicSourceIdentifier(
                type: .plex,
                accountId: "account-1",
                serverId: "server-1",
                libraryId: "lib-1"
            )
        )

        try await waitForTrackCount(viewModel: viewModel, expectedCount: 0)
        XCTAssertTrue(viewModel.trackBrowseSnapshot.tracks.isEmpty)
        let cachedTracks = try await harness.libraryRepository.fetchTracks()
        XCTAssertTrue(cachedTracks.isEmpty)
    }

    func testProviderRefreshKeepsUnchangedSourceWorkCurrent() {
        let harness = makeHarness()
        let firstSourceKey = "plex:account-1:server-1:lib-1"
        let secondSourceKey = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [
                ("lib-1", "Library One", true),
                ("lib-2", "Library Two", true)
            ])
        )
        harness.syncCoordinator.refreshProviders()
        let initialRevisions = Dictionary(uniqueKeysWithValues:
            harness.syncCoordinator.configuredSourceProviderRegistrations.map {
                ($0.provider.sourceIdentifier.compositeKey, $0.revision)
            }
        )

        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "lib-2",
            isEnabled: false
        ))
        harness.syncCoordinator.refreshProviders()
        let disabledRevisions = Dictionary(uniqueKeysWithValues:
            harness.syncCoordinator.configuredSourceProviderRegistrations.map {
                ($0.provider.sourceIdentifier.compositeKey, $0.revision)
            }
        )

        XCTAssertEqual(disabledRevisions[firstSourceKey], initialRevisions[firstSourceKey])
        XCTAssertNil(disabledRevisions[secondSourceKey])

        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "lib-2",
            isEnabled: true
        ))
        harness.syncCoordinator.refreshProviders()
        let restoredRevisions = Dictionary(uniqueKeysWithValues:
            harness.syncCoordinator.configuredSourceProviderRegistrations.map {
                ($0.provider.sourceIdentifier.compositeKey, $0.revision)
            }
        )

        XCTAssertEqual(restoredRevisions[firstSourceKey], initialRevisions[firstSourceKey])
        XCTAssertNotEqual(restoredRevisions[secondSourceKey], initialRevisions[secondSourceKey])
    }

    func testSourceCleanupResultReportsRemovedCounts() async throws {
        let harness = makeHarness(
            clearLyricsCache: { _ in 2 },
            clearAllLyricsCaches: { 4 }
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")

        let result = try await harness.sourceCacheCleanupService.cleanupSource("plex:account-1:server-1:lib-1")

        XCTAssertEqual(result.sourceKeys, ["plex:account-1:server-1:lib-1"])
        XCTAssertFalse(result.deletedAllLibraryData)
        XCTAssertGreaterThanOrEqual(result.libraryItemCount, 1)
        XCTAssertEqual(result.downloadRecordCount, 1)
        XCTAssertEqual(result.targetCount, 1)
        XCTAssertEqual(result.lyricsItemCount, 2)
        XCTAssertTrue(result.duration >= 0)
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testSourceCleanupDeletesOnlyExactPendingMutationsBeforeSameKeyReadd() async throws {
        let harness = makeHarness()
        let removedSourceKey = "plex:account-1:server-1:lib-1"
        let retainedSourceKey = "plex:account-2:server-2:lib-2"
        let removedSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-1"
        )
        let removedAccount = makeAccount(libraries: [("lib-1", "Library One", true)])
        harness.accountManager.addPlexAccount(removedAccount)
        harness.syncCoordinator.refreshProviders()
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "removed-pending",
            type: .trackRating,
            payload: Data(),
            sourceCompositeKey: removedSourceKey
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "removed-failed",
            type: .scrobble,
            payload: Data(),
            sourceCompositeKey: removedSourceKey
        )
        try await harness.pendingMutationRepository.markFailed(id: "removed-failed")
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "retained",
            type: .trackRating,
            payload: Data(),
            sourceCompositeKey: retainedSourceKey
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "unscoped",
            type: .scrobble,
            payload: Data(),
            sourceCompositeKey: nil
        )

        harness.accountManager.removePlexAccount(id: "account-1")
        harness.syncCoordinator.refreshProviders()
        let cleanupSucceeded = await harness.syncCoordinator.cleanupRemovedSource(removedSource)
        harness.accountManager.addPlexAccount(removedAccount)
        harness.syncCoordinator.refreshProviders()

        XCTAssertTrue(cleanupSucceeded)
        let remainingIDs = Set(try await harness.pendingMutationRepository.fetchAllMutations().map(\.id))
        XCTAssertEqual(remainingIDs, ["retained"])
    }

    func testSourceCleanupDeletesServerPlaylistMutationReferencingRemovedLibrary() async throws {
        let harness = makeHarness()
        let serverSourceKey = "plex:account-1:server-1"
        let removedSourceKey = "\(serverSourceKey):lib-1"
        let retainedSourceKey = "\(serverSourceKey):lib-2"
        let removedPayload = PlaylistMutationPayload(
            playlistRatingKey: "playlist-1",
            playlistSourceCompositeKey: serverSourceKey,
            trackReferences: [
                OfflineTrackReference(trackRatingKey: "removed", trackSourceCompositeKey: removedSourceKey),
                OfflineTrackReference(trackRatingKey: "retained", trackSourceCompositeKey: retainedSourceKey)
            ]
        )
        let retainedPayload = PlaylistMutationPayload(
            playlistRatingKey: "playlist-2",
            playlistSourceCompositeKey: serverSourceKey,
            trackReferences: [
                OfflineTrackReference(trackRatingKey: "retained", trackSourceCompositeKey: retainedSourceKey)
            ]
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "references-removed-library",
            type: .playlistAdd,
            payload: try JSONEncoder().encode(removedPayload),
            sourceCompositeKey: serverSourceKey
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "references-retained-library",
            type: .playlistAdd,
            payload: try JSONEncoder().encode(retainedPayload),
            sourceCompositeKey: serverSourceKey
        )

        _ = try await harness.sourceCacheCleanupService.cleanupSource(removedSourceKey)

        let remainingIDs = Set(try await harness.pendingMutationRepository.fetchAllMutationRecords().map(\.id))
        XCTAssertEqual(remainingIDs, ["references-retained-library"])
    }

    func testServerPlaylistCleanupDeletesOnlyThatServersPendingMutations() async throws {
        let harness = makeHarness()
        let removedServerKey = "plex:account-1:server-1"
        let retainedServerKey = "plex:account-2:server-2"
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "removed-playlist-mutation",
            type: .playlistAdd,
            payload: Data(),
            sourceCompositeKey: removedServerKey
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "retained-playlist-mutation",
            type: .playlistRemove,
            payload: Data(),
            sourceCompositeKey: retainedServerKey
        )

        await harness.syncCoordinator.cleanupServerPlaylists(
            accountId: "account-1",
            serverId: "server-1"
        )

        let remaining = try await harness.pendingMutationRepository.fetchAllMutations()
        XCTAssertEqual(remaining.map(\.id), ["retained-playlist-mutation"])
    }

    func testAllLibraryCleanupDeletesPendingFailedAndUnscopedMutations() async throws {
        let harness = makeHarness()
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "pending",
            type: .trackRating,
            payload: Data(),
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "failed",
            type: .playlistDelete,
            payload: Data(),
            sourceCompositeKey: "plex:account-1:server-1"
        )
        try await harness.pendingMutationRepository.markFailed(id: "failed")
        try await harness.pendingMutationRepository.enqueueMutation(
            id: "unscoped",
            type: .scrobble,
            payload: Data(),
            sourceCompositeKey: nil
        )

        _ = try await harness.sourceCacheCleanupService.cleanupAllLibraryData(
            cachedSourceKeys: ["plex:account-1:server-1:lib-1"]
        )

        let remaining = try await harness.pendingMutationRepository.fetchAllMutations()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAppleMusicCleanupClearsSharedArtworkCaches() async throws {
        let cleanupRecorder = CleanupRecorder()
        let harness = makeHarness(clearSharedArtworkCaches: {
            await cleanupRecorder.record("artwork")
        })
        let plexSourceKey = "plex:account-1:server-1:lib-1"
        let plexArtworkURL = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: "plex-album",
                type: .album,
                sourceCompositeKey: plexSourceKey
            )
        )
        let legacyArtworkURL = ArtworkDownloadManager.artworkDirectory.appendingPathComponent("legacy-apple_album.jpg")
        defer {
            try? harness.artworkDownloadManager.deleteArtwork(forSourceCompositeKey: plexSourceKey)
            try? FileManager.default.removeItem(at: legacyArtworkURL)
        }
        try Data("plex-artwork".utf8).write(to: plexArtworkURL)
        try Data("legacy-apple-artwork".utf8).write(to: legacyArtworkURL)

        _ = try await harness.sourceCacheCleanupService.cleanupSource(
            MusicSourceIdentifier.appleMusic.compositeKey
        )

        let calls = await cleanupRecorder.recordedSourceKeys()
        XCTAssertEqual(calls, ["artwork"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plexArtworkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyArtworkURL.path))
    }

    func testSourceCleanupWaitsForSharedPersistenceLease() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        harness.syncCoordinator.refreshProviders()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let sourceHandle = try XCTUnwrap(
            harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey)
        )

        harness.accountManager.removePlexAccount(id: "account-1")
        harness.syncCoordinator.refreshProviders()
        XCTAssertNil(harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey))

        var sourceCleanupCompleted = false
        let sourceCleanup = Task { @MainActor in
            await harness.syncCoordinator.cleanupRemovedSource(
                MusicSourceIdentifier(
                    type: .plex,
                    accountId: "account-1",
                    serverId: "server-1",
                    libraryId: "lib-1"
                )
            )
            sourceCleanupCompleted = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(sourceCleanupCompleted)

        harness.syncCoordinator.finishSourcePersistenceWork(sourceHandle)
        await sourceCleanup.value
        XCTAssertTrue(sourceCleanupCompleted)
        let remainingTracks = try await harness.libraryRepository.fetchTracks()
        XCTAssertTrue(remainingTracks.isEmpty)
    }

    func testRemovedLibraryCannotBorrowSiblingProviderPersistenceLease() throws {
        let harness = makeHarness()
        let removedSourceKey = "plex:account-1:server-1:lib-1"
        let retainedSourceKey = "plex:account-1:server-1:lib-2"
        let serverSourceKey = "plex:account-1:server-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [
                ("lib-1", "Library One", true),
                ("lib-2", "Library Two", true)
            ])
        )
        harness.syncCoordinator.refreshProviders()
        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "lib-1",
            isEnabled: false
        ))
        harness.syncCoordinator.refreshProviders()

        XCTAssertNil(harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: removedSourceKey))
        XCTAssertNil(harness.syncCoordinator.beginCurrentSourcePersistenceWork(
            sourceKeys: [serverSourceKey, removedSourceKey]
        ))
        let retainedHandle = try XCTUnwrap(
            harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: retainedSourceKey)
        )
        harness.syncCoordinator.finishSourcePersistenceWork(retainedHandle)
    }

    func testSourceCleanupPreservesSameSourceRestoredWhileWaitingForPersistence() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        let account = makeAccount(libraries: [("lib-1", "Library One", true)])
        harness.accountManager.addPlexAccount(account)
        harness.syncCoordinator.refreshProviders()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)

        let sourceHandle = try XCTUnwrap(
            harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey)
        )
        harness.accountManager.removePlexAccount(id: "account-1")
        harness.syncCoordinator.refreshProviders()

        var cleanupCompleted = false
        let cleanup = Task { @MainActor in
            let result = await harness.syncCoordinator.cleanupRemovedSource(
                MusicSourceIdentifier(
                    type: .plex,
                    accountId: "account-1",
                    serverId: "server-1",
                    libraryId: "lib-1"
                )
            )
            cleanupCompleted = true
            return result
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(cleanupCompleted)

        harness.accountManager.addPlexAccount(account)
        harness.syncCoordinator.refreshProviders()
        harness.syncCoordinator.finishSourcePersistenceWork(sourceHandle)

        let cleanupSucceeded = await cleanup.value
        XCTAssertTrue(cleanupSucceeded)
        XCTAssertTrue(cleanupCompleted)
        let remainingSources = try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey)
        XCTAssertEqual(remainingSources, [sourceKey])
    }

    func testFailedSourceCleanupReturnsFailureAndDoesNotPublishCompletion() async {
        let harness = makeHarness()
        harness.syncCoordinator.sourceCacheCleanupService = FailingSourceCacheCleanup()
        let notification = expectation(description: "source cleanup completion")
        notification.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: SyncCoordinator.sourceCleanupDidComplete,
            object: harness.syncCoordinator,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let succeeded = await harness.syncCoordinator.cleanupRemovedSource(
            MusicSourceIdentifier(
                type: .plex,
                accountId: "account-1",
                serverId: "server-1",
                libraryId: "lib-1"
            )
        )

        XCTAssertFalse(succeeded)
        await fulfillment(of: [notification], timeout: 0.2)
    }

    func testServerPlaylistCleanupWaitsForSharedPersistenceLease() async throws {
        let harness = makeHarness()
        let serverSourceKey = "plex:account-1:server-1"
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", true)])
        )
        harness.syncCoordinator.refreshProviders()
        let serverHandle = try XCTUnwrap(
            harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: serverSourceKey)
        )

        harness.accountManager.removePlexAccount(id: "account-1")
        harness.syncCoordinator.refreshProviders()
        XCTAssertNil(harness.syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: serverSourceKey))

        var serverCleanupCompleted = false
        let serverCleanup = Task { @MainActor in
            await harness.syncCoordinator.cleanupServerPlaylists(
                accountId: "account-1",
                serverId: "server-1"
            )
            serverCleanupCompleted = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(serverCleanupCompleted)

        harness.syncCoordinator.finishSourcePersistenceWork(serverHandle)
        await serverCleanup.value
        XCTAssertTrue(serverCleanupCompleted)
    }

    func testAppleMusicRemovalClearsOnlySourceOwnedFunctionalPreferences() async {
        let defaults = UserDefaults.standard
        let appleSourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let plexSourceKey = "plex:account-1:server-1"
        let genericFilterKey = "Ensemble.FilterOptions.MergedArtistDetail-single:\(appleSourceKey)||apple-artist:ajr"
        let keys = [
            "appleMusicCreatedPlaylistIDs",
            "appleMusicEditablePlaylistIDs",
            "failedHubKeys",
            "NowPlaying.LastPlaylist.ID",
            "NowPlaying.LastPlaylist.Title",
            "NowPlaying.LastPlaylist.SourceKey",
            "NowPlaying.LastPlaylist.ByServer",
            genericFilterKey
        ]
        keys.forEach(defaults.removeObject)
        defer { keys.forEach(defaults.removeObject) }

        Playlist.markAppleMusicPlaylistCreated(id: "apple-playlist")
        defaults.set(["legacy-playlist"], forKey: "appleMusicEditablePlaylistIDs")
        defaults.set([appleSourceKey, plexSourceKey], forKey: "failedHubKeys")
        defaults.set("preserve", forKey: genericFilterKey)

        let harness = makeHarness()
        let plexTarget = LastPlaylistTarget(
            id: "plex-playlist",
            title: "Plex Playlist",
            sourceCompositeKey: plexSourceKey
        )
        let appleTarget = LastPlaylistTarget(
            id: "apple-playlist",
            title: "Apple Playlist",
            sourceCompositeKey: appleSourceKey
        )
        harness.syncCoordinator.setLastPlaylistTargetForTesting(plexTarget, serverSourceKey: plexSourceKey)
        harness.syncCoordinator.setLastPlaylistTargetForTesting(appleTarget, serverSourceKey: appleSourceKey)

        await harness.syncCoordinator.cleanupRemovedSource(.appleMusic)

        XCTAssertFalse(Playlist.appleMusicPlaylistWasCreatedByEnsemble("apple-playlist"))
        XCTAssertNil(defaults.object(forKey: "appleMusicEditablePlaylistIDs"))
        XCTAssertEqual(Set(defaults.stringArray(forKey: "failedHubKeys") ?? []), [plexSourceKey])
        XCTAssertNil(harness.syncCoordinator.lastPlaylistTarget(forServerSourceKey: appleSourceKey))
        XCTAssertEqual(harness.syncCoordinator.lastPlaylistTarget(forServerSourceKey: plexSourceKey), plexTarget)
        XCTAssertNil(harness.syncCoordinator.lastPlaylistTarget)
        XCTAssertEqual(defaults.string(forKey: genericFilterKey), "preserve")
    }

    func testSourceCleanupDeletesOnlyThatSourcesDurableArtwork() async throws {
        let harness = makeHarness()
        let sourceA = "plex:account-1:server-1:lib-1"
        let sourceB = "plex:account-1:server-1:lib-2"
        let ratingKey = "shared-album-id"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceA)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceB)
        let artworkURLA = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: ratingKey,
                type: .album,
                sourceCompositeKey: sourceA
            )
        )
        let artworkURLB = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: ratingKey,
                type: .album,
                sourceCompositeKey: sourceB
            )
        )
        let identityURLA = artworkURLA.deletingPathExtension().appendingPathExtension("identity.json")
        let identityURLB = artworkURLB.deletingPathExtension().appendingPathExtension("identity.json")
        defer {
            try? harness.artworkDownloadManager.deleteArtwork(forSourceCompositeKey: sourceA)
            try? harness.artworkDownloadManager.deleteArtwork(forSourceCompositeKey: sourceB)
        }
        try Data("a".utf8).write(to: artworkURLA)
        try Data("b".utf8).write(to: artworkURLB)
        try JSONEncoder().encode(ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/artwork",
            dateModifiedSeconds: nil,
            sourceCompositeKey: sourceA
        )).write(to: identityURLA)
        try JSONEncoder().encode(ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: "/artwork",
            dateModifiedSeconds: nil,
            sourceCompositeKey: sourceB
        )).write(to: identityURLB)

        _ = try await harness.sourceCacheCleanupService.cleanupSource(sourceA)

        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURLA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: identityURLA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURLB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: identityURLB.path))
    }

    func testSourceCleanupDiscardsOnlyRemovedSourcesPendingArtworkInvalidations() async throws {
        let harness = makeHarness()
        let removedSourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let retainedSourceKey = "plex:account-1:server-1:lib-1"

        for sourceKey in [removedSourceKey, retainedSourceKey] {
            try await harness.libraryRepository.batchUpsertAlbums(
                [makeAlbumInput(thumbPath: "/old-artwork")],
                sourceCompositeKey: sourceKey
            )
            _ = try await harness.playlistRepository.upsertPlaylist(
                ratingKey: "shared-playlist",
                key: "shared-playlist",
                title: "Shared Playlist",
                summary: nil,
                compositePath: "/old-composite",
                isSmart: false,
                duration: nil,
                trackCount: nil,
                dateAdded: nil,
                dateModified: Date(timeIntervalSince1970: 1_000),
                lastPlayed: nil,
                sourceCompositeKey: sourceKey
            )
        }
        _ = harness.libraryRepository.drainArtworkInvalidationInfo()
        _ = harness.playlistRepository.drainArtworkInvalidationInfo()

        for sourceKey in [removedSourceKey, retainedSourceKey] {
            try await harness.libraryRepository.batchUpsertAlbums(
                [makeAlbumInput(thumbPath: "/new-artwork")],
                sourceCompositeKey: sourceKey
            )
            _ = try await harness.playlistRepository.upsertPlaylist(
                ratingKey: "shared-playlist",
                key: "shared-playlist",
                title: "Shared Playlist",
                summary: nil,
                compositePath: "/new-composite",
                isSmart: false,
                duration: nil,
                trackCount: nil,
                dateAdded: nil,
                dateModified: Date(timeIntervalSince1970: 2_000),
                lastPlayed: nil,
                sourceCompositeKey: sourceKey
            )
        }

        let cleanupSucceeded = await harness.syncCoordinator.cleanupRemovedSource(.appleMusic)

        XCTAssertTrue(cleanupSucceeded)
        XCTAssertEqual(
            Set(harness.libraryRepository.drainArtworkInvalidationInfo().compactMap(\.sourceCompositeKey)),
            [retainedSourceKey]
        )
        XCTAssertEqual(
            Set(harness.playlistRepository.drainArtworkInvalidationInfo().compactMap(\.sourceCompositeKey)),
            [retainedSourceKey]
        )
    }

    func testServerPlaylistCleanupDiscardsOnlyRemovedServersPendingArtworkInvalidations() async throws {
        let harness = makeHarness()
        let removedServerKey = "plex:account-1:server-1"
        let retainedServerKey = "plex:account-2:server-2"

        for sourceKey in [removedServerKey, retainedServerKey] {
            _ = try await harness.playlistRepository.upsertPlaylist(
                ratingKey: "shared-playlist",
                key: "shared-playlist",
                title: "Shared Playlist",
                summary: nil,
                compositePath: "/old-composite",
                isSmart: false,
                duration: nil,
                trackCount: nil,
                dateAdded: nil,
                dateModified: Date(timeIntervalSince1970: 1_000),
                lastPlayed: nil,
                sourceCompositeKey: sourceKey
            )
        }
        _ = harness.playlistRepository.drainArtworkInvalidationInfo()

        for sourceKey in [removedServerKey, retainedServerKey] {
            _ = try await harness.playlistRepository.upsertPlaylist(
                ratingKey: "shared-playlist",
                key: "shared-playlist",
                title: "Shared Playlist",
                summary: nil,
                compositePath: "/new-composite",
                isSmart: false,
                duration: nil,
                trackCount: nil,
                dateAdded: nil,
                dateModified: Date(timeIntervalSince1970: 2_000),
                lastPlayed: nil,
                sourceCompositeKey: sourceKey
            )
        }

        await harness.syncCoordinator.cleanupServerPlaylists(
            accountId: "account-1",
            serverId: "server-1"
        )

        XCTAssertEqual(
            Set(harness.playlistRepository.drainArtworkInvalidationInfo().compactMap(\.sourceCompositeKey)),
            [retainedServerKey]
        )
    }

    func testSourceCleanupRemovesDownloadFilesAndOrphanedSidecars() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        let trackRatingKey = "track-lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let fileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: sourceKey,
            trackRatingKey: trackRatingKey
        )
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        let orphanSidecarURL = DownloadManager.downloadsDirectory
            .appendingPathComponent("orphan-sidecar-\(UUID().uuidString).mp3.freq")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: sidecarURL)
            try? FileManager.default.removeItem(at: orphanSidecarURL)
        }
        try Data("orphan".utf8).write(to: orphanSidecarURL)

        let result = try await harness.sourceCacheCleanupService.cleanupSource(sourceKey)

        XCTAssertEqual(result.sourceKeys, [sourceKey])
        XCTAssertEqual(result.downloadRecordCount, 1)
        XCTAssertEqual(result.targetCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanSidecarURL.path))
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testRemoteLibraryDisableCleansSourceDownloadsAndPreservesEnabledSource() async throws {
        let harness = makeHarness()
        let enabledSourceKey = "plex:account-1:server-1:lib-1"
        let disabledSourceKey = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", true)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: enabledSourceKey)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: disabledSourceKey)

        let keptFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: enabledSourceKey,
            trackRatingKey: "track-lib-1"
        )
        let removedFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: disabledSourceKey,
            trackRatingKey: "track-lib-2"
        )
        let keptSidecarURL = URL(fileURLWithPath: keptFileURL.path + ".freq")
        let removedSidecarURL = URL(fileURLWithPath: removedFileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: keptFileURL)
            try? FileManager.default.removeItem(at: keptSidecarURL)
            try? FileManager.default.removeItem(at: removedFileURL)
            try? FileManager.default.removeItem(at: removedSidecarURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedFileURL.path))

        let result = harness.accountManager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:lib-1": true,
                "account-1:server-1:lib-2": false
            ])
        )
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), [disabledSourceKey])

        await harness.syncCoordinator.cleanupRemovedSourcesIfPresent(result.disabledSources)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedSidecarURL.path))
        let keptDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: enabledSourceKey)
        let removedDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: disabledSourceKey)
        let targetSourceKeys = Set(try await harness.targetRepository.fetchTargets().compactMap(\.sourceCompositeKey))
        let cachedSourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(keptDownloadCount, 1)
        XCTAssertEqual(removedDownloadCount, 0)
        XCTAssertEqual(targetSourceKeys, [enabledSourceKey])
        XCTAssertEqual(cachedSourceKeys, [enabledSourceKey])
        XCTAssertEqual(trackSourceKeys, [enabledSourceKey])
    }

    func testRemoteDisabledLibraryFlagCleansAlreadyDisabledSourceDownloads() async throws {
        let harness = makeHarness()
        let enabledSourceKey = "plex:account-1:server-1:lib-1"
        let disabledSourceKey = "plex:account-1:server-1:lib-2"
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", false)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: enabledSourceKey)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: disabledSourceKey)

        let keptFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: enabledSourceKey,
            trackRatingKey: "track-lib-1"
        )
        let removedFileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: disabledSourceKey,
            trackRatingKey: "track-lib-2"
        )
        let keptSidecarURL = URL(fileURLWithPath: keptFileURL.path + ".freq")
        let removedSidecarURL = URL(fileURLWithPath: removedFileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: keptFileURL)
            try? FileManager.default.removeItem(at: keptSidecarURL)
            try? FileManager.default.removeItem(at: removedFileURL)
            try? FileManager.default.removeItem(at: removedSidecarURL)
        }

        let result = harness.accountManager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:lib-1": true,
                "account-1:server-1:lib-2": false
            ])
        )
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), [disabledSourceKey])

        await harness.syncCoordinator.cleanupRemovedSourcesIfPresent(result.disabledSources)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedSidecarURL.path))
        let keptDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: enabledSourceKey)
        let removedDownloadCount = try await harness.downloadManager.countDownloads(forSourceCompositeKey: disabledSourceKey)
        let targetSourceKeys = Set(try await harness.targetRepository.fetchTargets().compactMap(\.sourceCompositeKey))
        let cachedSourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(keptDownloadCount, 1)
        XCTAssertEqual(removedDownloadCount, 0)
        XCTAssertEqual(targetSourceKeys, [enabledSourceKey])
        XCTAssertEqual(cachedSourceKeys, [enabledSourceKey])
        XCTAssertEqual(trackSourceKeys, [enabledSourceKey])
    }

    func testCacheManagerClearAllCachesUsesSourceCleanupWorker() async throws {
        let harness = makeHarness(clearAllLyricsCaches: { 3 })
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService

        try await cacheManager.clearAllCaches()

        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testCacheManagerClearAllCachesDeletesDownloadedFilesFromDisk() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        let trackRatingKey = "track-lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let fileURL = try await seedCompletedOfflineDownloadFile(
            harness: harness,
            sourceKey: sourceKey,
            trackRatingKey: trackRatingKey
        )
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService

        try await cacheManager.clearAllCaches()

        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    func testCacheManagerClearAllCachesPostsLibraryDataClearNotification() async throws {
        let harness = makeHarness()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        cacheManager.sourceCacheCleanupService = harness.sourceCacheCleanupService
        let notification = expectation(description: "library data clear notification")
        let observer = NotificationCenter.default.addObserver(
            forName: CacheManager.libraryDataDidClear,
            object: cacheManager,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await cacheManager.clearAllCaches()

        await fulfillment(of: [notification], timeout: 1)
    }

    func testCacheManagerClearArtworkCachesPreservesLibraryAndDownloadState() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        try await seedOfflineDownload(harness: harness, sourceKey: sourceKey, trackRatingKey: "track-lib-1")
        let artworkDownloadManager = RecordingArtworkDownloadManager()
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: artworkDownloadManager,
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )

        let before = try await cacheManager.cleanupSnapshot()
        XCTAssertEqual(before.libraryItemCount, 1)
        XCTAssertEqual(before.sourceCount, 1)
        XCTAssertEqual(before.downloadRecordCount, 1)
        XCTAssertEqual(cacheManager.artworkCacheInvalidationGeneration, 0)

        let resetNotification = expectation(description: "artwork consumers reset once")
        resetNotification.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: CacheManager.artworkCachesDidClear,
            object: cacheManager,
            queue: nil
        ) { _ in
            resetNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await cacheManager.clearArtworkCaches()
        await fulfillment(of: [resetNotification], timeout: 1)

        let after = try await cacheManager.cleanupSnapshot()
        XCTAssertEqual(after.libraryItemCount, before.libraryItemCount)
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.downloadRecordCount, before.downloadRecordCount)
        XCTAssertEqual(after.completedDownloadCount, before.completedDownloadCount)
        let targets = try await harness.targetRepository.fetchTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(artworkDownloadManager.clearArtworkCacheCallCount, 1)
        XCTAssertEqual(cacheManager.artworkCacheInvalidationGeneration, 1)
    }

    func testCacheManagerClearArtworkCachesDoesNotPostLibraryDataClearNotification() async throws {
        let harness = makeHarness()
        let sourceKey = "plex:account-1:server-1:lib-1"
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceKey)
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: RecordingArtworkDownloadManager(),
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator)
        )
        let notification = expectation(description: "library data clear notification should not fire")
        notification.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: CacheManager.libraryDataDidClear,
            object: cacheManager,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await cacheManager.clearArtworkCaches()

        await fulfillment(of: [notification], timeout: 0.2)
    }

    func testCacheManagerDelegatesArtworkClearToLoaderOnce() async throws {
        let harness = makeHarness()
        let artworkDownloadManager = RecordingArtworkDownloadManager()
        var loaderClearCount = 0
        let cacheManager = CacheManager(
            libraryRepository: harness.libraryRepository,
            artworkDownloadManager: artworkDownloadManager,
            downloadManager: harness.downloadManager,
            lyricsService: LyricsService(syncCoordinator: harness.syncCoordinator),
            artworkCacheClear: { loaderClearCount += 1 }
        )

        try await cacheManager.clearArtworkCaches()

        XCTAssertEqual(loaderClearCount, 1)
        XCTAssertEqual(artworkDownloadManager.clearArtworkCacheCallCount, 0)
        XCTAssertEqual(cacheManager.artworkCacheInvalidationGeneration, 1)
    }

    private struct Harness {
        let accountManager: AccountManager
        let syncCoordinator: SyncCoordinator
        let libraryRepository: LibraryRepository
        let playlistRepository: PlaylistRepository
        let downloadManager: DownloadManager
        let targetRepository: OfflineDownloadTargetRepository
        let pendingMutationRepository: PendingMutationRepository
        let artworkDownloadManager: ArtworkDownloadManager
        let sourceCacheCleanupService: SourceCacheCleaning
    }

    private func makeHarness(
        credentialReadUnavailable: Bool = false,
        clearLyricsCache: @escaping SourceCacheCleanupService.LyricsCacheCleanup = { _ in 0 },
        clearAllLyricsCaches: @escaping SourceCacheCleanupService.AllLyricsCacheCleanup = { 0 },
        clearSharedArtworkCaches: @escaping SourceCacheCleanupService.SharedArtworkCacheCleanup = {}
    ) -> Harness {
        let keychain = TestKeychain()
        if credentialReadUnavailable {
            keychain.localReadFailure = .unavailable
        }
        let accountManager = AccountManager(keychain: keychain)
        accountManager.loadAccounts()
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let targetRepository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let pendingMutationRepository = PendingMutationRepository(coreDataStack: stack)
        let artworkDownloadManager = ArtworkDownloadManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.library-cache-cleanup.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        let sourceCacheCleanupService = SourceCacheCleanupService(
            libraryRepository: libraryRepository,
            hubRepository: HubRepository(coreDataStack: stack),
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            pendingMutationRepository: pendingMutationRepository,
            artworkDownloadManager: artworkDownloadManager,
            fetchArtworkRatingKeys: { sourceKey in
                try await libraryRepository.fetchArtworkRatingKeys(forSourceCompositeKey: sourceKey)
            },
            countLibraryItemsForSource: { sourceKey in
                try await libraryRepository.countLibraryItems(forSourceCompositeKey: sourceKey)
            },
            countAllLibraryItems: {
                try await libraryRepository.countAllLibraryItems()
            },
            countTargetsForSource: { sourceKey in
                try await targetRepository.countTargets(forSourceCompositeKey: sourceKey)
            },
            countAllTargets: {
                try await targetRepository.countAllTargets()
            },
            countArtworkItems: {
                try await artworkDownloadManager.getArtworkCacheFileCount()
            },
            clearLyricsCache: clearLyricsCache,
            clearAllLyricsCaches: clearAllLyricsCaches,
            clearSharedArtworkCaches: clearSharedArtworkCaches
        )
        syncCoordinator.sourceCacheCleanupService = sourceCacheCleanupService

        return Harness(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            pendingMutationRepository: pendingMutationRepository,
            artworkDownloadManager: artworkDownloadManager,
            sourceCacheCleanupService: sourceCacheCleanupService
        )
    }

    private func waitForDeferredCleanup(
        repository: LibraryRepository,
        expectedSourceKeys: Set<String> = []
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
            let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
            if sourceKeys == expectedSourceKeys && trackSourceKeys == expectedSourceKeys {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(sourceKeys, expectedSourceKeys)
        XCTAssertEqual(trackSourceKeys, expectedSourceKeys)
    }

    private func waitForDeferredOfflineCleanup(harness: Harness) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let downloads = try await harness.downloadManager.fetchDownloads()
            let targets = try await harness.targetRepository.fetchTargets()
            if downloads.isEmpty && targets.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let downloads = try await harness.downloadManager.fetchDownloads()
        let targets = try await harness.targetRepository.fetchTargets()
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    private func waitForTrackCount(viewModel: LibraryViewModel, expectedCount: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.tracks.count == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.tracks.count, expectedCount)
    }

    private func waitForTrackSnapshot(
        viewModel: LibraryViewModel,
        expectedSourceKeys: [String],
        isShowingStaleSnapshot: Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sourceKeys = viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey)
            if sourceKeys == expectedSourceKeys,
               viewModel.trackBrowseSnapshot.isShowingStaleSnapshot == isShowingStaleSnapshot {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.trackBrowseSnapshot.tracks.compactMap(\.sourceCompositeKey), expectedSourceKeys)
        XCTAssertEqual(viewModel.trackBrowseSnapshot.isShowingStaleSnapshot, isShowingStaleSnapshot)
    }

    private func waitForArtistName(viewModel: LibraryViewModel, expectedName: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.artistBrowseSnapshot.displayArtists.first?.name == expectedName {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.artistBrowseSnapshot.displayArtists.first?.name, expectedName)
    }

    private func makeViewModel(
        harness: Harness,
        hiddenMediaStore: HiddenMediaStore? = nil,
        appReadinessCoordinator: AppReadinessCoordinator? = nil
    ) -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: harness.libraryRepository,
            syncCoordinator: harness.syncCoordinator,
            accountManager: harness.accountManager,
            visibilityStore: LibraryVisibilityStore(),
            hiddenMediaStore: hiddenMediaStore,
            toastCenter: ToastCenter(),
            appReadinessCoordinator: appReadinessCoordinator
        )
    }

    private func makeAccount(
        libraries: [(key: String, title: String, enabled: Bool)]
    ) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            email: "user@example.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: libraries.map { library in
                        PlexLibraryConfig(
                            id: library.key,
                            key: library.key,
                            title: library.title,
                            isEnabled: library.enabled
                        )
                    }
                )
            ]
        )
    }

    private func makeFlagsData(_ flags: [String: Bool]) throws -> Data {
        try JSONEncoder().encode(flags)
    }

    private func seedSourceAndTrack(repository: LibraryRepository, sourceKey: String) async throws {
        let parts = sourceKey.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 4)
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: parts[0],
            accountId: parts[1],
            serverId: parts[2],
            libraryId: parts[3],
            displayName: "Library \(parts[3])",
            accountName: "Felicity"
        )

        _ = try await repository.upsertTrack(
            ratingKey: "track-\(parts[3])",
            key: "track-\(parts[3])",
            title: "Track \(parts[3])",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 120_000,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: sourceKey
        )
    }

    private func makeAlbumInput(thumbPath: String) -> AlbumUpsertInput {
        AlbumUpsertInput(
            ratingKey: "shared-album",
            key: "shared-album",
            title: "Shared Album",
            artistName: nil,
            albumArtist: nil,
            artistRatingKey: nil,
            summary: nil,
            thumbPath: thumbPath,
            artPath: nil,
            year: nil,
            trackCount: nil,
            dateAdded: nil,
            dateModified: nil,
            rating: nil
        )
    }

    private func seedOfflineDownload(harness: Harness, sourceKey: String, trackRatingKey: String) async throws {
        _ = try await harness.downloadManager.createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceKey,
            quality: "high"
        )
        _ = try await harness.targetRepository.upsertTarget(
            key: "library:\(sourceKey)",
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: sourceKey,
            displayName: "Library"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "library:\(sourceKey)",
            trackReferences: [
                OfflineTrackReference(trackRatingKey: trackRatingKey, trackSourceCompositeKey: sourceKey)
            ]
        )
    }

    private func seedCompletedOfflineDownloadFile(
        harness: Harness,
        sourceKey: String,
        trackRatingKey: String
    ) async throws -> URL {
        let download = try await harness.downloadManager.createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceKey,
            quality: "high"
        )
        let filename = "cleanup-test-\(UUID().uuidString).mp3"
        let fileURL = DownloadManager.downloadsDirectory.appendingPathComponent(filename)
        let sidecarURL = URL(fileURLWithPath: fileURL.path + ".freq")
        try Data("audio".utf8).write(to: fileURL)
        try Data("sidecar".utf8).write(to: sidecarURL)
        try await harness.downloadManager.completeDownload(
            download.objectID,
            filePath: fileURL.path,
            fileSize: 5,
            quality: "high"
        )
        _ = try await harness.targetRepository.upsertTarget(
            key: "library:\(sourceKey)",
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: sourceKey,
            displayName: "Library"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "library:\(sourceKey)",
            trackReferences: [
                OfflineTrackReference(trackRatingKey: trackRatingKey, trackSourceCompositeKey: sourceKey)
            ]
        )
        return fileURL
    }
}
