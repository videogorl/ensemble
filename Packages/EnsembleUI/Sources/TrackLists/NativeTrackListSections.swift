import EnsembleCore

/// Shared section model for native track list backends.
///
/// Screens can pass a flat section or indexed sections without depending on a
/// Songs-specific type name.
public struct NativeTrackListSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let tracks: [Track]

    public init(id: String, title: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.tracks = tracks
    }
}

public typealias SongsTrackListSection = NativeTrackListSection
