import EnsembleAPI
@testable import EnsembleCore
import XCTest

@MainActor
final class LibraryItemInfoViewModelTests: XCTestCase {
    func testAppleMusicSourceContextUsesNormalizedPresentation() {
        let accountManager = AccountManager(keychain: TestKeychain())

        XCTAssertEqual(
            LibraryItemInfoViewModel.sourceContext(
                sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                accountManager: accountManager
            ),
            LibraryItemInfoViewModel.SourceContext(
                serverName: "Apple Music",
                libraryName: "Apple Music"
            )
        )
    }

    func testPersistedTrackDurationConvertsMillisecondsToSeconds() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.persistedTrackDurationSeconds(210_000),
            210,
            accuracy: 0.001
        )
    }

    func testAudioFileInfoIncludesOriginalPlexFilePath() throws {
        let track = try decodePlexTrack(
            ratingKey: "1",
            filePath: "/music/Harry Styles/Harry's House/04 Kiwi.flac"
        )

        let info = try XCTUnwrap(AudioFileInfo(from: track))

        XCTAssertEqual(info.filePath, "/music/Harry Styles/Harry's House/04 Kiwi.flac")
    }

    func testAlbumFolderPathUsesTrackParentDirectory() {
        XCTAssertEqual(
            PlexMusicSourceSyncProvider.albumFolderPath(from: [
                "/music/A/Album/01 Kiwi.flac",
                "/music/A/Album/01 Kiwi.flac",
                "/music/A/Album/02 Grape.flac",
            ]),
            "/music/A/Album"
        )
    }

    func testAlbumFolderPathUsesCommonParentForDiscSubfolders() {
        XCTAssertEqual(
            PlexMusicSourceSyncProvider.albumFolderPath(from: [
                "/music/A/Album/Disc 1/01 Kiwi.flac",
                "/music/A/Album/Disc 2/01 Grape.flac",
            ]),
            "/music/A/Album"
        )
    }

    func testAlbumFolderPathIgnoresEmptyPathsAndHandlesNoFiles() {
        XCTAssertEqual(
            PlexMusicSourceSyncProvider.albumFolderPath(from: ["", "/music/A/Album/01 Kiwi.flac"]),
            "/music/A/Album"
        )
        XCTAssertNil(PlexMusicSourceSyncProvider.albumFolderPath(from: ["", ""]))
    }

    func testResolvedTrackCountPrefersFetchedTracksWhenAvailable() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.resolvedTrackCount(
                metadataTrackCount: 0,
                fetchedTrackCount: 9
            ),
            9
        )
    }

    func testResolvedTrackCountFallsBackToMetadata() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.resolvedTrackCount(
                metadataTrackCount: 12,
                fetchedTrackCount: nil
            ),
            12
        )
    }

    func testResolvedAlbumArtworkPathFallsBackToFetchedTrackFallback() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.resolvedAlbumArtworkPath(
                albumThumbPath: nil,
                fetchedTrackArtworkPath: nil,
                fetchedTrackFallbackPath: "/library/metadata/1111/thumb"
            ),
            "/library/metadata/1111/thumb"
        )
    }

    func testResolvedAlbumArtworkRatingKeyUsesFallbackTrackRatingKey() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.resolvedAlbumArtworkRatingKey(
                albumThumbPath: nil,
                albumRatingKey: "album-1",
                fetchedTrackArtworkPath: nil,
                fetchedTrackRatingKey: "track-1",
                fetchedTrackFallbackRatingKey: "album-1"
            ),
            "album-1"
        )
    }

    private func decodePlexTrack(ratingKey: String, filePath: String) throws -> PlexTrack {
        let escapedPath = filePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {
          "ratingKey": "\(ratingKey)",
          "key": "/library/metadata/\(ratingKey)",
          "title": "Kiwi",
          "Media": [
            {
              "audioCodec": "flac",
              "container": "flac",
              "Part": [
                {
                  "file": "\(escapedPath)",
                  "size": 123456,
                  "Stream": [
                    {
                      "id": 7,
                      "streamType": 2,
                      "codec": "flac",
                      "samplingRate": 44100,
                      "bitDepth": 16,
                      "channels": 2
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
        return try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
    }
}
