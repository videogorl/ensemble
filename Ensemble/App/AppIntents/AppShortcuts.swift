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
            intent: PlayEnsembleTrackIntent(),
            phrases: [
                "Play track \(\.$track) on \(.applicationName)",
                "In \(.applicationName), play track \(\.$track)"
            ],
            shortTitle: "Play Track",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: PlayEnsembleCollectionIntent(),
            phrases: [
                "Play \(\.$collection) on \(.applicationName)",
                "In \(.applicationName), play \(\.$collection)",
                "\(\.$collection) on \(.applicationName)"
            ],
            shortTitle: "Play Collection",
            systemImageName: "heart.text.square"
        )

        AppShortcut(
            intent: SetEnsemblePlaybackOptionIntent(),
            phrases: [
                "Turn \(\.$option) in \(.applicationName)",
                "Set \(\.$option) in \(.applicationName)",
                "\(.applicationName) \(\.$option)"
            ],
            shortTitle: "Playback Option",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: EnsembleSongActionIntent(),
            phrases: [
                "\(\.$action) this song in \(.applicationName)",
                "\(\.$action) this song on \(.applicationName)",
                "Add this song to my favorites in \(.applicationName)"
            ],
            shortTitle: "This Song",
            systemImageName: "heart"
        )

        AppShortcut(
            intent: AddCurrentSongToEnsemblePlaylistIntent(),
            phrases: [
                "Add this song to \(\.$playlist) in \(.applicationName)",
                "Add this song to the playlist \(\.$playlist) on \(.applicationName)"
            ],
            shortTitle: "Add This Song to Playlist",
            systemImageName: "text.badge.plus"
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
