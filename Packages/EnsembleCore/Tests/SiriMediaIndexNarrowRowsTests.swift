import CoreData
import EnsembleDomain
import EnsembleSiriShared
@testable import EnsembleCore
@testable import EnsemblePersistence
import XCTest

/// The index is built from narrow dictionary rows; it must equal the one the full objects gave.
final class SiriMediaIndexNarrowRowsTests: XCTestCase {
    private static let names: [String?] = [
        "abba", "ABBA", "The Beatles", "Beatles", "Édith Piaf", "Edith Piaf", "Zoë", "10", "9", "100", "!!!", "#1 Hits",
        "", "😀 Emoji", "Björk", "ß", "ss", "Ленинград", "你好", "ひかる", "ヒカル", "AC/DC", nil
    ]

    func testIndexItemsAndHiddenDecisionsMatchTheFullObjectReads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-narrow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let repository = LibraryRepository(coreDataStack: stack)
        let writer = stack.newBackgroundContext()
        try await writer.perform {
            for (index, name) in Self.names.enumerated() {
                var artist: CDArtist?
                if let name {
                    let created = CDArtist(context: writer)
                    created.ratingKey = "artist-\(index)"
                    created.key = "k"
                    created.name = name
                    created.sourceCompositeKey = index == 3 ? nil : "plex:a:s"
                    created.thumbPath = index % 2 == 0 ? "/library/metadata/\(index)/thumb/1" : nil
                    artist = created
                }
                for (offset, year) in [Int32(2024), 1999, 0, 1999].enumerated() {
                    let album = CDAlbum(context: writer)
                    album.ratingKey = "album-\(index)-\(offset)"
                    album.key = "k"
                    album.title = "Album \(offset)"
                    album.artistName = offset == 1 ? nil : name
                    album.albumArtist = offset == 2 ? "Various" : nil
                    album.year = year
                    album.trackCount = Int32(offset)
                    album.genreNames = offset == 3 ? "Rock, Pop" : nil
                    album.thumbPath = offset == 0 ? "/library/metadata/\(index)/thumb/9" : nil
                    album.sourceCompositeKey = "plex:a:s"
                    album.artist = artist
                }
            }
            try writer.save()
        }
        // One hidden artist (hides its albums too), one hidden album, one source-less artist.
        let hidden = HiddenMediaSnapshot(identities: [
            .init(kind: .artist, itemID: "artist-4", sourceCompositeKey: "plex:a:s"),
            .init(kind: .album, itemID: "album-6-0", sourceCompositeKey: "plex:a:s")
        ])

        let artistRows = try await repository.fetchSiriArtistRows()
        let albumRows = try await repository.fetchSiriAlbumRows()
        let artistObjects = try await repository.fetchArtists()
        let albumObjects = try await repository.fetchAlbums()

        XCTAssertEqual(
            artistRows.map { SiriMediaIndexStore.indexItem(for: $0) },
            artistObjects.map(Self.legacyItem)
        )
        XCTAssertEqual(
            albumRows.map { SiriMediaIndexStore.indexItem(for: $0) },
            albumObjects.map(Self.legacyItem)
        )
        XCTAssertEqual(
            artistRows.map { SiriMediaIndexStore.isHidden($0, in: hidden) },
            artistObjects.map { hidden.isHidden(Artist(from: $0)) }
        )
        XCTAssertEqual(
            albumRows.map { SiriMediaIndexStore.isHidden($0, in: hidden) },
            albumObjects.map { hidden.isHidden(Album(from: $0)) }
        )
        XCTAssertTrue(albumRows.contains { SiriMediaIndexStore.isHidden($0, in: hidden) })
    }

    /// The mappers as they read `CDArtist` / `CDAlbum` before the index took rows.
    private static func legacyItem(_ artist: CDArtist) -> SiriMediaIndexItem {
        let hasThumb = !(artist.thumbPath ?? "").isEmpty
        return SiriMediaIndexItem(
            kind: .artist, id: artist.ratingKey, displayName: artist.name, sourceCompositeKey: artist.sourceCompositeKey,
            secondaryText: nil, lastPlayed: nil, playCount: nil, trackCount: nil, artistName: artist.name,
            artworkPath: hasThumb ? artist.thumbPath : nil,
            artworkCacheKey: hasThumb ? artist.ratingKey : nil,
            artworkCacheType: hasThumb ? .artist : nil
        )
    }

    private static func legacyItem(_ album: CDAlbum) -> SiriMediaIndexItem {
        SiriMediaIndexItem(
            kind: .album, id: album.ratingKey, displayName: album.title, sourceCompositeKey: album.sourceCompositeKey,
            secondaryText: album.artistName, lastPlayed: nil, playCount: nil, trackCount: Int(album.trackCount),
            albumTitle: album.title, artistName: album.artistName ?? album.albumArtist, genre: album.genreNames,
            artworkPath: album.thumbPath, artworkCacheKey: album.ratingKey, artworkCacheType: .album,
            year: album.year > 0 ? Int(album.year) : nil,
            albumArtist: album.albumArtist ?? album.artistName ?? album.artist?.name
        )
    }
}
