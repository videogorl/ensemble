import EnsembleDomain
import EnsemblePersistence
import Foundation

public enum ArtistDetailRequest: Hashable, Sendable {
    case artist(Artist)
    case reference(id: String?, name: String?, sourceKey: String?)
    case display(id: String)
}

/// Resolves artist routes against exact-source metadata before applying visible-library merging.
@MainActor
public struct ArtistDetailResolver {
    private let libraryRepository: LibraryRepositoryProtocol
    private let remoteArtist: (String?, String?, String) async throws -> Artist?
    private let visibleArtists: ([Artist]) -> [Artist]
    private let mergingPreferences: () -> EnsembleMergingPreferences

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        remoteArtist: @escaping (String?, String?, String) async throws -> Artist?,
        visibleArtists: @escaping ([Artist]) -> [Artist],
        mergingPreferences: @escaping () -> EnsembleMergingPreferences = { .default }
    ) {
        self.libraryRepository = libraryRepository
        self.remoteArtist = remoteArtist
        self.visibleArtists = visibleArtists
        self.mergingPreferences = mergingPreferences
    }

    public func resolve(
        _ request: ArtistDetailRequest,
        cachedArtists: [Artist]? = nil,
        cachedDisplayArtists: [DisplayArtist] = []
    ) async throws -> DisplayArtist? {
        try Task.checkCancellation()
        let sourceArtist: Artist?
        switch request {
        case .artist(let artist):
            sourceArtist = artist
        case .reference(let id, let name, let sourceKey):
            guard id?.isEmpty == false || name.map(DisplayArtist.normalizedName)?.isEmpty == false else { return nil }
            sourceArtist = Artist(id: id ?? "", key: "", name: name ?? "", sourceCompositeKey: sourceKey)
        case .display:
            sourceArtist = nil
        }
        if let sourceArtist, visibleArtists([sourceArtist]).isEmpty { return nil }

        let preferences = mergingPreferences()
        if case .artist(let artist) = request, !preferences.isEnabled || !preferences.mergeArtists {
            return .single(artist)
        }
        let libraryArtists: [Artist]
        if let cachedArtists {
            libraryArtists = cachedArtists
        } else {
            libraryArtists = try await libraryRepository.fetchArtists().map(Artist.init(from:))
        }
        let artists = visibleArtists(libraryArtists)

        if case .display(let id) = request {
            if let cached = cachedDisplayArtists.first(where: { $0.id == id }) {
                guard let member = visibleArtists(cached.artists).first else { return nil }
                return DisplayArtist.group(
                    artists.filter { DisplayArtist.normalizedName($0.name) == DisplayArtist.normalizedName(cached.name) },
                    preferences: mergingPreferences()
                ).first { $0.artists.contains { $0.sourceScopedID == member.sourceScopedID } }
            }
            return DisplayArtist.group(artists, preferences: mergingPreferences()).first { $0.id == id }
        }

        let artist: Artist?
        switch request {
        case .artist(let initialArtist):
            artist = initialArtist
        case .reference(let id, let name, let sourceKey):
            guard let sourceKey else { return nil }
            artist = try await resolveReference(id: id, name: name, sourceKey: sourceKey, artists: libraryArtists)
        case .display:
            return nil
        }
        try Task.checkCancellation()
        guard let artist, !visibleArtists([artist]).isEmpty else { return nil }
        let matches = visibleArtists(libraryArtists).filter {
            DisplayArtist.normalizedName($0.name) == DisplayArtist.normalizedName(artist.name)
        }
        return DisplayArtist.group(matches, preferences: mergingPreferences())
            .first { $0.artists.contains { $0.sourceScopedID == artist.sourceScopedID } }
            ?? .single(artist)
    }

    private func resolveReference(id: String?, name: String?, sourceKey: String, artists: [Artist]) async throws -> Artist? {
        if let local = artists.first(where: { $0.id == id && $0.sourceCompositeKey == sourceKey }) {
            return local
        }
        if let id, let stored = try await libraryRepository.fetchArtist(ratingKey: id, sourceCompositeKey: sourceKey) {
            return Artist(from: stored)
        }
        if let name, let local = artists.first(where: {
            $0.sourceCompositeKey == sourceKey && DisplayArtist.normalizedName(name) == DisplayArtist.normalizedName($0.name)
        }) {
            return local
        }
        if let name, let stored = try await libraryRepository.findArtistsByName(name, sourceCompositeKeys: [sourceKey]).first {
            return Artist(from: stored)
        }
        let remote = try await remoteArtist(id, name, sourceKey)
        return remote?.sourceCompositeKey == sourceKey ? remote : nil
    }
}
