import EnsembleCore
import EnsembleSiriShared
import SwiftUI

/// Static helpers that bridge ShareService payloads to the system share sheet.
/// Called from context menus and buttons across the app.
public enum ShareActions {

    /// Share a library-independent Ensemble link for a track.
    @MainActor public static func shareEnsembleLink(_ track: Track, deps: DependencyContainer) {
        shareEnsembleLink(
            EnsemblePermalink(
                kind: .track,
                title: track.title,
                artistName: track.artistName ?? track.albumArtistName,
                albumTitle: track.albumName,
                duration: track.duration,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber
            ),
            deps: deps
        )
    }

    /// Share a library-independent Ensemble link for an album.
    @MainActor public static func shareEnsembleLink(_ album: Album, deps: DependencyContainer) {
        shareEnsembleLink(
            EnsemblePermalink(
                kind: .album,
                title: album.title,
                artistName: album.artistName ?? album.albumArtist,
                year: album.year
            ),
            deps: deps
        )
    }

    /// Share a library-independent Ensemble link for an artist.
    @MainActor public static func shareEnsembleLink(_ artist: Artist, deps: DependencyContainer) {
        shareEnsembleLink(EnsemblePermalink(kind: .artist, title: artist.name), deps: deps)
    }

    /// Share a library-independent Ensemble link for a playlist.
    @MainActor public static func shareEnsembleLink(_ playlist: Playlist, deps: DependencyContainer) {
        shareEnsembleLink(
            EnsemblePermalink(
                kind: .playlist,
                title: playlist.title,
                isSmartPlaylist: playlist.isSmart
            ),
            deps: deps
        )
    }

    /// Share one portable link for a same-named merged playlist.
    @MainActor public static func shareEnsembleLink(_ playlist: DisplayPlaylist, deps: DependencyContainer) {
        shareEnsembleLink(
            EnsemblePermalink(
                kind: .playlist,
                title: playlist.title,
                isSmartPlaylist: playlist.isSmart
            ),
            deps: deps
        )
    }

    /// Share a universal link for a track (song.link → Apple Music → plain text fallback).
    public static func shareTrackLink(_ track: Track, deps: DependencyContainer) {
        Task { @MainActor in
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "link",
                    title: "Finding link…",
                    message: nil,
                    dedupeKey: "share-link-\(track.sourceScopedID)"
                )
            )
            let payload = await deps.shareService.prepareTrackLinkPayload(track: track)
            presentPayload(payload, deps: deps)
        }
    }

    /// Share a universal link for an album (song.link → Apple Music → plain text fallback).
    public static func shareAlbumLink(_ album: Album, deps: DependencyContainer) {
        Task { @MainActor in
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "link",
                    title: "Finding link…",
                    message: nil,
                    dedupeKey: "share-link-\(album.sourceScopedID)"
                )
            )
            let payload = await deps.shareService.prepareAlbumLinkPayload(album: album)
            presentPayload(payload, deps: deps)
        }
    }

    /// Share a track's audio file.
    /// For downloaded tracks: presents share sheet immediately.
    /// For non-downloaded tracks: shows progress toast, downloads to temp, then presents.
    public static func shareTrackFile(_ track: Track, deps: DependencyContainer) {
        Task { @MainActor in
            // Show progress toast for non-downloaded tracks
            let isDownloaded = track.localFilePath != nil
            if !isDownloaded {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: "arrow.down.circle",
                        title: "Preparing audio file…",
                        message: nil,
                        dedupeKey: "share-file-download-\(track.sourceScopedID)"
                    )
                )
            }

            guard let payload = await deps.shareService.prepareTrackFilePayload(track: track) else {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "exclamationmark.triangle.fill",
                        title: "Couldn't prepare audio file",
                        message: "Check your connection and try again.",
                        dedupeKey: "share-file-failed-\(track.sourceScopedID)"
                    )
                )
                return
            }

            presentPayload(payload, deps: deps)
        }
    }

    // MARK: - Private

    @MainActor
    private static func shareEnsembleLink(_ permalink: EnsemblePermalink, deps: DependencyContainer) {
        guard let url = permalink.url else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: EnsembleDesign.Icon.error,
                    title: "Couldn't create Ensemble link",
                    message: nil,
                    dedupeKey: "share-ensemble-link-failed"
                )
            )
            return
        }
        deps.toastCenter.dismissCurrent()
        ShareSheetPresenter.present(items: [url])
    }

    @MainActor
    private static func presentPayload(_ payload: SharePayload, deps: DependencyContainer) {
        // Dismiss any active toast so it doesn't float above the share sheet
        deps.toastCenter.dismissCurrent()

        switch payload {
        case .link(let url, _):
            ShareSheetPresenter.present(items: [url]) {
                deps.shareService.cleanupTempFiles()
            }

        case .text(let text):
            // Show a toast indicating we're sharing text instead of a link
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "text.quote",
                    title: "Sharing as text",
                    message: "No streaming link found for this item.",
                    dedupeKey: "share-text-fallback"
                )
            )
            ShareSheetPresenter.present(items: [text])

        case .file(let url, _):
            ShareSheetPresenter.present(items: [url]) {
                deps.shareService.cleanupTempFiles()
            }
        }
    }
}
