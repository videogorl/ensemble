import EnsembleCore
import SwiftUI

/// Everything that varies between kinds of track-list detail screens (album,
/// playlist, merged playlist). `MediaDetailView` reads one of these instead of
/// taking each option as its own argument. Visual values stay in the design
/// system, not here.
struct DetailConfiguration {
    /// Kind-specific actions shown in the toolbar menu.
    enum Menu {
        case none
        case album(AlbumDetailMenuActions)
        case playlist(PlaylistDetailMenuActions)
    }

    /// Pin behaviour for screens whose item is a group of source items.
    struct Pin {
        let toggle: (Bool) -> Void
        let isPinned: (Set<String>) -> Bool
    }

    var mediaType: PinnedItemType?
    var menu: Menu = .none
    var showArtwork = true
    var showTrackNumbers = false
    var groupByDisc = false
    var showFilter = true
    var selectedTrackId: String?
    var hiddenCandidates: [HiddenMediaCandidate] = []
    var hiddenIdentity: HiddenMediaIdentity?
    var includesHidden = false
    var footerContent: AnyView?
    var supplementalLoad: (() async -> Void)?
    /// When nil, the default single-item pin behaviour is used.
    var pin: Pin?
}
