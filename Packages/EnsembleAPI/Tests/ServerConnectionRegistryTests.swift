import XCTest
@testable import EnsembleAPI

final class ServerConnectionRegistryTests: XCTestCase {
    func testUnchangedEndpointDoesNotPublishAnotherChange() async {
        let registry = ServerConnectionRegistry()
        let changes = await registry.endpointChanges()
        let firstChange = expectation(description: "initial endpoint")
        let duplicateChange = expectation(description: "duplicate endpoint")
        duplicateChange.isInverted = true

        let observation = Task {
            var count = 0
            for await _ in changes {
                count += 1
                if count == 1 {
                    firstChange.fulfill()
                } else {
                    duplicateChange.fulfill()
                    break
                }
            }
        }
        defer { observation.cancel() }

        let endpoint = PlexEndpointDescriptor(
            url: "https://server.example.com",
            local: false,
            relay: false
        )
        await registry.updateEndpoint(for: "account:server", endpoint: endpoint, source: .connectionRefresh)
        await fulfillment(of: [firstChange], timeout: 1)

        await registry.updateEndpoint(for: "account:server", endpoint: endpoint, source: .healthCheck)
        await fulfillment(of: [duplicateChange], timeout: 0.1)
    }
}
