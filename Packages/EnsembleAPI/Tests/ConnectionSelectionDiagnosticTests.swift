import XCTest
@testable import EnsembleAPI

final class ConnectionSelectionDiagnosticTests: XCTestCase {
    func testDiagnosticSummaryCapturesProbeShapeWithoutURLs() {
        let selected = PlexEndpointDescriptor(
            url: "https://local.example",
            local: true,
            relay: false
        )
        let timeout = PlexEndpointDescriptor(
            url: "https://remote.example",
            local: false,
            relay: false
        )
        let result = ConnectionSelectionResult(
            selected: selected,
            probes: [
                ConnectionProbeResult(
                    endpoint: selected,
                    success: true,
                    duration: 0.042,
                    failureCategory: nil
                ),
                ConnectionProbeResult(
                    endpoint: timeout,
                    success: false,
                    duration: 1.5,
                    failureCategory: .timeout
                )
            ],
            reusedPreferredPath: false,
            skippedInsecureCount: 1
        )

        XCTAssertEqual(
            result.diagnosticSummary,
            "selectedClass=0 probes=2 successes=1 failures=1 failureCategories=timeout:1 fastestMs=42 slowestMs=1500 reusedPreferred=0 skippedInsecure=1"
        )
        XCTAssertFalse(result.diagnosticSummary.contains("local.example"))
        XCTAssertFalse(result.diagnosticSummary.contains("remote.example"))
    }

    func testDiagnosticSummaryHandlesEmptyProbeSet() {
        let result = ConnectionSelectionResult(
            selected: nil,
            probes: [],
            reusedPreferredPath: false,
            skippedInsecureCount: 0
        )

        XCTAssertEqual(
            result.diagnosticSummary,
            "selectedClass=none probes=0 successes=0 failures=0 failureCategories=none fastestMs=n/a slowestMs=n/a reusedPreferred=0 skippedInsecure=0"
        )
    }
}
