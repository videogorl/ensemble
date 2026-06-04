import XCTest
@testable import EnsembleSiriShared

final class SiriMatchingTests: XCTestCase {
    func testBasicNormalizationRemovesCasePunctuationAndDiacritics() {
        XCTAssertEqual(SiriPhraseNormalizer.basic("Beyoncé!!!  HALO"), "beyonce halo")
        XCTAssertEqual(SiriPhraseNormalizer.basic("  The---Downward   Spiral  "), "the downward spiral")
    }

    func testBroadNormalizationRemovesAppSuffixConnectorsAndMediaPrefixes() {
        XCTAssertEqual(
            SiriPhraseNormalizer.normalized("Playlist Road Trip on Ensemble"),
            "road trip"
        )
        XCTAssertEqual(
            SiriPhraseNormalizer.normalized("The Album Faedom using Ensemble Music"),
            "faedom"
        )
        XCTAssertEqual(
            SiriPhraseNormalizer.normalized("Shuffle the playlist Road Trip on Ensemble"),
            "road trip"
        )
    }

    func testQueryVariantsIncludeShortestMediaTitleFormFirst() {
        let variants = SiriPhraseNormalizer.queryVariants(for: "Playlist Road Trip on Ensemble")

        XCTAssertEqual(variants.first, "road trip")
        XCTAssertTrue(variants.contains("playlist road trip on ensemble"))
        XCTAssertTrue(variants.contains("playlist road trip"))
    }

    func testQueryVariantsStripShuffleOnlyWhenItIntroducesMediaType() {
        let playlistVariants = SiriPhraseNormalizer.queryVariants(for: "Shuffle the playlist Road Trip on Ensemble")

        XCTAssertEqual(playlistVariants.first, "road trip")
        XCTAssertTrue(playlistVariants.contains("the playlist road trip"))
        XCTAssertTrue(playlistVariants.contains("shuffle the playlist road trip"))

        let titleVariants = SiriPhraseNormalizer.queryVariants(for: "Shuffle This")
        XCTAssertEqual(titleVariants.first, "shuffle this")
        XCTAssertFalse(titleVariants.contains("this"))
    }

    func testMatchScorerKeepsExpectedExactPrefixContainmentAndFuzzyScores() {
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "faedom", candidate: "faedom"), 1.0)
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "fae", candidate: "faedom"), SiriMatchScorer.prefixScore)
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "orange", candidate: "orange county"), SiriMatchScorer.prefixScore)
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "county", candidate: "orange county"), SiriMatchScorer.containmentScore)
        XCTAssertGreaterThan(SiriMatchScorer.scoreMatch(query: "freedom", candidate: "faedom"), 0.6)
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "", candidate: "faedom"), 0)
    }
}
