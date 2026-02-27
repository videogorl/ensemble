import XCTest
@testable import EnsembleAPI

final class PlexAuthTokenLifecycleTests: XCTestCase {
    func testTokenMetadataParsesIatAndExpFromJWTPayload() {
        let token = makeJWT(iat: 1_700_000_000, exp: 1_800_000_000)
        let metadata = PlexAuthService.tokenMetadata(from: token)

        XCTAssertEqual(metadata.rawToken, token)
        XCTAssertNotNil(metadata.issuedAt)
        XCTAssertNotNil(metadata.expiresAt)
        XCTAssertEqual(metadata.issuedAt!.timeIntervalSince1970, 1_700_000_000, accuracy: 0.1)
        XCTAssertEqual(metadata.expiresAt!.timeIntervalSince1970, 1_800_000_000, accuracy: 0.1)
    }

    func testExpiredTokenIsReportedAsExpired() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = makeJWT(iat: 1_700_000_000, exp: 1_800_000_000)
        let metadata = PlexAuthService.tokenMetadata(from: token)

        XCTAssertTrue(metadata.isExpired(now: now))
    }

    func testInvalidTokenFallsBackToNoExpiryMetadata() {
        let metadata = PlexAuthService.tokenMetadata(from: "not-a-jwt")
        XCTAssertNil(metadata.issuedAt)
        XCTAssertNil(metadata.expiresAt)
        XCTAssertFalse(metadata.isExpired(now: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    private func makeJWT(iat: TimeInterval, exp: TimeInterval) -> String {
        let header = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "iat": Int(iat),
            "exp": Int(exp),
            "sub": "tester"
        ]
        let signature = "signature"
        return "\(encodeJSONSegment(header)).\(encodeJSONSegment(payload)).\(signature)"
    }

    private func encodeJSONSegment(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
