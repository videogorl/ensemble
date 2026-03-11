import EnsembleCore
import SwiftUI

/// Static helpers that bridge ShareService payloads to the system share sheet.
/// Called from context menus and buttons across the app.
public enum ShareActions {

    /// Share a universal link for a track (song.link → Apple Music → plain text fallback).
    public static func shareTrackLink(_ track: Track, deps: DependencyContainer) {
        Task { @MainActor in
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "link",
                    title: "Finding link…",
                    message: nil,
                    dedupeKey: "share-link-\(track.id)"
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
                    dedupeKey: "share-link-\(album.id)"
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
                        dedupeKey: "share-file-download-\(track.id)"
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
                        dedupeKey: "share-file-failed-\(track.id)"
                    )
                )
                return
            }

            presentPayload(payload, deps: deps)
        }
    }

    // MARK: - Private

    @MainActor
    private static func presentPayload(_ payload: SharePayload, deps: DependencyContainer) {
        switch payload {
        case .link(let url, let text):
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

        case .file(let url, let title):
            ShareSheetPresenter.present(items: [url]) {
                deps.shareService.cleanupTempFiles()
            }
        }
    }
}
