import EnsembleSiriShared
import Foundation

/// The track lists behind the library collections the app plays: a mood and what was added recently.
/// Reads cached rows (recently added) or the Plex libraries (mood); it never writes.
@MainActor
public struct LibraryCollectionTracks {
    private let accountManager: AccountManager
    private let libraryRepository: LibraryRepositoryProtocol
    private let moodRepository: MoodRepository

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        moodRepository: MoodRepository
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.moodRepository = moodRepository
    }

    // MARK: - Recently added

    /// Tracks of the most recently added albums, newest album first.
    public func recentlyAddedTracks(albumLimit: Int = 10) async throws -> [Track] {
        let albums = try await enabledAlbums()
            .filter { $0.dateAdded != nil }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        return try await tracks(of: Array(albums.prefix(albumLimit)))
    }

    // MARK: - Mood

    /// Cached moods, merged across libraries by name.
    public func moods() async -> [Mood] {
        guard let cached = try? await moodRepository.fetchMoods() else { return [] }
        return SearchViewModel.mergeMoodsForDisplay(cached)
    }

    /// Tracks the Plex libraries list under the mood. Plex mood keys are library-local: prefer the key captured
    /// while the mood list was built, then fall back to resolving the mood by title.
    public func tracks(for mood: Mood) async -> [Track] {
        var allTracks: [Track] = []
        var seen = Set<String>()

        let targetMoodTitleKey = Mood.normalizedTitleKey(mood.title)
        let targetReferences = Mood.sourceReferences(from: mood.sourceCompositeKey)
        let targetSourceKeys = Set(targetReferences.map(\.sourceCompositeKey))
        var cachedMoodKeysBySource: [String: String] = [:]
        for reference in targetReferences {
            if let moodKey = reference.moodKey {
                cachedMoodKeysBySource[reference.sourceCompositeKey] = moodKey
            }
        }

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                for library in server.libraries where library.isEnabled {
                    let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"
                    if !targetSourceKeys.isEmpty, !targetSourceKeys.contains(sourceKey) {
                        continue
                    }

                    do {
                        let moodKey: String
                        if let cachedMoodKey = cachedMoodKeysBySource[sourceKey] {
                            moodKey = cachedMoodKey
                        } else {
                            let libraryMood = try await client.getMoods(sectionKey: library.key)
                                .first { Mood.normalizedTitleKey($0.title) == targetMoodTitleKey }
                            guard let libraryMood else { continue }
                            moodKey = libraryMood.key
                        }

                        for plexTrack in try await client.getTracksByMood(sectionKey: library.key, moodKey: moodKey) {
                            let track = Track(from: plexTrack, sourceKey: sourceKey)
                            // Dedup only repeat results from the same source; cross-source duplicates stay distinct.
                            if seen.insert(track.sourceScopedID).inserted {
                                allTracks.append(track)
                            }
                        }
                    } catch {
                        // Continue to the next library if this one fails.
                        continue
                    }
                }
            }
        }
        return allTracks
    }

    // MARK: - Shared

    private func enabledSourceKeys() -> Set<String> {
        SystemMediaSourceScope.enabledLibraryKeys(for: accountManager.enabledSources())
    }

    private func enabledAlbums() async throws -> [Album] {
        let enabledKeys = enabledSourceKeys()
        return try await libraryRepository.fetchAlbums().map(Album.init(from:)).filter {
            enabledKeys.contains($0.sourceCompositeKey ?? "")
        }
    }

    private func tracks(of albums: [Album]) async throws -> [Track] {
        var tracks: [Track] = []
        for album in albums {
            guard let sourceKey = album.sourceCompositeKey else { continue }
            tracks += try await libraryRepository.fetchTracks(forAlbum: album.id, sourceCompositeKey: sourceKey)
                .map(Track.init(from:))
        }
        return tracks
    }
}

@MainActor
public extension DependencyContainer {
    var libraryCollectionTracks: LibraryCollectionTracks {
        LibraryCollectionTracks(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            moodRepository: moodRepository
        )
    }
}
