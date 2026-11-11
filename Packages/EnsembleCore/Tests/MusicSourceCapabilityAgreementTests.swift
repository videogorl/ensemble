import XCTest
@testable import EnsembleCore

/// `MusicSourceCapabilities` decides UI and copy; protocol conformance decides routing
/// (`SyncProviderResolver.requireCapability`). Four flags have a protocol counterpart, and a
/// source that claims one without implementing it would show a feature that fails at runtime.
final class MusicSourceCapabilityAgreementTests: XCTestCase {
    private struct Row {
        let type: MusicSourceType
        let connector: Any.Type
    }

    private var rows: [Row] {
        var rows = [Row(type: .plex, connector: PlexConnector.self)]
        #if os(iOS)
        // `AppleMusicConnector` is iOS-only, so this row runs only in an iOS test run.
        if #available(iOS 18, *) {
            rows.append(Row(type: .appleMusic, connector: AppleMusicConnector.self))
        }
        #endif
        return rows
    }

    func testCapabilityFlagsAgreeWithProtocolConformance() {
        for row in rows {
            let flags = row.type.capabilities
            let name = String(describing: row.connector)
            XCTAssertEqual(flags.supportsLyrics, row.connector is MusicSourceLyricsProviding.Type,
                           "\(name) supportsLyrics vs MusicSourceLyricsProviding")
            XCTAssertEqual(flags.supportsAudioFileInfo, row.connector is MusicSourceFileInfoProviding.Type,
                           "\(name) supportsAudioFileInfo vs MusicSourceFileInfoProviding")
            XCTAssertEqual(flags.supportsCollectionRatings, row.connector is MusicSourceCollectionRatingMutating.Type,
                           "\(name) supportsCollectionRatings vs MusicSourceCollectionRatingMutating")
            XCTAssertEqual(flags.supportsOfflineDownloads, row.connector is MusicSourceTwoPhasePlaybackResolving.Type,
                           "\(name) supportsOfflineDownloads vs MusicSourceTwoPhasePlaybackResolving")
        }
    }
}
