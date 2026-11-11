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

    /// What Siri hears and what is stored differ in punctuation; both sides normalise to one form.
    func testPunctuationDifferencesNormaliseToTheSameForm() {
        let pairs: [(stored: String, heard: String)] = [
            ("Pretty. Odd.", "Pretty, Odd"),
            ("Don\u{2019}t Stop Believin\u{2019}", "dont stop believin"),
            ("Don't Stop", "Don\u{2019}t Stop"),
            ("Kim & Jessie", "Kim and Jessie"),
            ("Who Are You?", "who are you"),
            ("Panic! At The Disco", "panic at the disco")
        ]
        for pair in pairs {
            XCTAssertEqual(
                SiriMatchScorer.scoreMatch(
                    queries: SiriPhraseNormalizer.queryVariants(for: pair.heard),
                    candidate: SiriPhraseNormalizer.basic(pair.stored)
                ),
                1.0,
                "\(pair.stored) vs \(pair.heard)"
            )
        }
    }

    /// A short title only matches inside a longer phrase as whole words, so "Rest" is not "Firestorm".
    func testShortTitleDoesNotMatchInsideALongerWord() {
        XCTAssertLessThan(SiriMatchScorer.scoreMatch(query: "firestorm", candidate: "rest"), 0.6)
        XCTAssertLessThan(SiriMatchScorer.scoreMatch(query: "firestorm", candidate: "fire"), 0.6)
        XCTAssertEqual(SiriMatchScorer.scoreMatch(query: "my focus", candidate: "focus"), SiriMatchScorer.containmentScore)
    }

    func testPossessiveShuffleRequestFindsTheExactPlaylistName() {
        let variants = SiriPhraseNormalizer.queryVariants(for: "Shuffle my focus playlist")
        XCTAssertEqual(SiriMatchScorer.scoreMatch(queries: variants, candidate: "focus"), 1.0)
    }
}
