import AppIntents

/// Voice phrases and Shortcuts tiles. Every other intent is an action in the Shortcuts editor.
struct EnsembleAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayEnsemblePlaylistIntent(),
            phrases: [
                "Play playlist \(\.$playlist) on \(.applicationName)",
                "Play the playlist \(\.$playlist) on \(.applicationName)",
                "In \(.applicationName), play playlist \(\.$playlist)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: PlayEnsembleAlbumIntent(),
            phrases: [
                "Play album \(\.$album) on \(.applicationName)",
                "In \(.applicationName), play album \(\.$album)"
            ],
            shortTitle: "Play Album",
            systemImageName: "opticaldisc"
        )

        AppShortcut(
            intent: PlayEnsembleArtistIntent(),
            phrases: [
                "Play artist \(\.$artist) on \(.applicationName)",
                "Play the artist \(\.$artist) on \(.applicationName)",
                "Play music by \(\.$artist) on \(.applicationName)",
                "In \(.applicationName), play artist \(\.$artist)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )

        AppShortcut(
            intent: ShuffleEnsembleLibraryIntent(),
            phrases: [
                "Shuffle my library on \(.applicationName)",
                "Shuffle my music on \(.applicationName)",
                "In \(.applicationName), shuffle my library"
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: PlayEnsembleFavoritesIntent(),
            phrases: [
                "Play my favorites on \(.applicationName)",
                "Play my favourite songs on \(.applicationName)",
                "In \(.applicationName), play my favorites"
            ],
            shortTitle: "Play Favorites",
            systemImageName: "heart"
        )

        AppShortcut(
            intent: PlayEnsembleTrackIntent(),
            phrases: [
                "Play track \(\.$track) on \(.applicationName)",
                "In \(.applicationName), play track \(\.$track)"
            ],
            shortTitle: "Play Track",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: OpenEnsembleMediaIntent(),
            phrases: [
                "Open \(\.$media) in \(.applicationName)"
            ],
            shortTitle: "Open Media",
            systemImageName: "arrow.up.forward.app"
        )
    }
}
