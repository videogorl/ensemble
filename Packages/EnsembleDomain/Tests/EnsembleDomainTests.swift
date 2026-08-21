import XCTest
@testable import EnsembleDomain

final class EnsembleDomainTests: XCTestCase {
    func testSyncableCredentialShapeDecodes() throws {
        let json = """
        [{
          "accountId": "account-1",
          "email": "user@example.com",
          "plexUsername": "user",
          "displayTitle": "User",
          "authToken": "token",
          "servers": [{
            "serverId": "server-1",
            "serverName": "Server",
            "serverToken": "server-token",
            "libraries": [{
              "id": "3",
              "key": "3",
              "title": "Music",
              "isEnabled": true
            }]
          }]
        }]
        """.data(using: .utf8)!

        let credentials = try JSONDecoder().decode([EnsembleAccountCredential].self, from: json)

        XCTAssertEqual(credentials.first?.displayName, "User")
        XCTAssertEqual(credentials.first?.servers.first?.libraries.first?.title, "Music")
    }

    func testLibraryTitleSortingMatchesIOSRules() {
        XCTAssertEqual("The Beatles".ensembleSortingKey, "Beatles")
        XCTAssertEqual("A Tribe Called Quest".ensembleSortingKey, "Tribe Called Quest")
        XCTAssertEqual("An Awesome Wave".ensembleSortingKey, "Awesome Wave")
        XCTAssertEqual("Therapy?".ensembleSortingKey, "Therapy?")
    }

    func testLibraryTitleIndexingMatchesIOSRules() {
        XCTAssertEqual("The Beatles".ensembleIndexingLetter, "B")
        XCTAssertEqual("'Til Tuesday".ensembleIndexingLetter, "T")
        XCTAssertEqual("1999".ensembleIndexingLetter, "#")
    }

    func testLegacyMediaSummaryDecodesWithoutSmartPlaylistMetadata() throws {
        let data = Data(#"{"id":"1","kind":"playlist","title":"Mix","sourceKey":"plex:a:s"}"#.utf8)

        let summary = try JSONDecoder().decode(EnsembleMediaSummary.self, from: data)

        XCTAssertNil(summary.isSmart)
    }

    func testQueuePolicySharesHistoryShuffleAndDisplayRules() {
        XCTAssertEqual(EnsembleQueuePolicy.displayLimit, 50)
        XCTAssertEqual(EnsembleQueuePolicy.nextRepeatRawValue(current: 0, caseCount: 3), 1)
        XCTAssertEqual(EnsembleQueuePolicy.nextRepeatRawValue(current: 2, caseCount: 3), 0)

        var history = ["old"]
        EnsembleQueuePolicy.recordToHistory(
            "current",
            history: &history,
            maximumCount: 2,
            identity: { $0 },
            normalized: { $0 }
        )
        EnsembleQueuePolicy.recordToHistory(
            "current",
            history: &history,
            maximumCount: 2,
            identity: { $0 },
            normalized: { $0 }
        )
        XCTAssertEqual(history, ["old", "current"])

        let shuffled = EnsembleQueuePolicy.shuffledQueue(
            ["played", "current", "candidate", "generated"],
            currentQueueIndex: 1,
            history: ["played"],
            identity: { $0 },
            source: { $0 == "generated" ? .autoplay : .continuePlaying },
            shuffle: { $0.reverse() }
        )
        XCTAssertEqual(shuffled.items, ["current", "candidate", "generated"])
        XCTAssertEqual(shuffled.currentQueueIndex, 0)

        let persisted = EnsembleQueuePolicy.queueForPersistence(
            ["current", "manual", "generated"],
            currentQueueIndex: 0,
            source: { $0 == "generated" ? .autoplay : .continuePlaying }
        )
        XCTAssertEqual(persisted, ["current", "manual"])
    }
}
