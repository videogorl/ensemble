@testable import EnsembleAPI
import XCTest

final class PlexAudioFormatSupportTests: XCTestCase {
    func testIncrementalPlaybackMatrix() {
        let cases: [(codec: String?, container: String?, ext: String?, supported: Bool)] = [
            ("mp3", "mp3", nil, true),
            ("aac", "mp4", nil, true),
            ("alac", "m4a", nil, true),
            ("flac", "flac", nil, true),
            ("pcm_s24le", "wav", nil, true),
            (nil, nil, "aiff", true),
            ("opus", "ogg", nil, false),
            ("vorbis", "ogg", nil, false),
            ("aac", "mpegts", nil, false),
            (nil, nil, "wma", false),
        ]

        for value in cases {
            XCTAssertEqual(
                PlexAudioFormatSupport.supportsIncrementalPlayback(
                    codec: value.codec,
                    container: value.container,
                    fileExtension: value.ext
                ),
                value.supported,
                "codec=\(value.codec ?? "nil") container=\(value.container ?? "nil") ext=\(value.ext ?? "nil")"
            )
        }
    }
}
