import XCTest
@testable import EnsembleCore

final class MediaSourceIdentityTests: XCTestCase {
    func testParsesLibraryScopedSourceKey() {
        let identity = MediaSourceIdentity.parse("plex:account:server:library")

        XCTAssertEqual(identity?.type, "plex")
        XCTAssertEqual(identity?.accountId, "account")
        XCTAssertEqual(identity?.serverId, "server")
        XCTAssertEqual(identity?.libraryId, "library")
        XCTAssertEqual(identity?.serverSourceKey, "plex:account:server")
        XCTAssertEqual(identity?.accountServerKey, "account:server")
        XCTAssertEqual(identity?.isServerScoped, false)
        XCTAssertEqual(identity?.librarySourceKey, "plex:account:server:library")
    }

    func testParsesServerScopedSourceKey() {
        let identity = MediaSourceIdentity.parse("plex:account:server")

        XCTAssertEqual(identity?.serverSourceKey, "plex:account:server")
        XCTAssertEqual(identity?.accountServerKey, "account:server")
        XCTAssertEqual(identity?.isServerScoped, true)
        XCTAssertNil(identity?.librarySourceKey)
    }

    func testServerSourceKeyReturnsFirstThreeComponents() {
        XCTAssertEqual(
            MediaSourceIdentity.serverSourceKey(from: "plex:account:server:library"),
            "plex:account:server"
        )
        XCTAssertEqual(
            MediaSourceIdentity.serverSourceKey(from: "plex:account:server"),
            "plex:account:server"
        )
        XCTAssertNil(MediaSourceIdentity.serverSourceKey(from: "plex:account"))
        XCTAssertNil(MediaSourceIdentity.serverSourceKey(from: nil))
    }

    func testServerSourceKeyForMusicSourceIdentifier() {
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "library"
        )

        XCTAssertEqual(MediaSourceIdentity.serverSourceKey(for: source), "plex:account:server")
    }

    func testSameServerComparisonHandlesLibraryKeys() {
        XCTAssertTrue(MediaSourceIdentity.isSameServer("plex:a:s:lib1", "plex:a:s:lib2"))
        XCTAssertFalse(MediaSourceIdentity.isSameServer("plex:a:s1:lib", "plex:a:s2:lib"))
        XCTAssertFalse(MediaSourceIdentity.isSameServer("bad", "plex:a:s:lib"))
    }
}
