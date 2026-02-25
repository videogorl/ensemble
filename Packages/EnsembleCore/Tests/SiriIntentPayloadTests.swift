import XCTest
@testable import EnsembleCore

final class SiriIntentPayloadTests: XCTestCase {
    func testPayloadRoundTripEncodingDecoding() throws {
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

    func testUserInfoRoundTrip() throws {
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

    func testInvalidUserInfoReturnsNil() {
        let userInfo: [AnyHashable: Any] = [SiriPlaybackActivityCodec.payloadUserInfoKey: "invalid"]
        XCTAssertNil(SiriPlaybackActivityCodec.payload(from: userInfo))
    }
}
