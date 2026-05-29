import Foundation

public enum LibraryBrowseRefreshPhase: Equatable, Sendable {
    case idle
    case loading
    case refreshing
}

public struct TrackBrowseSnapshot: Equatable, Sendable {
    public let tracks: [Track]
    public let sections: [LibraryViewModel.TrackSection]
    public let availableGenres: [String]
    public let phase: LibraryBrowseRefreshPhase
    public let isShowingStaleSnapshot: Bool

    public static let empty = TrackBrowseSnapshot(
        tracks: [],
        sections: [],
        availableGenres: [],
        phase: .idle,
        isShowingStaleSnapshot: false
    )

    public var hasVisibleContent: Bool {
        !tracks.isEmpty
    }

    public func updating(
        availableGenres: [String]? = nil,
        phase: LibraryBrowseRefreshPhase? = nil,
        isShowingStaleSnapshot: Bool? = nil
    ) -> Self {
        TrackBrowseSnapshot(
            tracks: tracks,
            sections: sections,
            availableGenres: availableGenres ?? self.availableGenres,
            phase: phase ?? self.phase,
            isShowingStaleSnapshot: isShowingStaleSnapshot ?? self.isShowingStaleSnapshot
        )
    }
}

public struct ArtistBrowseSnapshot: Equatable, Sendable {
    public let artists: [Artist]
    public let displayArtists: [DisplayArtist]
    public let sections: [LibraryViewModel.ArtistSection]
    public let availableGenres: [String]
    public let phase: LibraryBrowseRefreshPhase
    public let isShowingStaleSnapshot: Bool

    public static let empty = ArtistBrowseSnapshot(
        artists: [],
        displayArtists: [],
        sections: [],
        availableGenres: [],
        phase: .idle,
        isShowingStaleSnapshot: false
    )

    public var hasVisibleContent: Bool {
        !displayArtists.isEmpty
    }

    public func updating(
        availableGenres: [String]? = nil,
        phase: LibraryBrowseRefreshPhase? = nil,
        isShowingStaleSnapshot: Bool? = nil
    ) -> Self {
        ArtistBrowseSnapshot(
            artists: artists,
            displayArtists: displayArtists,
            sections: sections,
            availableGenres: availableGenres ?? self.availableGenres,
            phase: phase ?? self.phase,
            isShowingStaleSnapshot: isShowingStaleSnapshot ?? self.isShowingStaleSnapshot
        )
    }
}

public struct AlbumBrowseSnapshot: Equatable, Sendable {
    public let albums: [Album]
    public let sections: [LibraryViewModel.AlbumSection]
    public let availableGenres: [String]
    public let phase: LibraryBrowseRefreshPhase
    public let isShowingStaleSnapshot: Bool

    public static let empty = AlbumBrowseSnapshot(
        albums: [],
        sections: [],
        availableGenres: [],
        phase: .idle,
        isShowingStaleSnapshot: false
    )

    public var hasVisibleContent: Bool {
        !albums.isEmpty
    }

    public func updating(
        availableGenres: [String]? = nil,
        phase: LibraryBrowseRefreshPhase? = nil,
        isShowingStaleSnapshot: Bool? = nil
    ) -> Self {
        AlbumBrowseSnapshot(
            albums: albums,
            sections: sections,
            availableGenres: availableGenres ?? self.availableGenres,
            phase: phase ?? self.phase,
            isShowingStaleSnapshot: isShowingStaleSnapshot ?? self.isShowingStaleSnapshot
        )
    }
}

public struct GenreBrowseSnapshot: Equatable, Sendable {
    public let displayGenres: [DisplayGenre]
    public let phase: LibraryBrowseRefreshPhase
    public let isShowingStaleSnapshot: Bool

    public static let empty = GenreBrowseSnapshot(
        displayGenres: [],
        phase: .idle,
        isShowingStaleSnapshot: false
    )

    public var hasVisibleContent: Bool {
        !displayGenres.isEmpty
    }

    public func updating(
        phase: LibraryBrowseRefreshPhase? = nil,
        isShowingStaleSnapshot: Bool? = nil
    ) -> Self {
        GenreBrowseSnapshot(
            displayGenres: displayGenres,
            phase: phase ?? self.phase,
            isShowingStaleSnapshot: isShowingStaleSnapshot ?? self.isShowingStaleSnapshot
        )
    }
}
