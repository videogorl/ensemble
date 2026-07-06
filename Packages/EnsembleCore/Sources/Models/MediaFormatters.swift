import Foundation

/// Shared media display formatters used by domain models, ViewModels, and UI.
public enum MediaFormatters {
    public static func trackClock(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    public static func negativeTrackClock(_ seconds: TimeInterval) -> String {
        "-\(trackClock(seconds))"
    }

    public static func collectionDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    public static func mediumDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    public static func mediumDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func trackCollectionDuration(_ tracks: [Track]) -> String {
        collectionDuration(tracks.reduce(0) { $0 + $1.duration })
    }

    public static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func fileBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func sampleRate(_ rate: Int) -> String {
        if rate % 1000 == 0 {
            return "\(rate / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(rate) / 1000.0)
    }

    public static func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "aac": return "AAC"
        case "alac": return "ALAC"
        case "wav", "pcm": return "WAV"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default: return codec.uppercased()
        }
    }

    public static func logBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
