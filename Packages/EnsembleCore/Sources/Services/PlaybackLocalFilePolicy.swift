import Foundation

/// Local audio-file policy shared by transport, playback launch, and prefetch
/// recovery paths. Keeps file sniffing and truncated-duration thresholds out of
/// the playback facade.
enum PlaybackLocalFilePolicy {
    static func preparedPlaybackURL(forPath path: String) -> URL {
        let originalURL = URL(fileURLWithPath: path)
        guard originalURL.pathExtension.lowercased() == "m4a" else { return originalURL }
        guard sniffedAudioContainer(for: originalURL) == "mp3" else { return originalURL }

        let mp3URL = originalURL.deletingPathExtension().appendingPathExtension("mp3")
        if FileManager.default.fileExists(atPath: mp3URL.path) {
            if sniffedAudioContainer(for: mp3URL) == "mp3", !isClearlyInvalidPayload(mp3URL) {
                return mp3URL
            }
            try? FileManager.default.removeItem(at: mp3URL)
        }

        do {
            try FileManager.default.linkItem(at: originalURL, to: mp3URL)
            return isClearlyInvalidPayload(mp3URL) ? originalURL : mp3URL
        } catch {
            do {
                try FileManager.default.copyItem(at: originalURL, to: mp3URL)
                return isClearlyInvalidPayload(mp3URL) ? originalURL : mp3URL
            } catch {
                EnsembleLogger.debug("⚠️ Failed creating mp3 alias for local playback: \(error.localizedDescription)")
                return originalURL
            }
        }
    }

    static func sniffedAudioContainer(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), !header.isEmpty else {
            return nil
        }

        if header.starts(with: Data([0x49, 0x44, 0x33])) { return "mp3" } // ID3
        if header.starts(with: Data([0x66, 0x4C, 0x61, 0x43])) { return "flac" } // fLaC
        if header.starts(with: Data([0xFF, 0xFB]))
            || header.starts(with: Data([0xFF, 0xF3]))
            || header.starts(with: Data([0xFF, 0xF2])) {
            return "mp3"
        }
        if header.count >= 8 && header.subdata(in: 4..<8) == Data([0x66, 0x74, 0x79, 0x70]) {
            return "m4a"
        }
        return nil
    }

    static func isClearlyInvalidPayload(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return true }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        if fileSize < 256 { return true }

        guard let header = try? handle.read(upToCount: 64), !header.isEmpty else {
            return true
        }

        let leadingText = String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<?xml")
            || leadingText.contains("<h1>400 bad request</h1>")
            || leadingText.contains("<h1>404 not found</h1>")
            || leadingText.contains("<h1>503 ") {
            return true
        }

        return false
    }

    static func shouldTreatAsTruncated(fileDuration: Double, expectedDuration: Double) -> Bool {
        guard expectedDuration > 10 else { return false }
        return fileDuration < expectedDuration * 0.5 && fileDuration < expectedDuration - 10
    }

    static func shouldCheckForTruncation(expectedDuration: Double) -> Bool {
        expectedDuration > 10
    }

    static func truncatedDownloadError(fileDuration: Double, expectedDuration: Double) -> String {
        "Truncated download (\(String(format: "%.0f", fileDuration))s vs \(String(format: "%.0f", expectedDuration))s expected)"
    }
}
