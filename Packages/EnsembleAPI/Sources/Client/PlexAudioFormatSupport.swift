import Foundation

/// Audio formats Ensemble can parse incrementally with Audio File Stream Services.
/// Keep Plex's advertised direct-play profile and the original-file fast path aligned.
public enum PlexAudioFormatSupport {
    public static let directPlayCodecs = ["aac", "mp3", "flac", "alac"]

    public static func supportsIncrementalPlayback(_ track: PlexTrack) -> Bool {
        guard let media = track.media?.first else {
            return supportsIncrementalPlayback(
                codec: nil,
                container: nil,
                fileExtension: track.streamURL.flatMap(pathExtension)
            )
        }

        let part = media.part?.first
        let codec = part?.stream?.first(where: { $0.streamType == 2 })?.codec ?? media.audioCodec
        let container = part?.container ?? media.container
        let fileExtension = part?.file.flatMap(pathExtension)
            ?? part?.key.flatMap(pathExtension)
        return supportsIncrementalPlayback(
            codec: codec,
            container: container,
            fileExtension: fileExtension
        )
    }

    public static func supportsIncrementalPlayback(
        codec: String?,
        container: String?,
        fileExtension: String?
    ) -> Bool {
        let codec = normalized(codec)
        let container = normalized(container)
        let fileExtension = normalized(fileExtension)

        switch codec {
        case "mp3":
            return container.map { ["mp3", "mpeg"].contains($0) } ?? true
        case "aac", "alac":
            return container.map { ["m4a", "mp4", "mov", "3gp"].contains($0) } ?? true
        case "flac":
            return container == nil || container == "flac"
        case "pcm", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le":
            return container.map { ["wav", "wave", "aif", "aiff", "aifc", "caf"].contains($0) } ?? true
        case .some:
            return false
        case nil:
            return fileExtension.map {
                ["mp3", "m4a", "mp4", "aac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf", "alac"].contains($0)
            } ?? false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func pathExtension(_ path: String) -> String? {
        let pathExtension = URL(fileURLWithPath: path).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension
    }
}
