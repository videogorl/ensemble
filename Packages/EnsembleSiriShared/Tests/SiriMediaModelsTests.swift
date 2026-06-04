import XCTest
@testable import EnsembleSiriShared

final class SiriMediaModelsTests: XCTestCase {
    func testPlaybackPayloadRoundTripEncodingDecoding() throws {
        let payload = SiriPlaybackRequestPayload(
            kind: .artist,
            entityID: "12345",
            sourceCompositeKey: "plex:account:server:library",
            displayName: "Billie Eilish"
        )

        let encoded = try SiriPlaybackActivityCodec.encode(payload)
        let decoded = try SiriPlaybackActivityCodec.decode(from: encoded)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.schemaVersion, SiriPlaybackRequestPayload.currentSchemaVersion)
    }

    func testPlaybackUserInfoRoundTrip() throws {
        let payload = SiriPlaybackRequestPayload(
            kind: .playlist,
            entityID: "abc",
            sourceCompositeKey: "plex:account:server",
            displayName: "Music to get high to"
        )

        let userInfo = try SiriPlaybackActivityCodec.makeUserInfo(payload)
        let decoded = SiriPlaybackActivityCodec.payload(from: userInfo)

        XCTAssertEqual(decoded, payload)
    }

    func testInvalidPlaybackUserInfoReturnsNil() {
        let userInfo: [AnyHashable: Any] = [SiriPlaybackActivityCodec.payloadUserInfoKey: "invalid"]
        XCTAssertNil(SiriPlaybackActivityCodec.payload(from: userInfo))
    }

    func testV1MediaIndexDecodesWithoutV2Fields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": 0,
          "items": [
            {
              "kind": "album",
              "id": "42",
              "displayName": "Faedom",
              "sourceCompositeKey": "plex:account:server:library",
              "secondaryText": "Grimes",
              "trackCount": 12
            }
          ]
        }
        """.data(using: .utf8)!

        let index = try JSONDecoder().decode(SiriMediaIndex.self, from: json)

        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.items.first?.kind, .album)
        XCTAssertNil(index.items.first?.duration)
        XCTAssertNil(index.items.first?.genre)
        XCTAssertNil(index.items.first?.artworkCacheKey)
        XCTAssertNil(index.items.first?.artworkCacheType)
    }

    func testV2MediaIndexDecodesWithoutArtworkFields() throws {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": 0,
          "items": [
            {
              "kind": "playlist",
              "id": "playlist-1",
              "displayName": "Music Video Ideas",
              "sourceCompositeKey": "plex:account:server",
              "trackCount": 42
            }
          ]
        }
        """.data(using: .utf8)!

        let index = try JSONDecoder().decode(SiriMediaIndex.self, from: json)

        XCTAssertEqual(index.schemaVersion, 2)
        XCTAssertEqual(index.items.first?.kind, .playlist)
        XCTAssertNil(index.items.first?.artworkPath)
        XCTAssertNil(index.items.first?.artworkCacheKey)
        XCTAssertNil(index.items.first?.artworkCacheType)
    }

    func testSourceScopedIdentifierComponentsRoundTrip() throws {
        let identifier = SystemMediaReference.sourceScopedIdentifier(
            kind: .album,
            id: "album-1",
            sourceCompositeKey: "plex://server.one/library"
        )

        let components = try XCTUnwrap(
            SystemMediaReference.components(fromSourceScopedIdentifier: identifier)
        )

        XCTAssertEqual(components.kind, .album)
        XCTAssertEqual(components.id, "album-1")
        XCTAssertEqual(components.sourceCompositeKey, "plex://server.one/library")
    }

    func testSpotlightIdentityStripsSharedPrefix() throws {
        let reference = SystemMediaReference(
            kind: .artist,
            id: "artist-1",
            sourceCompositeKey: "plex://server.one/library",
            displayName: "Artist"
        )

        let spotlightIdentifier = SystemMediaSpotlightIdentity.spotlightIdentifier(for: reference)

        XCTAssertEqual(
            SystemMediaSpotlightIdentity.sourceScopedIdentifier(fromSpotlightIdentifier: spotlightIdentifier),
            reference.sourceScopedIdentifier
        )
        XCTAssertNil(SystemMediaSpotlightIdentity.sourceScopedIdentifier(fromSpotlightIdentifier: reference.sourceScopedIdentifier))
    }
}
