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

    func testShuffleDoesNotDuplicateCurrentAutoplayItem() {
        let shuffled = EnsembleQueuePolicy.shuffledQueue(
            ["manual", "current-auto", "future-auto"],
            currentQueueIndex: 1,
            history: [],
            identity: { $0 },
            source: { $0.contains("auto") ? .autoplay : .continuePlaying },
            shuffle: { _ in }
        )

        XCTAssertEqual(shuffled.items, ["current-auto", "manual", "future-auto"])
    }

    func testCrossDeviceLibraryFlagsMergeByTimestampAndDecodeLegacyPayload() throws {
        let local = EnsembleLibraryFlagEntry(key: "library", isEnabled: true, updatedAt: 20)
        let staleRemote = EnsembleLibraryFlagEntry(key: "library", isEnabled: false, updatedAt: 10)
        let freshRemote = EnsembleLibraryFlagEntry(key: "library", isEnabled: false, updatedAt: 30)

        XCTAssertEqual(
            EnsembleLibraryFlagPolicy.merged(
                local: [local.key: local],
                remote: [staleRemote.key: staleRemote]
            )[local.key],
            local
        )
        XCTAssertEqual(
            EnsembleLibraryFlagPolicy.merged(
                local: [local.key: local],
                remote: [freshRemote.key: freshRemote]
            )[local.key],
            freshRemote
        )

        let legacyData = try JSONEncoder().encode(["legacy": true])
        XCTAssertEqual(
            EnsembleLibraryFlagPolicy.decodedEntries(from: legacyData)?["legacy"],
            EnsembleLibraryFlagEntry(key: "legacy", isEnabled: true)
        )
    }

    func testSourceScopeCompatibilityRequiresTheSameParsedServer() {
        XCTAssertTrue(EnsembleSourceScope.isCompatible("plex:a:s", "plex:a:s:3"))
        XCTAssertTrue(EnsembleSourceScope.isCompatible("plex:a:s:2", "plex:a:s:3"))
        XCTAssertFalse(EnsembleSourceScope.isCompatible("plex:a:s:3", "plex:a:other:3"))
        XCTAssertFalse(EnsembleSourceScope.isCompatible("malformed", "plex:a:s:3"))
    }

    func testMergingPrefersTheFirstAvailableSourceAndPreservesAmbiguousVariants() {
        struct Item: Equatable {
            let name: String
            let source: String
            let identity: String?
        }

        let preferences = EnsembleMergingPreferences(
            preferredSourceKeys: ["plex:a:preferred:1", "plex:a:fallback:2"]
        )
        let collapsed = EnsembleMergeIdentity.collapsed(
            [
                Item(name: "fallback", source: "plex:a:fallback:2", identity: "same"),
                Item(name: "ambiguous", source: "plex:a:fallback:2", identity: nil),
                Item(name: "preferred", source: "plex:a:preferred", identity: "same")
            ],
            preferences: preferences,
            identity: \.identity,
            sourceKey: \.source
        )

        XCTAssertEqual(collapsed.map(\.name), ["preferred", "ambiguous"])
        XCTAssertNil(EnsembleMergeIdentity.albumFamily(
            title: "Album",
            artist: "Artist",
            year: nil
        ))
    }

    func testMergeIdentityNormalizesCaseAndTypographicQuotes() {
        let expected = EnsembleMergeIdentity.normalized("Don't Judge Me")

        XCTAssertEqual(EnsembleMergeIdentity.normalized("DON’T JUDGE ME"), expected)
        XCTAssertEqual(EnsembleMergeIdentity.normalized("Don‘t Judge Me"), expected)
        XCTAssertEqual(
            EnsembleMergeIdentity.normalized("“Dirty Computer”"),
            EnsembleMergeIdentity.normalized("\"Dirty Computer\"")
        )
        XCTAssertNotEqual(
            EnsembleMergeIdentity.normalized("Janelle Monáe Feat. Brian Wilson"),
            EnsembleMergeIdentity.normalized("Janelle Monáe ft. Brian Wilson")
        )
    }

    func testMediaActionCatalogUsesSharedWatchAndIOSOrder() {
        XCTAssertEqual(
            EnsembleMediaActionCatalog.ordered.map(\.action),
            [.play, .shuffle, .radio, .playNext, .playLast, .addToPlaylist,
             .addToRecentPlaylist, .favorite, .pin, .goToAlbum, .goToArtist,
             .share, .delete]
        )
    }

    func testCompanionCommandsRebaseByStableIdentityAndRequireAcknowledgedReplacement() throws {
        let items = [
            EnsembleCompanionQueueIdentity(id: "new-queue-id", sourceKey: "plex:a:s:1", playlistItemID: "track-7")
        ]
        XCTAssertEqual(
            EnsembleCompanionQueuePolicy.matchingIndex(
                itemID: "stale-queue-id",
                sourceKey: "plex:a:s:1",
                stableItemID: "track-7",
                in: items
            ),
            0
        )
        XCTAssertFalse(EnsembleCompanionQueuePolicy.acceptsReplacement(
            commandRevision: 4,
            currentRevision: 5,
            isProtected: false,
            isConfirmed: true
        ))
        XCTAssertFalse(EnsembleCompanionQueuePolicy.acceptsReplacement(
            commandRevision: 5,
            currentRevision: 5,
            isProtected: true,
            isConfirmed: false
        ))
        XCTAssertTrue(EnsembleCompanionQueuePolicy.acceptsReplacement(
            commandRevision: 5,
            currentRevision: 5,
            isProtected: true,
            isConfirmed: true
        ))

        let command = EnsembleCompanionCommand(
            kind: .createPlaylist,
            booleanValue: true,
            repeatMode: .one,
            targetSourceKey: "plex:a:s",
            targetTitle: "Watch Mix"
        )
        let decoded = try JSONDecoder().decode(
            EnsembleCompanionCommand.self,
            from: JSONEncoder().encode(command)
        )
        XCTAssertEqual(decoded.targetTitle, "Watch Mix")
        XCTAssertEqual(decoded.targetSourceKey, "plex:a:s")
        XCTAssertEqual(decoded.booleanValue, true)
        XCTAssertEqual(decoded.repeatMode, .one)
    }
}
