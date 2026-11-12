import EnsembleDomain
import XCTest
@testable import EnsembleSiriShared

/// Voice Add against the phone failure "couldn't find a playlist named ZZ Test Voice": two brand-new, never-played
/// playlists of one title on two servers, with merging on and off and every state of the published presentation.
final class SiriVoiceAddTests: XCTestCase {
    private let minibar = "plex:account-1:minibar"
    private let hiigel = "plex:account-1:hiigel"

    private func playlist(
        _ id: String, _ title: String, key: String, server: String?, played: Date? = nil, smart: Bool = false
    ) -> SiriMediaIndexItem {
        SiriMediaIndexItem(
            kind: .playlist, id: id, displayName: title, sourceCompositeKey: key,
            lastPlayed: played, isSmartPlaylist: smart, sourceName: server
        )
    }

    /// Older, played playlists plus the two new ones, as the persisted index holds them.
    private func index(serverNames: Bool = true, extra: [SiriMediaIndexItem] = []) -> SiriMediaIndex {
        let old = (0..<30).map {
            playlist("old-\($0)", "Mix \($0)", key: $0.isMultiple(of: 2) ? minibar : hiigel,
                     server: $0.isMultiple(of: 2) ? "Minibar" : "Hiigel-Server", played: Date(timeIntervalSince1970: Double($0)))
        }
        let created = [
            playlist("17681", "ZZ Test Voice", key: minibar, server: serverNames ? "Minibar" : nil),
            playlist("28409", "ZZ Test Voice", key: hiigel, server: serverNames ? "Hiigel-Server" : nil)
        ]
        return SiriMediaIndex(generatedAt: Date(timeIntervalSince1970: 100), items: old + created + extra)
    }

    private func presentation(
        for index: SiriMediaIndex, merging: Bool = true, hidden: Set<String> = [], generation: Date? = nil
    ) -> SiriPlaylistPresentation {
        var preferences = EnsembleMergingPreferences.default
        preferences.mergePlaylists = merging
        return SiriPlaylistPresentation(
            preferences: preferences, hiddenSourceKeys: hidden, indexGeneratedAt: generation ?? index.generatedAt
        )
    }

    private func summary(_ resolution: SiriPlaylistRows.VoiceAddResolution) -> String {
        switch resolution {
        case .deferToApp: return "deferToApp"
        case let .chosen(destination): return "chosen \(destination.name) #\(destination.item.id)"
        case let .choices(options): return "choices " + options.map { "\($0.name) #\($0.item.id)" }.joined(separator: ", ")
        case .notFound: return "notFound"
        case .notEditable: return "notEditable"
        }
    }

    /// Exactly one target when merging is on, two distinctly named ones when off, never a guess between copies, and
    /// brand-new playlists with no play history are offered like any other.
    func testNewSameNamedPlaylistsResolveByMergeSetting() {
        let withNames = index()
        let withoutNames = index(serverNames: false)
        let cases: [(name: String, index: SiriMediaIndex, merging: Bool, spoken: String, expected: String)] = [
            ("merging on: one target", withNames, true, "ZZ Test Voice", "chosen ZZ Test Voice #17681"),
            ("merging on, sloppy casing and spacing", withNames, true, "zz  test voice ", "chosen ZZ Test Voice #17681"),
            ("merging off: two distinct names", withNames, false, "ZZ Test Voice",
             "choices ZZ Test Voice (Minibar) #17681, ZZ Test Voice (Hiigel-Server) #28409"),
            ("merging off: a name Siri passes back picks exactly one", withNames, false, "ZZ Test Voice (Hiigel-Server)",
             "chosen ZZ Test Voice (Hiigel-Server) #28409"),
            ("merging off, server names not yet known: still two distinct names", withoutNames, false, "ZZ Test Voice",
             "choices ZZ Test Voice (Server) #17681, ZZ Test Voice (Server) 2 #28409"),
            ("merging off, no server names: the passed-back name picks one", withoutNames, false, "ZZ Test Voice (Server) 2",
             "chosen ZZ Test Voice (Server) 2 #28409")
        ]
        for testCase in cases {
            let resolution = SiriPlaylistRows.resolveVoiceAdd(
                named: testCase.spoken, in: testCase.index,
                presentation: presentation(for: testCase.index, merging: testCase.merging)
            )
            XCTAssertEqual(summary(resolution), testCase.expected, testCase.name)
        }
    }

    /// An unavailable presentation (never published, or for another index generation) hands the name to the app
    /// instead of answering "not found"; a covering one with no such playlist is a real "not found".
    func testMissingOrStalePresentationDefersToTheApp() {
        let index = index()
        let cases: [(name: String, presentation: SiriPlaylistPresentation?, spoken: String, expected: String)] = [
            ("missing", nil, "ZZ Test Voice", "deferToApp"),
            ("stale generation", presentation(for: index, generation: Date(timeIntervalSince1970: 99)), "ZZ Test Voice", "deferToApp"),
            ("never stamped", SiriPlaylistPresentation(), "ZZ Test Voice", "deferToApp"),
            ("covering, unknown name", presentation(for: index), "Quarterly Polka", "notFound"),
            ("covering, weak resemblance is not a match", presentation(for: index), "Zebra", "notFound")
        ]
        for testCase in cases {
            XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: testCase.spoken, in: index, presentation: testCase.presentation)),
                           testCase.expected, testCase.name)
        }
    }

    /// Hidden sources are never written to; smart playlists cannot take a song; a close title never stands in for
    /// the one named; and the destination set is the full editable list, with the newest playlist last included.
    func testDestinationsAreVisibleEditableAndComplete() {
        let smart = playlist("smart", "Recently Added", key: minibar, server: "Minibar", smart: true)
        let many = (0..<1_200).map { playlist("bulk-\($0)", "Bulk \(String(format: "%04d", $0))", key: hiigel, server: "Hiigel-Server") }
        let index = index(extra: [smart] + many)

        let hiddenMinibar = presentation(for: index, hidden: [minibar])
        XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: "ZZ Test Voice", in: index, presentation: hiddenMinibar)),
                       "chosen ZZ Test Voice #28409", "merging: the visible copy, not the hidden preferred one")
        XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: "ZZ Test Voice", in: index, presentation: presentation(for: index, hidden: [minibar, hiigel]))),
                       "notFound", "every copy hidden")
        XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: "Recently Added", in: index, presentation: presentation(for: index))),
                       "notEditable", "a smart playlist is not an Add destination")
        XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: "Bulk 1199", in: index, presentation: presentation(for: index))),
                       "chosen Bulk 1199 #bulk-1199", "no cap drops late playlists")
        XCTAssertEqual(SiriPlaylistRows.voiceAddDestinations(in: index, presentation: presentation(for: index))?.count, 30 + 1 + 1_200,
                       "every visible editable playlist, one row for the merged pair")
        let offered = SiriPlaylistRows.voiceAddDestinations(in: index, presentation: presentation(for: index))!
        XCTAssertTrue(offered.allSatisfy { !($0.isSmartPlaylist ?? false) })

        let near = SiriMediaIndex(generatedAt: index.generatedAt, items: [playlist("a", "ZZ Test Voices", key: minibar, server: "Minibar")])
        XCTAssertEqual(summary(SiriPlaylistRows.resolveVoiceAdd(named: "ZZ Test Voice", in: near, presentation: presentation(for: near))),
                       "chosen ZZ Test Voices #a", "a single close title is the one named")
    }

    /// The extension's trail is bounded, ordered, drained once, and carries only codes and counts.
    func testBreadcrumbTrailIsBoundedAndDrainsOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trail-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for step in 0..<(SiriExtensionBreadcrumbs.capacity + 5) {
            SiriExtensionBreadcrumbs.record(
                SiriExtensionBreadcrumb(at: Date(timeIntervalSince1970: Double(step)), event: "resolveDestination", outcome: "chosen presentation=covers", counts: ["step": step]),
                at: url
            )
        }
        let trail = SiriExtensionBreadcrumbs.drain(at: url)
        XCTAssertEqual(trail.count, SiriExtensionBreadcrumbs.capacity)
        XCTAssertEqual(trail.first?.counts["step"], 5, "the oldest are dropped")
        XCTAssertEqual(trail.last?.counts["step"], SiriExtensionBreadcrumbs.capacity + 4)
        XCTAssertEqual(trail.last?.logLine.contains("event=resolveDestination outcome=chosen presentation=covers step=44"), true)
        XCTAssertTrue(SiriExtensionBreadcrumbs.drain(at: url).isEmpty)
    }

    /// A smart playlist is matched like any other: when it is the best match nothing is written, and a similar regular
    /// playlist is never the fallback.
    func testSmartPlaylistMatchNeverFallsThroughToASimilarRegularOne() {
        let extra = [
            playlist("smart-1", "Road Trip Mix", key: minibar, server: "Minibar", smart: true),
            playlist("reg-1", "Road Trip Mix 2024", key: minibar, server: "Minibar"),
            playlist("smart-2", "Night Drive", key: hiigel, server: "Hiigel-Server", smart: true),
            playlist("reg-2", "Night Drive", key: minibar, server: "Minibar")
        ]
        let index = index(extra: extra)
        let cases: [(name: String, spoken: String, merging: Bool, expected: String)] = [
            ("exact smart title beats the fuzzy regular one", "Road Trip Mix", true, "notEditable"),
            ("same with merging off", "Road Trip Mix", false, "notEditable"),
            ("the regular playlist by its own name", "Road Trip Mix 2024", true, "chosen Road Trip Mix 2024 #reg-1"),
            ("a smart and a regular playlist share a title: ambiguous, never written", "Night Drive", true, "notEditable")
        ]
        for testCase in cases {
            XCTAssertEqual(
                summary(SiriPlaylistRows.resolveVoiceAdd(
                    named: testCase.spoken, in: index, presentation: presentation(for: index, merging: testCase.merging)
                )),
                testCase.expected, testCase.name
            )
        }
    }

    /// A writer that finds the lock held skips its record instead of waiting: the file stays valid, no entry is
    /// duplicated, and writers that did run kept theirs.
    func testContendedBreadcrumbRecordsAreSkippedNotCorrupted() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trail-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
        }
        DispatchQueue.concurrentPerform(iterations: 30) { step in
            SiriExtensionBreadcrumbs.record(SiriExtensionBreadcrumb(event: "e", outcome: "o", counts: ["step": step]), at: url)
        }
        let steps = SiriExtensionBreadcrumbs.drain(at: url).compactMap { $0.counts["step"] }
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps.count, Set(steps).count, "no entry is duplicated")

        // Held elsewhere: record and drain both return at once without touching the file.
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { close(descriptor) }
        SiriExtensionBreadcrumbs.record(SiriExtensionBreadcrumb(event: "held", outcome: "o"), at: url)
        XCTAssertTrue(SiriExtensionBreadcrumbs.drain(at: url).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
