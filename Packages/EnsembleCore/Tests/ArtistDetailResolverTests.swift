import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class ArtistDetailResolverTests: XCTestCase {
    private let firstSource = "plex:account:server:1"
    private let requestedSource = "plex:account:server:2"

    private func artist(source: String, name: String = "half·alive") -> Artist {
        Artist(id: "42", key: "/library/metadata/42", name: name, sourceCompositeKey: source)
    }

    private func visible(_ artists: [Artist]) -> [Artist] {
        LibraryVisibilityFiltering.visibleArtists(
            artists, hiddenSourceCompositeKeys: [], sourceConfiguration: nil, hiddenMedia: .empty
        )
    }

    func testAllArtistRoutesAnchorToRequestedSourceBeforeMerging() async throws {
        let first = artist(source: firstSource, name: "half•alive")
        let requested = artist(source: requestedSource)
        let requests: [ArtistDetailRequest] = [
            .artist(requested),
            .reference(id: requested.id, name: "Unrelated title", sourceKey: requestedSource),
            .reference(id: nil, name: "HALF-ALIVE", sourceKey: requestedSource),
            .display(id: DisplayArtist.single(requested).id)
        ]
        for mergeArtists in [false, true] {
            let resolver = ArtistDetailResolver(
                libraryRepository: EmptyLibraryRepository(),
                remoteArtist: { _, _, _ in XCTFail("Cached routes should not need remote lookup"); return nil },
                visibleArtists: visible,
                mergingPreferences: { EnsembleMergingPreferences(mergeArtists: mergeArtists) }
            )
            for request in requests {
                let result = try await resolver.resolve(
                    request, cachedArtists: [first, requested],
                    cachedDisplayArtists: [.single(requested)]
                )
                let resolved = try XCTUnwrap(result, "\(request), merging: \(mergeArtists)")
                XCTAssertEqual(Set(resolved.artists.map(\.sourceScopedID)),
                               Set((mergeArtists ? [first, requested] : [requested]).map(\.sourceScopedID)))
            }
        }
    }

    func testHiddenDisabledAndMalformedRoutesCannotResolveThroughVisibleNamesakes() async throws {
        let requested = artist(source: requestedSource)
        let source = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "2")
        let disabled = SourceConfigurationSnapshot(
            configuredSources: [source], enabledSources: [], authoritativeSourceTypes: [.plex],
            hasAnySources: true, isAuthoritative: true
        )
        let hiddenItem = HiddenMediaSnapshot(identities: [
            HiddenMediaIdentity(kind: .artist, itemID: requested.id, sourceCompositeKey: requestedSource)
        ])
        let cases: [(String, Set<String>, SourceConfigurationSnapshot?, HiddenMediaSnapshot)] = [
            (requestedSource, [requestedSource], nil, .empty),
            (requestedSource, [], disabled, .empty),
            (requestedSource, [], nil, hiddenItem),
            ("malformed", [], nil, .empty)
        ]
        for (sourceKey, hiddenSources, configuration, hiddenMedia) in cases {
            let resolver = ArtistDetailResolver(
                libraryRepository: EmptyLibraryRepository(),
                remoteArtist: { _, _, _ in XCTFail("Invisible routes must not reach a provider"); return nil },
                visibleArtists: {
                    LibraryVisibilityFiltering.visibleArtists(
                        $0, hiddenSourceCompositeKeys: hiddenSources,
                        sourceConfiguration: configuration, hiddenMedia: hiddenMedia
                    )
                }
            )
            let result = try await resolver.resolve(
                .reference(id: requested.id, name: requested.name, sourceKey: sourceKey),
                cachedArtists: [artist(source: firstSource), requested]
            )
            XCTAssertNil(result, sourceKey)
        }
    }

    func testRemoteLookupCannotSubstituteAnotherSourceAndRechecksVisibilityAfterAwait() async throws {
        for returnedSource in [firstSource, requestedSource] {
            for hideDuringLookup in [false, true] {
                var hiddenSources = Set<String>()
                let resolver = ArtistDetailResolver(
                    libraryRepository: EmptyLibraryRepository(),
                    remoteArtist: { id, name, source in
                        XCTAssertEqual(id, "42")
                        XCTAssertEqual(name, "half·alive")
                        XCTAssertEqual(source, self.requestedSource)
                        if hideDuringLookup { hiddenSources.insert(source) }
                        return self.artist(source: returnedSource)
                    },
                    visibleArtists: {
                        LibraryVisibilityFiltering.visibleArtists(
                            $0, hiddenSourceCompositeKeys: hiddenSources, sourceConfiguration: nil, hiddenMedia: .empty
                        )
                    }
                )
                let result = try await resolver.resolve(
                    .reference(id: "42", name: "half·alive", sourceKey: requestedSource),
                    cachedArtists: [artist(source: firstSource)]
                )
                XCTAssertEqual(result?.primaryArtist.sourceCompositeKey,
                               returnedSource == requestedSource && !hideDuringLookup ? requestedSource : nil)
            }
        }
    }

    func testPersistedExactIDWinsOverStaleCachedNamesake() async throws {
        let repository = LibraryRepository(coreDataStack: .inMemory())
        for source in [firstSource, requestedSource] {
            try await repository.batchUpsertArtists([
                ArtistUpsertInput(ratingKey: "42", key: "/library/metadata/42", name: "half·alive",
                                  summary: nil, thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: nil)
            ], sourceCompositeKey: source)
        }
        let resolver = ArtistDetailResolver(
            libraryRepository: repository,
            remoteArtist: { _, _, _ in XCTFail("Persisted metadata should resolve locally"); return nil },
            visibleArtists: visible
        )
        let namesake = Artist(id: "43", key: "/artist/43", name: "half·alive", sourceCompositeKey: requestedSource)
        for cached in [[], [namesake]] {
            let result = try await resolver.resolve(
                .reference(id: "42", name: "half·alive", sourceKey: requestedSource), cachedArtists: cached
            )
            XCTAssertEqual(result?.primaryArtist.sourceScopedID, "\(requestedSource)||42")
        }
    }
}
