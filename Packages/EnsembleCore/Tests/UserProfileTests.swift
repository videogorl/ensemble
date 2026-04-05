import XCTest
@testable import EnsembleCore

/// Tests for the UserProfile model and serialization
final class UserProfileTests: XCTestCase {

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
}
