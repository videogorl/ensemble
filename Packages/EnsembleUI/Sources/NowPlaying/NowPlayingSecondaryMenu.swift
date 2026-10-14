import EnsembleCore

/// Overflow order is independent of the configured visible slots.
enum NowPlayingSecondaryMenu {
    static let sections: [[NowPlayingSecondaryAction]] = [
        [.airPlay, .favorite, .addToPlaylist, .addToLibrary],
        [.goToAlbum, .goToArtist],
        [.shareEnsembleLink, .shareLink, .shareAudioFile],
        [.addToRecentPlaylist]
    ]
}
