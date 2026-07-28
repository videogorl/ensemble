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

    func testFilePathsFromTracksKeepsOriginalOrderAndDeduplicates() throws {
        let first = try decodePlexTrack(ratingKey: "1", filePath: "/music/A/01 Kiwi.flac")
        let duplicate = try decodePlexTrack(ratingKey: "2", filePath: "/music/A/01 Kiwi.flac")
        let second = try decodePlexTrack(ratingKey: "3", filePath: "/music/A/02 Grape.flac")

        XCTAssertEqual(
            LibraryItemInfoViewModel.filePaths(from: [first, duplicate, second]),
            [
                "/music/A/01 Kiwi.flac",
                "/music/A/02 Grape.flac"
            ]
        )
    }

    func testAlbumFolderPathUsesTrackParentDirectory() throws {
        let first = try decodePlexTrack(ratingKey: "1", filePath: "/music/A/Album/01 Kiwi.flac")
        let second = try decodePlexTrack(ratingKey: "2", filePath: "/music/A/Album/02 Grape.flac")

        XCTAssertEqual(
            LibraryItemInfoViewModel.albumFolderPath(from: [first, second]),
            "/music/A/Album"
        )
    }

    func testAlbumFolderPathUsesCommonParentForDiscSubfolders() throws {
        let first = try decodePlexTrack(ratingKey: "1", filePath: "/music/A/Album/Disc 1/01 Kiwi.flac")
        let second = try decodePlexTrack(ratingKey: "2", filePath: "/music/A/Album/Disc 2/01 Grape.flac")

        XCTAssertEqual(
            LibraryItemInfoViewModel.albumFolderPath(from: [first, second]),
            "/music/A/Album"
        )
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
