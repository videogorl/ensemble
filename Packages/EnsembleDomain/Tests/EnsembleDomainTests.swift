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
}
