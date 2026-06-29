import XCTest
@testable import EnsembleAPI

final class PlexAPIClientTests: XCTestCase {
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

    func testPlexModelsDecoding() throws {
        // Test PlexTrack decoding
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "Test Song",
            "parentTitle": "Test Album",
            "grandparentTitle": "Test Artist",
            "duration": 180000
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: trackJSON.data(using: .utf8)!)
        XCTAssertEqual(track.ratingKey, "12345")
        XCTAssertEqual(track.title, "Test Song")
        XCTAssertEqual(track.durationSeconds, 180.0)
    }

    func testPlexTrackExposesAudioStreamId() throws {
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "Test Song",
            "Media": [
                {
                    "Part": [
                        {
                            "key": "/library/parts/12345",
                            "Stream": [
                                { "id": 111, "streamType": 4 },
                                { "id": 222, "streamType": 2 }
                            ]
                        }
                    ]
                }
            ]
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(trackJSON.utf8))
        XCTAssertEqual(track.audioStreamId, 222)
    }

    func testPlexAlbumDecodesFormatTags() throws {
        let albumJSON = """
        {
            "ratingKey": "12321",
            "key": "/library/metadata/12321/children",
            "title": "A Little Rhythm and a Wicked Feeling",
            "Format": [
                {
                    "id": 32101,
                    "filter": "format=32101",
                    "tag": "EP"
                }
            ]
        }
        """

        let album = try JSONDecoder().decode(PlexAlbum.self, from: Data(albumJSON.utf8))
        XCTAssertEqual(album.format?.map(\.tag), ["EP"])
    }

    func testPlexLibraryFormatFiltersDecode() throws {
        let filtersJSON = """
        {
            "MediaContainer": {
                "Directory": [
                    {
                        "fastKey": "/library/sections/3/all?format=31744",
                        "key": "31744",
                        "title": "Album"
                    },
                    {
                        "fastKey": "/library/sections/3/all?format=32101",
                        "key": "32101",
                        "title": "EP"
                    }
                ]
            }
        }
        """

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexLibraryFilterValue>.self,
            from: Data(filtersJSON.utf8)
        )
        XCTAssertEqual(container.mediaContainer.items.map(\.key), ["31744", "32101"])
        XCTAssertEqual(container.mediaContainer.items.map(\.title), ["Album", "EP"])
    }

    func testPlexLibrarySectionDecodesUpdatedAt() throws {
        let sectionJSON = """
        {
            "MediaContainer": {
                "Directory": [
                    {
                        "key": "3",
                        "title": "Music",
                        "type": "artist",
                        "updatedAt": 1782502159
                    }
                ]
            }
        }
        """

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexLibrarySection>.self,
            from: Data(sectionJSON.utf8)
        )
        XCTAssertEqual(container.mediaContainer.items.first?.updatedAt, 1782502159)
    }

    func testPlexTrackDecodesMultipleLyricsStreamsAndSidecarFile() throws {
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "Test Song",
            "Media": [
                {
                    "Part": [
                        {
                            "key": "/library/parts/12345",
                            "Stream": [
                                {
                                    "id": 111,
                                    "streamType": 4,
                                    "key": "/library/streams/111",
                                    "codec": "lrc",
                                    "format": "lrc",
                                    "timed": 1,
                                    "provider": "com.plexapp.agents.lyricfind"
                                },
                                {
                                    "id": 222,
                                    "streamType": 4,
                                    "key": "/library/streams/222",
                                    "codec": "lrc",
                                    "format": "lrc",
                                    "timed": 1,
                                    "provider": "localmedia",
                                    "file": "/music/Test Song.chord.lrc"
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(trackJSON.utf8))
        XCTAssertEqual(track.lyricsStreams.map(\.id), [111, 222])
        XCTAssertEqual(track.normalLyricsStreams.map(\.id), [111])
        XCTAssertEqual(track.lyricsStream?.id, 111)
        XCTAssertEqual(track.chordCandidateStreams.map(\.id), [222])
        XCTAssertEqual(track.chordCandidateStreams.first?.file, "/music/Test Song.chord.lrc")
    }

    func testPlexTrackNormalLyricsStreamsPreferTimedButKeepUntimedFallbacks() throws {
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "Test Song",
            "Media": [
                {
                    "Part": [
                        {
                            "Stream": [
                                {
                                    "id": 100,
                                    "streamType": 2,
                                    "codec": "mp3"
                                },
                                {
                                    "id": 111,
                                    "streamType": 4,
                                    "key": "/library/streams/111",
                                    "codec": "txt",
                                    "format": "txt",
                                    "timed": 0,
                                    "provider": "localmedia",
                                    "file": "/music/Test Song.txt"
                                },
                                {
                                    "id": 222,
                                    "streamType": 4,
                                    "key": "/library/streams/222",
                                    "codec": "lrc",
                                    "format": "lrc",
                                    "timed": 1,
                                    "provider": "com.plexapp.agents.lyricfind"
                                },
                                {
                                    "id": 333,
                                    "streamType": 4,
                                    "key": "/library/streams/333",
                                    "codec": "lrc",
                                    "format": "lrc",
                                    "timed": 1,
                                    "provider": "localmedia",
                                    "file": "/music/Test Song.chord.lrc"
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(trackJSON.utf8))

        XCTAssertEqual(track.normalLyricsStreams.map(\.id), [222, 111])
        XCTAssertEqual(track.lyricsStream?.id, 222)
        XCTAssertEqual(track.chordCandidateStreams.map(\.id), [111, 333])
    }

    func testPlexRequestBuilderCanRequestPlainTextForRawLyrics() throws {
        let context = PlexRequestHeaderContext(
            clientIdentifier: "test-client",
            productName: "EnsembleTests",
            productVersion: "1",
            platformName: "iOS",
            deviceName: "Simulator"
        )
        let request = try PlexRequestBuilder(
            baseURL: "https://example.test",
            token: "token",
            headerContext: context
        ).makeRequest(
            method: "GET",
            path: "/library/streams/123",
            query: ["format": "lrc"],
            accept: "text/plain"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
        XCTAssertEqual(request.url?.query?.contains("format=lrc"), true)
    }

    func testPlexTrackDecodingFallsBackToFileNameWhenTitleMissing() throws {
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "",
            "Media": [
                {
                    "Part": [
                        { "file": "/music/Boards of Canada/Geogaddi/1969.mp3" }
                    ]
                }
            ]
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: Data(trackJSON.utf8))
        XCTAssertEqual(track.title, "1969")
        XCTAssertEqual(track.parentTitle, "Geogaddi")
    }

    func testPlexAlbumDecodingFallsBackToDirectoryNameWhenTitleMissing() throws {
        let albumJSON = """
        {
            "ratingKey": "album-1",
            "key": "/library/metadata/album-1",
            "title": "   ",
            "Media": [
                {
                    "Part": [
                        { "file": "/music/Boards of Canada/Music Has the Right to Children/Turquoise Hexagon Sun.mp3" }
                    ]
                }
            ]
        }
        """

        let album = try JSONDecoder().decode(PlexAlbum.self, from: Data(albumJSON.utf8))
        XCTAssertEqual(album.title, "Music Has the Right to Children")
    }

    func testPlexDeviceDecoding() throws {
        let deviceJSON = """
        {
            "name": "My Plex Server",
            "product": "Plex Media Server",
            "productVersion": "1.32.0",
            "platform": "Linux",
            "clientIdentifier": "abc123",
            "provides": "server",
            "owned": true,
            "connections": [
                {
                    "uri": "https://192.168.1.100:32400",
                    "local": true
                }
            ]
        }
        """

        let device = try JSONDecoder().decode(PlexDevice.self, from: deviceJSON.data(using: .utf8)!)
        XCTAssertEqual(device.name, "My Plex Server")
        XCTAssertTrue(device.isServer)
        XCTAssertNotNil(device.bestConnection)
    }

    func testServerCapabilitiesExposeTriStateFeatureSupport() {
        let unknown = PlexServerCapabilities()
        XCTAssertEqual(unknown.lyricsSupport, .unknown)
        XCTAssertEqual(unknown.radioSupport, .unknown)
        XCTAssertEqual(unknown.plexPassSupport, .unknown)

        let unsupported = PlexServerCapabilities(
            myPlexSubscription: false,
            ownerFeatures: "collections,home"
        )
        XCTAssertEqual(unsupported.lyricsSupport, .unsupported)
        XCTAssertEqual(unsupported.radioSupport, .unsupported)
        XCTAssertEqual(unsupported.plexPassSupport, .unsupported)

        let supported = PlexServerCapabilities(
            myPlexSubscription: nil,
            ownerFeatures: "lyrics,shared-radio,pass"
        )
        XCTAssertEqual(supported.lyricsSupport, .supported)
        XCTAssertEqual(supported.radioSupport, .supported)
        XCTAssertEqual(supported.plexPassSupport, .supported)
    }

    func testDeletePlaylistBuildsDeleteRequest() async throws {
        let keychain = TestKeychain()
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "token123",
                identifier: "server",
                name: "Server"
            ),
            keychain: keychain
        )

        let request = try await client.makeServerRequest(
            url: "https://example.com",
            method: "DELETE",
            path: "/playlists/abc123"
        )

        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/playlists/abc123")
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "X-Plex-Token" })?
                .value,
            "token123"
        )
    }

    func testMakeServerRequestRejectsInvalidBaseURL() async {
        let keychain = TestKeychain()
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "token123",
                identifier: "server",
                name: "Server"
            ),
            keychain: keychain
        )

        do {
            _ = try await client.makeServerRequest(
                url: "http://%",
                method: "GET",
                path: "/library/sections"
            )
            XCTFail("Expected invalidURL error")
        } catch {
            guard case PlexAPIError.invalidURL = error else {
                XCTFail("Expected invalidURL, got \(error)")
                return
            }
        }
    }

    func testServerRequestsSkipURLSessionWhenNetworkUnavailable() async {
        let keychain = TestKeychain()
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "token123",
                identifier: "server",
                name: "Server"
            ),
            keychain: keychain,
            isNetworkAvailable: { false }
        )

        do {
            _ = try await client.getLibrarySections()
            XCTFail("Expected offline network error")
        } catch PlexAPIError.networkError(let error as URLError) {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Expected notConnectedToInternet, got \(error)")
        }
    }

    func testServerRequestCancellationIsNotWrappedAsNetworkError() async {
        let keychain = TestKeychain()
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "token123",
                identifier: "server",
                name: "Server"
            ),
            keychain: keychain,
            isNetworkAvailable: {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return true
            }
        )

        let task = Task {
            try await client.getLibrarySections()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation should not be logged/retried as a network failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testBatchTrackFetchDecodesMultipleTracks() throws {
        // Test batch metadata response with multiple tracks
        let batchJSON = """
        {
            "MediaContainer": {
                "size": 3,
                "Metadata": [
                    {
                        "ratingKey": "12345",
                        "key": "/library/metadata/12345",
                        "title": "Track One",
                        "parentTitle": "Album",
                        "grandparentTitle": "Artist",
                        "duration": 180000
                    },
                    {
                        "ratingKey": "12346",
                        "key": "/library/metadata/12346",
                        "title": "Track Two",
                        "parentTitle": "Album",
                        "grandparentTitle": "Artist",
                        "duration": 200000
                    },
                    {
                        "ratingKey": "12347",
                        "key": "/library/metadata/12347",
                        "title": "Track Three",
                        "parentTitle": "Album",
                        "grandparentTitle": "Artist",
                        "duration": 220000
                    }
                ]
            }
        }
        """

        let container = try JSONDecoder().decode(
            PlexMediaContainer<PlexTrack>.self,
            from: batchJSON.data(using: .utf8)!
        )
        
        XCTAssertEqual(container.mediaContainer.items.count, 3)
        XCTAssertEqual(container.mediaContainer.items[0].ratingKey, "12345")
        XCTAssertEqual(container.mediaContainer.items[0].title, "Track One")
        XCTAssertEqual(container.mediaContainer.items[1].ratingKey, "12346")
        XCTAssertEqual(container.mediaContainer.items[1].title, "Track Two")
        XCTAssertEqual(container.mediaContainer.items[2].ratingKey, "12347")
        XCTAssertEqual(container.mediaContainer.items[2].title, "Track Three")
    }
}
