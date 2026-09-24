import EnsembleCore
import EnsembleDomain
import XCTest

final class DisplayAlbumTests: XCTestCase {
    func testAlbumFamilyGroupingRetainsSourcesAndKeepsDistinctEditionsSeparate() {
        let plex = Album(
            id: "plex",
            key: "/plex",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            year: 2012,
            trackCount: 16,
            sourceCompositeKey: "plex:a:s:3"
        )
        let apple = Album(
            id: "apple",
            key: "/apple",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            year: 2012,
            trackCount: 16,
            sourceCompositeKey: "appleMusic:a:d:l"
        )
        let standard = Album(
            id: "standard",
            key: "/standard",
            title: "Synthetica",
            artistName: "Metric",
            year: 2012,
            trackCount: 11,
            sourceCompositeKey: "plex:a:s:3"
        )
        let missingYear = Album(
            id: "unknown",
            key: "/unknown",
            title: "Synthetica (Deluxe Edition)",
            artistName: "Metric",
            sourceCompositeKey: "plex:a:other:3"
        )
        let preferences = EnsembleMergingPreferences(
            mergeAlbums: true,
            preferredSourceKeys: ["appleMusic:a:d:l", "plex:a:s:3"]
        )

        let groups = DisplayAlbum.group([plex, apple, standard, missingYear], preferences: preferences)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].albums.map(\.id), ["apple", "plex"])
        XCTAssertEqual(groups[0].primaryAlbum.id, "apple")
        XCTAssertEqual(groups[1].primaryAlbum.id, "standard")
        XCTAssertEqual(groups[2].primaryAlbum.id, "unknown")
    }

    func testAlbumTrackProjectionKeepsSourceCopiesInTrackOrder() {
        let plexSource = "plex:a:s:3"
        let appleSource = "appleMusic:a:d:l"
        let tracks = [
            makeTrack(id: "plex-14", title: "Breathing Underwater", number: 14, duration: 230, source: plexSource),
            makeTrack(id: "plex-15", title: "Gimme Sympathy", number: 15, duration: 210, source: plexSource),
            makeTrack(id: "plex-16", title: "Black Sheep", number: 16, duration: 250, source: plexSource),
            makeTrack(id: "apple-14", title: "Breathing Underwater", number: 14, duration: 230, source: appleSource),
            makeTrack(id: "apple-15", title: "Gimme Sympathy", number: 15, duration: 215, source: appleSource),
            makeTrack(id: "apple-16", title: "Black Sheep", number: 16, duration: 250, source: appleSource),
        ]

        let separate = MergingProjection.albumTracks(
            tracks,
            preferences: EnsembleMergingPreferences(
                mergeTracks: false,
                preferredSourceKeys: [plexSource, appleSource]
            )
        )
        let merged = MergingProjection.albumTracks(
            tracks,
            preferences: EnsembleMergingPreferences(
                mergeTracks: true,
                preferredSourceKeys: [plexSource, appleSource]
            )
        )

        XCTAssertEqual(separate.map(\.id), ["plex-14", "apple-14", "plex-15", "apple-15", "plex-16", "apple-16"])
        XCTAssertEqual(merged.map(\.id), ["plex-14", "plex-15", "apple-15", "plex-16"])
        XCTAssertEqual(
            MergingProjection.mutationCandidates(
                for: merged[0],
                in: tracks,
                preferences: EnsembleMergingPreferences(
                    mergeTracks: true,
                    preferredSourceKeys: [plexSource, appleSource]
                )
            ).map(\.id),
            ["plex-14", "apple-14"]
        )
        XCTAssertEqual(
            MergingProjection.mutationCandidates(
                for: merged[2],
                in: tracks,
                preferences: EnsembleMergingPreferences(
                    mergeTracks: true,
                    preferredSourceKeys: [plexSource, appleSource]
                )
            ).map(\.id),
            ["apple-15"]
        )
    }

    private func makeTrack(
        id: String,
        title: String,
        number: Int,
        duration: TimeInterval,
        source: String
    ) -> Track {
        Track(
            id: id,
            key: "/\(id)",
            title: title,
            artistName: "Metric",
            albumName: "Synthetica (Deluxe Edition)",
            trackNumber: number,
            duration: duration,
            sourceCompositeKey: source
        )
    }
}
