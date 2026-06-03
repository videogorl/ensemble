import XCTest
@testable import EnsembleSupport

final class EnsembleLogRedactorTests: XCTestCase {
    func testRedactsSensitiveHeadersAndTokenFields() {
        let message = "Headers: X-Plex-Token: secret-token, Authorization: Bearer bearer-secret, accessToken=account-secret authToken=session-secret rawToken=jwt-secret token=generic-secret"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("bearer-secret"))
        XCTAssertFalse(redacted.contains("account-secret"))
        XCTAssertFalse(redacted.contains("session-secret"))
        XCTAssertFalse(redacted.contains("jwt-secret"))
        XCTAssertFalse(redacted.contains("generic-secret"))
        XCTAssertTrue(redacted.contains("X-Plex-Token: <redacted>"))
        XCTAssertTrue(redacted.contains("Authorization: <redacted>"))
        XCTAssertTrue(redacted.contains("accessToken=<redacted>"))
        XCTAssertTrue(redacted.contains("authToken=<redacted>"))
        XCTAssertTrue(redacted.contains("rawToken=<redacted>"))
        XCTAssertTrue(redacted.contains("token=<redacted>"))
    }

    func testRedactsURLAndPathLiterals() {
        let message = "Request https://example.test/:/transcode/universal/start.mp3?path=%2Flibrary%2Fparts%2F1&X-Plex-Token=secret-token&directPlay=0 path=/library/metadata/7551?viewOffset>=50 file=/Users/test/Music/Secret Track.mp3"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("example.test"))
        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("/library/metadata/7551"))
        XCTAssertFalse(redacted.contains("viewOffset"))
        XCTAssertFalse(redacted.contains("/Users/test/Music/Secret"))
        XCTAssertEqual(redacted, "Request <redacted-url> path=<redacted-path> file=<redacted-path>")
    }

    func testRedactsSchemeLessPlexEndpointHosts() {
        let message = "Request GET 192-168-0-111.2180421863bb4b7d826874b1fc55cfd5.plex.direct/library/metadata/1 (HTTPS: true)"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("192-168-0-111"))
        XCTAssertFalse(redacted.contains("plex.direct"))
        XCTAssertFalse(redacted.contains("/library/metadata/1"))
        XCTAssertEqual(redacted, "Request GET <redacted-host><redacted-path> (HTTPS: true)")
    }

    func testRedactsBarePlexHostsAndRootPlaylistPaths() {
        let message = "WebSocket connecting to 192-168-0-111.2180421863bb4b7d826874b1fc55cfd5.plex.direct and GET server.plex.direct/playlists"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("192-168-0-111"))
        XCTAssertFalse(redacted.contains("plex.direct"))
        XCTAssertFalse(redacted.contains("/playlists"))
        XCTAssertEqual(redacted, "WebSocket connecting to <redacted-host> and GET <redacted-host><redacted-path>")
    }
}
