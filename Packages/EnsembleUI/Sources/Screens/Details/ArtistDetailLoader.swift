import EnsembleCore
import SwiftUI

struct ArtistDetailLoader: View {
    let artistId: String?
    let artistName: String?
    let artistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    let includesHidden: Bool
    let initialArtist: Artist?
    @State private var displayArtist: DisplayArtist?
    @State private var isLoading = true
    @State private var error: Error?
    
    @Environment(\.dependencies) private var deps

    init(
        artistId: String?,
        artistName: String? = nil,
        artistSourceKey: String? = nil,
        nowPlayingVM: NowPlayingViewModel,
        includesHidden: Bool = false
    ) {
        self.artistId = artistId
        self.artistName = artistName
        self.artistSourceKey = artistSourceKey
        self.nowPlayingVM = nowPlayingVM
        self.includesHidden = includesHidden
        self.initialArtist = nil
    }

    init(artist: Artist, nowPlayingVM: NowPlayingViewModel, includesHidden: Bool = false) {
        self.artistId = artist.id
        self.artistName = artist.name
        self.artistSourceKey = artist.sourceCompositeKey
        self.nowPlayingVM = nowPlayingVM
        self.includesHidden = includesHidden
        self.initialArtist = artist
    }
    
    var body: some View {
        Group {
            if let displayArtist {
                ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM, includesHidden: includesHidden)
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Loading artist…")
            } else if let error = error {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Failed to load artist",
                    message: error.localizedDescription
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Artist not found")
            }
        }
        .task {
            await loadArtist()
        }
    }
    
    @MainActor
    private func loadArtist() async {
        do {
            var artist: Artist?
            if let initialArtist {
                artist = initialArtist
            } else if let artistId {
                artist = try await deps.libraryRepository.fetchArtist(
                    ratingKey: artistId,
                    sourceCompositeKey: artistSourceKey
                ).map { Artist(from: $0) }
            }
            if artist == nil, let artistSourceKey {
                artist = try await deps.syncCoordinator.getArtist(
                    artistId: artistId,
                    name: artistName,
                    sourceKey: artistSourceKey
                )
            }
            guard let artist else {
                finishLoading(displayArtist: nil, error: nil)
                return
            }
            finishLoading(displayArtist: await resolveDisplayArtist(containing: artist), error: nil)
        } catch {
            finishLoading(displayArtist: nil, error: error)
        }
    }

    private func resolveDisplayArtist(containing artist: Artist) async -> DisplayArtist {
        let preferences = deps.settingsManager.mergingPreferences
        guard preferences.isEnabled, preferences.mergeArtists,
              let artists = try? await deps.libraryRepository.fetchArtists().map({ Artist(from: $0) }) else {
            return .single(artist)
        }
        let sourceConfiguration = deps.accountManager.sourceConfigurationSnapshot
        let hiddenSources = deps.libraryVisibilityStore.effectiveHiddenSourceCompositeKeys(
            enabledSourceCompositeKeys: sourceConfiguration.enabledSourceKeys
        )
        let visibleArtists = LibraryVisibilityFiltering.visibleArtists(
            artists,
            hiddenSourceCompositeKeys: hiddenSources,
            sourceConfiguration: sourceConfiguration.hasAnySources || !sourceConfiguration.isAuthoritative
                ? sourceConfiguration : nil,
            hiddenMedia: includesHidden ? .empty : deps.hiddenMediaStore.snapshot
        )
        let name = DisplayArtist.normalizedName(artist.name)
        return DisplayArtist.group(
            visibleArtists.filter { DisplayArtist.normalizedName($0.name) == name },
            preferences: preferences
        ).first { $0.artists.contains(where: { $0.sourceScopedID == artist.sourceScopedID }) }
            ?? .single(artist)
    }

    @MainActor
    private func finishLoading(displayArtist: DisplayArtist?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.displayArtist = displayArtist
            self.error = error
            self.isLoading = false
        }
    }
}
