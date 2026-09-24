import XCTest
@testable import EnsembleCore

final class PlexAccountConfigTests: XCTestCase {
    func testEndpointDescriptorTreatsHTTPSURIAsSecureWhenProtocolMetadataIsMissing() {
        let connection = PlexConnectionConfig(
            uri: "https://server.example.com",
            local: false,
            relay: false
        )

        XCTAssertTrue(connection.endpointDescriptor.secure)
        XCTAssertEqual(connection.endpointDescriptor.endpointClass, .remoteSecure)
    }

    func testEndpointDescriptorPreservesRelayAndLocalMetadata() {
        let connection = PlexConnectionConfig(
            uri: "http://relay.example.com",
            local: true,
            relay: true,
            protocol: "http"
        )

        XCTAssertTrue(connection.endpointDescriptor.local)
        XCTAssertTrue(connection.endpointDescriptor.relay)
        XCTAssertEqual(connection.endpointDescriptor.endpointClass, .relay)
    }
}
