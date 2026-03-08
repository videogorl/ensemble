import AVFoundation

/// Converts downloaded MP3 files to Core Audio Format (CAF) with uncompressed PCM.
///
/// PMS's universal transcode produces VBR MP3 files that cause AVPlayer issues
/// at gapless transition boundaries (FigFilePlayer err=-12864). Converting to
/// CAF with exact sample counts gives AVPlayer a format it handles natively,
/// enabling true zero-gap gapless playback.
///
/// The conversion decodes the MP3 and writes uncompressed PCM — no quality loss,
/// just a format change. The resulting file is larger (~30MB for a 3min track)
/// but is only used for temporary streaming playback, not permanent storage.
enum AudioFormatConverter {

    /// Convert an MP3 file to uncompressed CAF for AVPlayer-native gapless playback.
    /// Returns the CAF file URL on success, or nil if conversion fails (caller
    /// should fall back to using the original MP3).
    static func convertToCAF(mp3URL: URL) -> URL? {
        let cafURL = mp3URL.deletingPathExtension().appendingPathExtension("caf")

        // Remove stale CAF if it exists
        if FileManager.default.fileExists(atPath: cafURL.path) {
            try? FileManager.default.removeItem(at: cafURL)
        }

        do {
            let inputFile = try AVAudioFile(forReading: mp3URL)
            let processingFormat = inputFile.processingFormat

            // Write as uncompressed PCM in CAF container — AVPlayer's native format
            // for gapless playback with exact sample-level precision.
            // Use the input's exact processing format (Float32 non-interleaved) for
            // the output so a single buffer works for both read() and write().
            let outputFile = try AVAudioFile(
                forWriting: cafURL,
                settings: processingFormat.settings,
                commonFormat: processingFormat.commonFormat,
                interleaved: processingFormat.isInterleaved
            )

            // Single buffer compatible with both input read() and output write()
            let bufferCapacity: AVAudioFrameCount = 8192
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: bufferCapacity
            ) else {
                return nil
            }

            while inputFile.framePosition < inputFile.length {
                try inputFile.read(into: buffer)
                try outputFile.write(from: buffer)
            }

            // Remove the source MP3 — we only need the CAF for playback
            try? FileManager.default.removeItem(at: mp3URL)

            #if DEBUG
            let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int) ?? 0
            EnsembleLogger.debug(
                "🎵 Converted MP3 to CAF: \(cafURL.lastPathComponent) "
                + "(\(cafSize / 1024)KB, \(inputFile.length) samples)"
            )
            #endif

            return cafURL
        } catch {
            #if DEBUG
            EnsembleLogger.debug("⚠️ MP3→CAF conversion failed: \(error). Using original MP3.")
            #endif
            // Clean up partial CAF if conversion failed
            try? FileManager.default.removeItem(at: cafURL)
            return nil
        }
    }
}
