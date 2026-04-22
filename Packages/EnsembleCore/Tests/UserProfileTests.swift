import XCTest
@testable import EnsembleCore

/// Tests for the UserProfile model and serialization
final class UserProfileTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Model Tests

    func testDefaultProfileIsEmpty() {
        let profile = UserProfile()
        XCTAssertNil(profile.displayName)
        XCTAssertNil(profile.profileImagePath)
        XCTAssertTrue(profile.isEmpty)
    }

    func testProfileWithNameIsNotEmpty() {
        var profile = UserProfile()
        profile.displayName = "Alice"
        XCTAssertFalse(profile.isEmpty)
    }

    func testProfileWithImagePathIsNotEmpty() {
        var profile = UserProfile()
        profile.profileImagePath = "avatar.jpg"
        XCTAssertFalse(profile.isEmpty)
    }

    // MARK: - Serialization Tests

    func testProfileRoundTrips() throws {
        var original = UserProfile()
        original.displayName = "Bob"
        original.profileImagePath = "avatar.jpg"
        original.lastModified = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)

        XCTAssertEqual(decoded.displayName, "Bob")
        XCTAssertEqual(decoded.profileImagePath, "avatar.jpg")
        XCTAssertEqual(decoded.lastModified.timeIntervalSince1970,
                       original.lastModified.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testProfileDecodesNilFields() throws {
        let json = """
        {"lastModified": 0}
        """
        let data = json.data(using: .utf8)!
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        XCTAssertNil(profile.displayName)
        XCTAssertNil(profile.profileImagePath)
        XCTAssertTrue(profile.isEmpty)
    }

    func testPossessiveFormAddsApostropheSForMostNames() {
        XCTAssertEqual("Alex".possessiveForm, "Alex's")
    }

    func testPossessiveFormUsesTrailingApostropheForNamesEndingInS() {
        XCTAssertEqual("James".possessiveForm, "James'")
    }

    func testTextualDisplayNameRemovesDecorativeEmoji() {
        XCTAssertEqual("Lissy 💕".textualDisplayName, "Lissy")
    }

    func testTextualDisplayNamePreservesReadablePunctuation() {
        XCTAssertEqual("P!nk".textualDisplayName, "P!nk")
    }

    // MARK: - Store Conflict Tests

    @MainActor
    func testRemoteProfileWithEqualTimestampButDifferentContentStillApplies() throws {
        let store = try makeStore()
        store.updateName("Local")

        let equalTimestamp = store.profile.lastModified
        let remote = UserProfile(displayName: "Remote", profileImagePath: nil, lastModified: equalTimestamp)

        store.applyRemoteProfile(remote, imageData: nil)

        XCTAssertEqual(store.profile.displayName, "Remote")
        XCTAssertEqual(store.profile.lastModified, equalTimestamp)
    }

    @MainActor
    func testOlderRemoteProfileDoesNotOverwriteLocalState() throws {
        let store = try makeStore()
        store.updateName("Local")

        let remote = UserProfile(
            displayName: "Remote",
            profileImagePath: nil,
            lastModified: store.profile.lastModified.addingTimeInterval(-60)
        )

        store.applyRemoteProfile(remote, imageData: nil)

        XCTAssertEqual(store.profile.displayName, "Local")
    }

    @MainActor
    func testEmptyLocalProfileAcceptsRemoteEvenWhenTimestampIsOlder() throws {
        let store = try makeStore()
        let remote = UserProfile(
            displayName: "Remote",
            profileImagePath: nil,
            lastModified: Date(timeIntervalSince1970: 100)
        )

        store.applyRemoteProfile(remote, imageData: nil)

        XCTAssertEqual(store.profile.displayName, "Remote")
    }

    @MainActor
    private func makeStore() throws -> UserProfileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(directory)
        return UserProfileStore(profileDirectory: directory)
    }
}
