import EnsembleAPI
import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class PlexMusicSourceSyncProviderTests: XCTestCase {
    func testOriginalDownloadDeclaresDownloadIntentWithoutChangingPlaybackURL() async throws {
        let client = PlexAPIClient(connection: .init(url: "https://download.invalid", token: "test", identifier: "server", name: "Test"), keychain: TestKeychain())
        let source = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "3")
        let provider = PlexMusicSourceSyncProvider(sourceIdentifier: source, apiClient: client, sectionKey: "3")
        let part = "/library/parts/42/file.flac"
        let playback = try await client.getStreamURL(trackKey: part)
        let download = try await provider.getDownloadURL(for: "track", trackStreamKey: part, quality: .original)
        let playbackQuery = try XCTUnwrap(URLComponents(url: playback, resolvingAgainstBaseURL: false)?.queryItems)
        let downloadQuery = try XCTUnwrap(URLComponents(url: download, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(download.path, playback.path)
        XCTAssertEqual(downloadQuery, playbackQuery + [URLQueryItem(name: "download", value: "1")])
    }

    private final class LostAppendAcknowledgment: URLProtocol {
        static let lock = NSLock()
        static var members: [String] = []
        static var appends = 0
        static var appendHosts: [String] = []
        static var incomplete = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            if request.httpMethod == "PUT" {
                Self.members.append("track")
                Self.appends += 1
                Self.appendHosts.append(request.url?.host ?? "")
                Self.lock.unlock()
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let metadata = Self.members.map { ["ratingKey": $0, "key": "/library/metadata/" + $0, "title": "Track", "type": "track"] }
            let size = Self.incomplete ? metadata.count + 1 : metadata.count
            Self.lock.unlock()
            let body = try! JSONSerialization.data(withJSONObject: ["MediaContainer": ["size": size, "Metadata": metadata]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testPlaylistReplayDoesNotRepeatAnAcceptedAppendAndRejectsIncompleteMembership() async throws {
        LostAppendAcknowledgment.members = []
        LostAppendAcknowledgment.appends = 0
        LostAppendAcknowledgment.appendHosts = []
        LostAppendAcknowledgment.incomplete = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LostAppendAcknowledgment.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let serverID = UUID().uuidString
        let client = PlexAPIClient(
            connection: .init(url: "https://playlist.invalid", alternativeURLs: ["https://alternate-playlist.invalid"], token: "test", identifier: serverID, name: "Test"),
            keychain: TestKeychain(),
            probeURLSession: session,
            urlSession: session
        )
        let source = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: serverID, libraryId: "3")
        let provider = PlexMusicSourceSyncProvider(sourceIdentifier: source, apiClient: client, sectionKey: "3")
        let track = Track(id: "track", key: "/library/metadata/track", title: "Track", sourceCompositeKey: source.compositeKey)
        do { _ = try await provider.addTracks([track], to: "playlist"); XCTFail("Acknowledgment should be lost") }
        catch { XCTAssertTrue(PlexErrorClassification.classify(error).isRetryable) }
        XCTAssertEqual(LostAppendAcknowledgment.members, ["track"])
        XCTAssertEqual(LostAppendAcknowledgment.appendHosts, ["playlist.invalid"])
        let repeated = try await provider.addTracks([track], to: "playlist")
        XCTAssertEqual(repeated, 0)
        XCTAssertEqual(LostAppendAcknowledgment.appends, 1)
        LostAppendAcknowledgment.incomplete = true
        do { _ = try await provider.addTracks([track], to: "playlist"); XCTFail("Partial membership must not authorize another append") }
        catch { guard case PlexAPIError.invalidResponse = error else { return XCTFail("Expected incomplete response rejection") } }
        XCTAssertEqual(LostAppendAcknowledgment.appends, 1)
        XCTAssertEqual(LostAppendAcknowledgment.members, ["track"])
    }

    private struct IncrementalItem: Equatable {
        let ratingKey: String
        let updatedAt: Int?
        let marker: String
        let ratingChanged: Bool
    }

    func testIncrementalChangeSelectionDeduplicatesAndLetsUpdatedItemWin() {
        let added = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "added", ratingChanged: false)
        let updated = IncrementalItem(ratingKey: "1", updatedAt: 101, marker: "updated", ratingChanged: false)

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [added],
            updated: [updated],
            existingTimestamps: ["1": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.uniqueCount, 1)
        XCTAssertEqual(changes.changedItems, [updated])
    }

    func testIncrementalChangeSelectionSkipsUnchangedAndMissingServerTimestampWhenLocalExists() {
        let unchanged = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "unchanged", ratingChanged: false)
        let missingTimestampExisting = IncrementalItem(
            ratingKey: "2",
            updatedAt: nil,
            marker: "missing-existing",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [unchanged, missingTimestampExisting],
            updated: [],
            existingTimestamps: [
                "1": Date(timeIntervalSince1970: 100),
                "2": Date(timeIntervalSince1970: 50)
            ],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertTrue(changes.changedItems.isEmpty)
    }

    func testIncrementalChangeSelectionSyncsMissingTimestampWhenLocalIsAbsent() {
        let missingTimestampNew = IncrementalItem(
            ratingKey: "new",
            updatedAt: nil,
            marker: "missing-new",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [missingTimestampNew],
            updated: [],
            existingTimestamps: [:],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.changedItems, [missingTimestampNew])
    }

    func testIncrementalChangeSelectionAllowsAdditionalChangePredicate() {
        let ratingOnly = IncrementalItem(
            ratingKey: "track",
            updatedAt: 100,
            marker: "rating",
            ratingChanged: true
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [],
            updated: [ratingOnly],
            existingTimestamps: ["track": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt },
            hasAdditionalChange: { $0.ratingChanged }
        )

        XCTAssertEqual(changes.changedItems, [ratingOnly])
    }

    func testArtistChangeSelectionUsesMetadataWhenPlexTimestampIsStale() {
        let staleDate = Date(timeIntervalSince1970: 100)
        let unchanged = makeArtistInput(ratingKey: "unchanged", name: "Unchanged", dateModified: staleDate)
        let oldRenamed = makeArtistInput(ratingKey: "renamed", name: "Janelle Mon�e", dateModified: staleDate)
        let renamed = makeArtistInput(ratingKey: "renamed", name: "Janelle Monáe", dateModified: staleDate)
        let newArtist = makeArtistInput(ratingKey: "new", name: "New Artist", dateModified: nil)

        let changes = PlexMusicSourceSyncProvider.changedArtistInputs(
            [unchanged, renamed, newArtist],
            existingMetadata: [
                unchanged.ratingKey: ArtistSyncMetadata(unchanged),
                oldRenamed.ratingKey: ArtistSyncMetadata(oldRenamed)
            ]
        )

        XCTAssertEqual(changes.map(\.ratingKey), ["renamed", "new"])
    }

    func testTrackUpsertInputPreservesPlexTrackMetadata() throws {
        let data = Data("""
        {
            "ratingKey": "track-1",
            "key": "/library/metadata/track-1",
            "parentRatingKey": "album-1",
            "grandparentRatingKey": "artist-1",
            "title": "Track One",
            "parentTitle": "Album One",
            "grandparentTitle": "Album Artist",
            "originalTitle": "Track Artist",
            "index": 3,
            "parentIndex": 2,
            "duration": 181000,
            "parentThumb": "/library/metadata/album-1/thumb",
            "addedAt": 100,
            "updatedAt": 200,
            "lastViewedAt": 300,
            "lastRatedAt": 400,
            "userRating": 8,
            "viewCount": 5,
            "Media": [
                {
                    "id": 10,
                    "Part": [
                        {
                            "id": 20,
                            "key": "/library/parts/20/file.flac",
                            "Stream": [
                                { "id": 30, "streamType": 2, "codec": "flac" }
                            ]
                        }
                    ]
                }
            ]
        }
        """.utf8)
        let track = try JSONDecoder().decode(PlexTrack.self, from: data)

        let input = PlexMusicSourceSyncProvider.trackUpsertInput(from: track, genreNames: "Rock, Pop")

        XCTAssertEqual(input.ratingKey, "track-1")
        XCTAssertEqual(input.key, "/library/metadata/track-1")
        XCTAssertEqual(input.title, "Track One")
        XCTAssertEqual(input.artistName, "Track Artist")
        XCTAssertEqual(input.albumName, "Album One")
        XCTAssertEqual(input.albumRatingKey, "album-1")
        XCTAssertEqual(input.trackNumber, 3)
        XCTAssertEqual(input.discNumber, 2)
        XCTAssertEqual(input.duration, 181_000)
        XCTAssertEqual(input.thumbPath, "/library/metadata/album-1/thumb")
        XCTAssertEqual(input.streamKey, "/library/parts/20/file.flac")
        XCTAssertEqual(input.streamId, 30)
        XCTAssertEqual(input.dateAdded, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(input.dateModified, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(input.lastPlayed, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(input.lastRatedAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(input.rating, 8)
        XCTAssertEqual(input.playCount, 5)
        XCTAssertEqual(input.genreNames, "Rock, Pop")
    }

    func testAlbumUpsertInputPersistsAuthoritativeLeafCount() throws {
        let data = Data("""
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "title": "Album One",
            "parentTitle": "Artist One",
            "leafCount": 12
        }
        """.utf8)
        let album = try JSONDecoder().decode(PlexAlbum.self, from: data)

        let input = PlexMusicSourceSyncProvider.albumUpsertInput(from: album)

        XCTAssertEqual(input.trackCount, 12)
    }

    func testAlbumTrackCountCanBeDerivedWhenSectionAlbumOmitsLeafCount() throws {
        let album = try JSONDecoder().decode(PlexAlbum.self, from: Data(#"""
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "title": "Album One"
        }
        """#.utf8))
        let tracks = try JSONDecoder().decode([PlexTrack].self, from: Data(#"""
        [
            { "ratingKey": "track-1", "key": "/track-1", "title": "One", "parentRatingKey": "album-1" },
            { "ratingKey": "track-2", "key": "/track-2", "title": "Two", "parentRatingKey": "album-1" },
            { "ratingKey": "track-3", "key": "/track-3", "title": "Three", "parentRatingKey": "album-2" }
        ]
        """#.utf8))

        let counts = PlexMusicSourceSyncProvider.trackCountsByAlbumRatingKey(tracks)
        let input = PlexMusicSourceSyncProvider.albumUpsertInput(
            from: album,
            trackCount: counts[album.ratingKey]
        )

        XCTAssertEqual(input.trackCount, 2)
    }

    func testOrphanCheckRunsWhenItemsChanged() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckOrphans(
                changedItemCount: 1,
                lastCheckedAt: Date().timeIntervalSince1970,
                now: Date()
            )
        )
    }

    func testOrphanCheckSkipsRecentUnchangedCleanup() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldCheckOrphans(
                changedItemCount: 0,
                lastCheckedAt: 900,
                now: now,
                interval: 200
            )
        )
    }

    func testOrphanCheckRunsWhenUnchangedCleanupIsStaleOrMissing() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckOrphans(
                changedItemCount: 0,
                lastCheckedAt: 700,
                now: now,
                interval: 200
            )
        )
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckOrphans(
                changedItemCount: 0,
                lastCheckedAt: 0,
                now: now,
                interval: 200
            )
        )
    }

    func testFullMetadataReconciliationRunsWhenMissingStaleOrClockRegressed() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(PlexMusicSourceSyncProvider.shouldReconcileFullMetadata(
            lastReconciledAt: nil,
            now: now,
            interval: 200
        ))
        XCTAssertTrue(PlexMusicSourceSyncProvider.shouldReconcileFullMetadata(
            lastReconciledAt: Date(timeIntervalSince1970: 700),
            now: now,
            interval: 200
        ))
        XCTAssertTrue(PlexMusicSourceSyncProvider.shouldReconcileFullMetadata(
            lastReconciledAt: Date(timeIntervalSince1970: 1_100),
            now: now,
            interval: 200
        ))
        XCTAssertFalse(PlexMusicSourceSyncProvider.shouldReconcileFullMetadata(
            lastReconciledAt: Date(timeIntervalSince1970: 900),
            now: now,
            interval: 200
        ))
    }

    func testPlaylistTrackSyncSkipsUnchangedPlaylist() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesChangedPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 101,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesNewPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: nil
            )
        )
    }

    func testPlaylistTrackSyncSkipsExistingPlaylistWhenServerUpdatedAtIsMissing() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: nil,
                existingModifiedAt: Date.distantPast
            )
        )
    }

    func testPlaylistTrackSyncRepairsEmptyLocalBodyWhenServerHasTracks() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 0
            )
        )
    }

    func testPlaylistTrackSyncPreservesPartialLocalBodyUntilServerChanges() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 3
            )
        )
    }

    func testPlaylistTrackSyncRepairsOversizedLocalBody() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 74,
                localMembershipCount: 148
            )
        )
    }

    func testPlaylistTrackSyncDoesNotRepairCompleteBodyWhenItemIDsAreMissing() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 12,
                localMembershipCount: 12
            )
        )
    }

    func testPlaylistTrackSyncDoesNotRepairIntentionallyEmptyPlaylist() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldRepairPlaylistTracks(
                serverTrackCount: 0,
                localMembershipCount: 0
            )
        )
    }

    func testPlexProviderExposesPlaylistMutationCapability() {
        func requirePlaylistMutator<T: MusicSourcePlaylistMutating>(_: T.Type) {}

        requirePlaylistMutator(PlexMusicSourceSyncProvider.self)
    }

    func testPlaylistSeedSectionKeysKeepPrimaryFirstAndDeduplicateEnabledSections() {
        XCTAssertEqual(
            PlexMusicSourceSyncProvider.playlistSeedSectionKeys(
                primary: "7",
                enabled: ["2", "", "7", "5", "2"]
            ),
            ["7", "2", "5"]
        )
    }

    func testSeedVisibilityRetriesTransientFetchFailureAndClearsDelayedPlaylist() async throws {
        let state = DelayedPlaylistVisibilityState(
            playlist: try JSONDecoder().decode(PlexPlaylist.self, from: Data(#"""
            {
                "ratingKey": "playlist-1",
                "key": "/playlists/playlist-1",
                "title": "Delayed Empty Playlist"
            }
            """#.utf8))
        )

        let playlist = try await PlexMusicSourceSyncProvider.pollForCreatedPlaylist(
            title: "Delayed Empty Playlist",
            seededEmptyPlaylist: true,
            retryDelays: [0, 1, 1],
            fetchPlaylists: { try await state.fetchPlaylists() },
            clearPlaylistItems: { await state.clearPlaylistItems($0) },
            sleep: { _ in }
        )

        let fetchCount = await state.fetchCount
        let clearedPlaylistIDs = await state.clearedPlaylistIDs
        XCTAssertEqual(playlist?.ratingKey, "playlist-1")
        XCTAssertEqual(fetchCount, 3)
        XCTAssertEqual(clearedPlaylistIDs, ["playlist-1"])
    }

    func testSeedVisibilityFetchCancellationStopsPollingAndPropagates() async {
        let cancellations: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            PlexAPIError.networkError(URLError(.cancelled))
        ]
        for cancellation in cancellations {
            do {
                _ = try await PlexMusicSourceSyncProvider.pollForCreatedPlaylist(
                    title: "Empty Playlist",
                    seededEmptyPlaylist: true,
                    retryDelays: [0, 1],
                    fetchPlaylists: { throw cancellation },
                    clearPlaylistItems: { _ in XCTFail("Cancelled visibility cannot authorize cleanup") },
                    sleep: { _ in XCTFail("Cancelled visibility must stop further polling") }
                )
                XCTFail("Visibility fetch cancellation must propagate")
            } catch {
                XCTAssertEqual(PlexErrorClassification.classify(error), .cancelled)
            }
        }
    }

    func testSeededEmptyPlaylistCreationPropagatesClearFailureAndCancellation() async throws {
        for failure in [URLError.Code.networkConnectionLost, .cancelled, nil] {
            let (provider, session) = playlistClearProvider(failure: failure)
            defer { session.invalidateAndCancel() }
            do {
                let playlist = try await provider.createPlaylist(title: "Empty Playlist", tracks: [])
                XCTAssertNil(failure, "Unacknowledged seed cleanup must not report empty-playlist success")
                XCTAssertEqual(playlist?.trackCount, 0)
            } catch {
                XCTAssertNotNil(failure)
                XCTAssertEqual(PlexErrorClassification.classify(error), failure == .cancelled ? .cancelled : .connectionFailure)
            }
            let expected = failure == .networkConnectionLost ? ["external"] : (failure == nil ? [] : ["seed"])
            XCTAssertEqual(PlaylistClearFixture.members, expected)
        }
        for seeded in [true, false] {
            do {
                let playlist = try await PlexMusicSourceSyncProvider.pollForCreatedPlaylist(
                    title: "Invisible Playlist", seededEmptyPlaylist: seeded, retryDelays: [0],
                    fetchPlaylists: { [] },
                    clearPlaylistItems: { _ in XCTFail("Invisible playlist cannot have acknowledged cleanup") }
                )
                XCTAssertFalse(seeded, "Exhausted seeded cleanup must report failure")
                XCTAssertNil(playlist)
            } catch PlexAPIError.invalidResponse {
                XCTAssertTrue(seeded, "Non-seeded visibility exhaustion retains its nil outcome")
            }
        }
    }

    func testLegacyPlaylistReplacementStopsAfterUnacknowledgedClearAndPreservesRequestedOccurrences() async throws {
        for failure in [URLError.Code.networkConnectionLost, .cancelled, nil] {
            let (provider, session) = playlistClearProvider(failure: failure)
            defer { session.invalidateAndCancel() }
            let tracks = ["next", "next", "last"].map {
                Track(id: $0, key: "/library/metadata/\($0)", title: $0, sourceCompositeKey: provider.sourceIdentifier.compositeKey)
            }
            do {
                try await provider.replacePlaylistContents("playlist", tracks: tracks)
                XCTAssertNil(failure, "Unacknowledged clear must stop replacement before append")
            } catch {
                XCTAssertNotNil(failure)
                XCTAssertEqual(PlexErrorClassification.classify(error), failure == .cancelled ? .cancelled : .connectionFailure)
            }
            let expected = failure == .networkConnectionLost ? ["external"] : (failure == nil ? ["next", "next", "last"] : ["seed"])
            XCTAssertEqual(PlaylistClearFixture.members, expected)
        }
    }

    private func playlistClearProvider(failure: URLError.Code?) -> (PlexMusicSourceSyncProvider, URLSession) {
        PlaylistClearFixture.members = ["seed"]
        PlaylistClearFixture.clearFailure = failure
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistClearFixture.self]
        let session = URLSession(configuration: config)
        let serverID = UUID().uuidString
        let client = PlexAPIClient(
            connection: .init(url: "https://playlist-clear.invalid", alternativeURLs: ["https://alternate-clear.invalid"], token: "test", identifier: serverID, name: "Test"),
            keychain: TestKeychain(),
            probeURLSession: session,
            urlSession: session
        )
        let source = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: serverID, libraryId: "3")
        return (PlexMusicSourceSyncProvider(sourceIdentifier: source, apiClient: client, sectionKey: "3"), session)
    }

    private final class PlaylistClearFixture: URLProtocol {
        static let lock = NSLock()
        static var members: [String] = []
        static var clearFailure: URLError.Code?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let uri = query.first { $0.name == "uri" }?.value
            let ids = uri?.split(separator: "/").last?.split(separator: ",").map(String.init) ?? []
            var status = 200
            var body: [String: Any] = [:]
            switch (request.httpMethod ?? "GET", request.url?.path) {
            case ("POST", "/playlists"):
                if ids.isEmpty { status = 400 }
                else { Self.members = ids }
            case ("GET", "/library/sections/3/all"):
                body = ["MediaContainer": ["size": 1, "totalSize": 1, "Metadata": [["ratingKey": "seed"]]]]
            case ("GET", "/playlists"):
                body = ["MediaContainer": ["size": 1, "Metadata": [["ratingKey": "playlist", "key": "/playlists/playlist", "title": "Empty Playlist", "leafCount": Self.members.count]]]]
            case ("DELETE", "/playlists/playlist/items"):
                if let failure = Self.clearFailure {
                    if failure == .networkConnectionLost {
                        // The clear succeeded; another client added an occurrence before its reply was lost.
                        Self.members = ["external"]
                    }
                    Self.lock.unlock()
                    client?.urlProtocol(self, didFailWithError: URLError(failure))
                    return
                }
                Self.members.removeAll()
                status = 204
            case ("PUT", "/playlists/playlist/items"):
                Self.members.append(contentsOf: ids)
                status = 204
            case ("GET", "/playlists/playlist/items"):
                let items = Self.members.map { ["ratingKey": $0, "key": "/library/metadata/" + $0, "title": $0] }
                body = ["MediaContainer": ["size": items.count, "Metadata": items]]
            case ("GET", "/identity"): break
            default: XCTFail("Unexpected playlist fixture request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            }
            Self.lock.unlock()
            let data = try! JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testPlaylistDeleteTreatsOnlyNotFoundAsConverged() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.isConvergedPlaylistDeleteError(
                PlexAPIError.httpError(statusCode: 404)
            )
        )
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.isConvergedPlaylistDeleteError(
                PlexAPIError.httpError(statusCode: 500)
            )
        )
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.isConvergedPlaylistDeleteError(
                PlexAPIError.invalidResponse
            )
        )
    }

    func testPlaylistEditOperationsRemoveMissingItemsBeforeStableMoves() throws {
        let original = [
            makePlaylistItem("a"),
            makePlaylistItem("b"),
            makePlaylistItem("c"),
            makePlaylistItem("d")
        ]
        let edited = [
            makePlaylistItem("c"),
            makePlaylistItem("a"),
            makePlaylistItem("d")
        ]

        XCTAssertEqual(
            try PlexMusicSourceSyncProvider.playlistEditOperations(
                originalItems: original,
                editedItems: edited
            ),
            [
                .remove(itemID: "b"),
                .move(itemID: "c", afterItemID: nil)
            ]
        )
    }

    func testPlaylistEditOperationsRejectIncompleteOrForeignMemberships() {
        XCTAssertThrowsError(
            try PlexMusicSourceSyncProvider.playlistEditOperations(
                originalItems: [makePlaylistItem("a", playlistItemID: nil)],
                editedItems: []
            )
        ) { error in
            XCTAssertEqual(error as? PlaylistMutationError, .incompletePlaylistContents)
        }

        XCTAssertThrowsError(
            try PlexMusicSourceSyncProvider.playlistEditOperations(
                originalItems: [makePlaylistItem("a")],
                editedItems: [makePlaylistItem("foreign")]
            )
        ) { error in
            XCTAssertEqual(error as? PlaylistMutationError, .incompletePlaylistContents)
        }
    }

    func testDefaultPlaylistEditReplacesContentsInEditedOrder() async throws {
        let provider = DefaultEditingPlaylistProvider()
        let editedItems = [makePlaylistItem("c"), makePlaylistItem("a")]

        try await provider.editPlaylistItems(
            "playlist",
            originalItems: [makePlaylistItem("a"), makePlaylistItem("b"), makePlaylistItem("c")],
            editedItems: editedItems
        )

        let replacement = await provider.replacement
        XCTAssertEqual(replacement?.playlistID, "playlist")
        XCTAssertEqual(replacement?.trackIDs, ["c", "a"])
    }

    private func makeArtistInput(
        ratingKey: String,
        name: String,
        dateModified: Date?
    ) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)/children",
            name: name,
            summary: "Summary",
            thumbPath: "/library/metadata/\(ratingKey)/thumb/100",
            artPath: "/library/metadata/\(ratingKey)/art/100",
            dateAdded: nil,
            dateModified: dateModified
        )
    }

    private func makePlaylistItem(_ id: String) -> PlaylistItem {
        makePlaylistItem(id, playlistItemID: id)
    }

    private func makePlaylistItem(_ id: String, playlistItemID: String?) -> PlaylistItem {
        PlaylistItem(
            id: id,
            playlistItemID: playlistItemID,
            track: Track(id: id, key: "/library/metadata/\(id)", title: id)
        )
    }
}

private actor DelayedPlaylistVisibilityState {
    let playlist: PlexPlaylist
    private(set) var fetchCount = 0
    private(set) var clearedPlaylistIDs: [String] = []

    init(playlist: PlexPlaylist) {
        self.playlist = playlist
    }

    func fetchPlaylists() throws -> [PlexPlaylist] {
        fetchCount += 1
        if fetchCount == 1 { throw URLError(.networkConnectionLost) }
        return fetchCount >= 3 ? [playlist] : []
    }

    func clearPlaylistItems(_ playlistID: String) {
        clearedPlaylistIDs.append(playlistID)
    }
}

private actor DefaultEditingPlaylistProvider: MusicSourcePlaylistMutating {
    private(set) var replacement: (playlistID: String, trackIDs: [String])?
    func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? { nil }
    func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int { tracks.count }
    func renamePlaylist(_ playlistID: String, title: String) async throws {}
    func deletePlaylist(_ playlistID: String) async throws {}

    func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
        replacement = (playlistID, tracks.map(\.id))
    }
}
