import XCTest
@testable import EnsembleCore

final class NowPlayingSecondaryLayoutTests: XCTestCase {
    func testDefaultsAndSanitizationPreserveSlotPositions() {
        XCTAssertEqual(NowPlayingSecondaryLayout.default.slots, [.airPlay, .favorite, .addToPlaylist, nil])
        let cases: [([NowPlayingSecondaryAction?], [NowPlayingSecondaryAction?])] = [
            ([], [nil, nil, nil, nil]),
            ([.favorite], [.favorite, nil, nil, nil]),
            ([nil, .favorite, .favorite, .airPlay, .shareLink], [nil, .favorite, nil, .airPlay])
        ]
        for (input, expected) in cases {
            XCTAssertEqual(NowPlayingSecondaryLayout(slots: input).slots, expected)
        }
    }

    func testUnknownActionsBecomeEmptyAndEmptySlotsRoundTrip() throws {
        let data = Data(#"{"slots":["favorite","futureAction",null,"airPlay","shareLink"]}"#.utf8)
        let layout = try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: data)
        XCTAssertEqual(layout.slots, [.favorite, nil, nil, .airPlay])
        for value in [layout, NowPlayingSecondaryLayout(slots: [])] {
            XCTAssertEqual(try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: JSONEncoder().encode(value)), value)
        }
        for payload in ["{}", "null", #"{"slots":false}"#, #"{"slots":[1]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: Data(payload.utf8)))
        }
    }

    func testSelectingAssignedActionSwapsSlots() {
        var layout = NowPlayingSecondaryLayout.default
        layout.setAction(.favorite, at: 0)
        XCTAssertEqual(layout.slots, [.favorite, .airPlay, .addToPlaylist, nil])
        layout.setAction(.favorite, at: 3)
        XCTAssertEqual(layout.slots, [nil, .airPlay, .addToPlaylist, .favorite])
        layout.setAction(nil, at: 1)
        XCTAssertEqual(layout.slots, [nil, nil, .addToPlaylist, .favorite])
        let before = layout
        layout.setAction(.airPlay, at: 4)
        XCTAssertEqual(layout, before)
    }

    func testAvailabilityUsesProviderAndTrackCapabilities() {
        let plex = Track(id: "1", key: "track", title: "Plex", albumRatingKey: "album", artistRatingKey: "artist", sourceCompositeKey: "plex:account:server:1")
        let apple = Track(id: "2", key: "apple-catalog", title: "Apple", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey)
        func available(_ action: NowPlayingSecondaryAction, _ track: Track?, favorited: Bool = false) -> Bool {
            action.isAvailable(for: track, isFavorited: favorited, canAddToLibrary: false, hasRecentPlaylist: false)
        }
        XCTAssertTrue(available(.airPlay, nil))
        XCTAssertFalse(available(.favorite, nil))
        XCTAssertTrue(available(.shareAudioFile, plex))
        XCTAssertFalse(available(.shareAudioFile, apple))
        XCTAssertTrue(available(.goToAlbum, plex))
        XCTAssertFalse(available(.goToArtist, apple))
        XCTAssertFalse(available(.addToLibrary, plex))
        XCTAssertFalse(available(.addToRecentPlaylist, plex))
        XCTAssertTrue(available(.favorite, plex, favorited: true))
        XCTAssertFalse(available(.favorite, apple, favorited: true))
    }

    @MainActor
    func testSettingsPersistLayoutAndRecoverCorruptPayload() {
        let key = "nowPlayingSecondaryLayout"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(Data("corrupt".utf8), forKey: key)
        let settings = SettingsManager()
        XCTAssertEqual(settings.nowPlayingSecondaryLayout, .default)
        settings.resetNowPlayingSecondaryLayoutToDefaults()
        XCTAssertNoThrow(try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: key))))
        settings.nowPlayingSecondaryLayout = NowPlayingSecondaryLayout(slots: [nil, .shareLink])
        XCTAssertEqual(SettingsManager().nowPlayingSecondaryLayout.slots, [nil, .shareLink, nil, nil])
        settings.resetNowPlayingSecondaryLayoutToDefaults()
        XCTAssertEqual(settings.nowPlayingSecondaryLayout, .default)
    }
}
