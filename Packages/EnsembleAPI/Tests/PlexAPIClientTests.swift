import XCTest
@testable import EnsembleAPI

final class PlexAPIClientTests: XCTestCase {
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
}
